package ua.naiksoftware.hangar

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit

// Radio work only: find the Mac by its service UUID, read the L2CAP PSM over GATT, open the channel and move raw bytes.
// The handshake, framing and encryption are Dart's (ble_transport.dart). Dart picks each link's id, so a late close
// from an old attempt never reaches a newer link.
@SuppressLint("MissingPermission") // granted() gates every Dart call that reaches the radio
class BleChannel(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private val links = ConcurrentHashMap<Int, Link>()
    private var permit: MethodChannel.Result? = null

    init {
        MethodChannel(messenger, "hangar/ble").setMethodCallHandler(this)
        EventChannel(messenger, "hangar/ble/data").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
    // Dart never cancels while it lives: the engine went away, and an open link would keep the Mac busy for this phone
    override fun onCancel(arguments: Any?) {
        sink = null
        closeAll()
    }

    fun closeAll() {
        for (id in links.keys.toList()) links.remove(id)?.close()
    }

    private fun granted() = PERMISSIONS.all { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    fun onPermissionsResult(requestCode: Int) {
        if (requestCode != REQUEST) return
        permit?.success(granted())
        permit = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Int>("id") ?: 0
        when (call.method) {
            "granted" -> result.success(granted())
            "permit" -> if (granted()) result.success(true) else {
                permit?.success(granted())
                permit = result
                activity.requestPermissions(PERMISSIONS, REQUEST)
            }
            "connect" -> {
                val link = Link(id)
                links[id] = link
                Thread { link.open(call.argument<List<String>>("services")!!.map(UUID::fromString), call.argument<Int>("timeoutMs")!!.toLong(), result) }.start()
            }
            "write" -> links[id]?.write(call.argument<ByteArray>("data")!!, result) ?: result.error("closed", null, null)
            "close" -> { links.remove(id)?.close(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private class NotFound : IOException("not found")
    private class Off : IOException("Bluetooth is off")
    private class ScanFailed(code: Int) : IOException("code $code")
    private data class Psm(val value: Int)

    private inner class Link(val id: Int) {
        @Volatile private var closed = false
        @Volatile private var gatt: BluetoothGatt? = null
        @Volatile private var socket: BluetoothSocket? = null
        private val events = LinkedBlockingQueue<Any>() // scan and GATT callbacks; an IOException fails the wait
        private val writer = Executors.newSingleThreadExecutor() // one writer: ciphertext order is nonce order

        fun open(services: List<UUID>, timeoutMs: Long, result: MethodChannel.Result) {
            try {
                val device = scan(services, timeoutMs)
                val psm = readPsm(device, services)
                val s = device.createInsecureL2capChannel(psm)
                socket = s
                if (closed) throw IOException("closed")
                val watchdog = Runnable { runCatching { s.close() } } // connect() has no timeout of its own
                main.postDelayed(watchdog, STEP_MS)
                try { s.connect() } finally { main.removeCallbacks(watchdog) }
                main.post { result.success(null) }
                read(s)
            } catch (e: Exception) {
                close()
                links.remove(id, this)
                val code = when (e) { is NotFound -> "notFound"; is Off -> "off"; is ScanFailed -> "scanFailed"; else -> "failed" }
                main.post { result.error(code, e.message ?: e.toString(), null) }
            }
        }

        private fun scan(services: List<UUID>, timeoutMs: Long): BluetoothDevice {
            val adapter = activity.getSystemService(BluetoothManager::class.java)?.adapter
            if (adapter == null || !adapter.isEnabled) throw Off()
            val scanner = adapter.bluetoothLeScanner ?: throw Off() // null while the radio turns off
            val cb = object : ScanCallback() {
                override fun onScanResult(callbackType: Int, r: ScanResult) { events.offer(r.device) }
                override fun onScanFailed(errorCode: Int) { events.offer(ScanFailed(errorCode)) }
            }
            scanner.startScan(
                services.map { ScanFilter.Builder().setServiceUuid(ParcelUuid(it)).build() }, // the rotating UUIDs of epochs e-1, e, e+1
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), cb)
            try {
                return await(timeoutMs) { NotFound() }
            } finally {
                runCatching { scanner.stopScan(cb) } // throws when Bluetooth went off meanwhile
            }
        }

        // The spike kept the GATT open for the whole L2CAP session (and requested HIGH priority on it), so this does too.
        private fun readPsm(device: BluetoothDevice, services: List<UUID>): Int {
            gatt = device.connectGatt(activity, false, object : BluetoothGattCallback() {
                override fun onConnectionStateChange(g: BluetoothGatt, status: Int, state: Int) {
                    if (status != BluetoothGatt.GATT_SUCCESS || state == BluetoothProfile.STATE_DISCONNECTED) {
                        events.offer(IOException("GATT state $state status $status"))
                    } else if (state == BluetoothProfile.STATE_CONNECTED) g.discoverServices()
                }
                override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                    val c = services.firstNotNullOfOrNull { g.getService(it) }?.getCharacteristic(PSM_CHARACTERISTIC) // whichever epoch matched
                    if (status != BluetoothGatt.GATT_SUCCESS || c == null || !g.readCharacteristic(c)) {
                        events.offer(IOException("no PSM characteristic (status $status)"))
                    }
                }
                override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, v: ByteArray, status: Int) {
                    events.offer(if (status == BluetoothGatt.GATT_SUCCESS && v.size == 2) Psm((v[0].toInt() and 0xff) or ((v[1].toInt() and 0xff) shl 8))
                        else IOException("PSM read status $status, ${v.size} bytes"))
                }
            }, BluetoothDevice.TRANSPORT_LE)
            if (closed) throw IOException("closed")
            val psm = await<Psm>(STEP_MS) { IOException("GATT timed out") }.value
            gatt?.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
            gatt?.setPreferredPhy(BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_OPTION_NO_PREFERRED)
            return psm
        }

        // skips what an earlier step left behind (more scan results); an IOException is the step's failure
        private inline fun <reified T> await(ms: Long, timeout: () -> IOException): T {
            val deadline = System.nanoTime() + ms * 1_000_000
            while (true) {
                val left = (deadline - System.nanoTime()) / 1_000_000
                val e = events.poll(left.coerceAtLeast(0), TimeUnit.MILLISECONDS) ?: throw timeout()
                if (e is T) return e
                if (e is IOException) throw e
            }
        }

        private fun read(s: BluetoothSocket) {
            val buf = ByteArray(65536)
            try {
                while (true) {
                    val n = s.inputStream.read(buf)
                    if (n < 0) break
                    val data = buf.copyOf(n)
                    main.post { sink?.success(mapOf("id" to id, "data" to data)) }
                }
            } catch (_: IOException) {
            }
            close()
            links.remove(id, this)
            main.post { sink?.success(mapOf("id" to id, "closed" to true)) }
        }

        fun write(data: ByteArray, result: MethodChannel.Result) = try {
            writer.execute {
                try {
                    socket!!.outputStream.write(data)
                    main.post { result.success(null) }
                } catch (e: Exception) {
                    close()
                    main.post { result.error("closed", e.toString(), null) }
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error("closed", null, null)
        }

        fun close() {
            closed = true
            events.offer(IOException("closed")) // wakes a scan or GATT wait
            runCatching { socket?.close() }
            gatt?.let { runCatching { it.disconnect(); it.close() } }
            writer.shutdownNow()
        }
    }

    companion object {
        private const val REQUEST = 4201
        private const val STEP_MS = 15_000L
        private val PERMISSIONS = arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        private val PSM_CHARACTERISTIC: UUID = UUID.fromString("a6e5c0de-0001-4a67-8000-68616e6761d1")
    }
}
