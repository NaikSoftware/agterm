package ua.naiksoftware.elis

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import com.dexterous.flutterlocalnotifications.ForegroundService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var ble: BleChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ble = BleChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        // `view` opens a web link in the browser, `share` shows the share sheet; no plugin dependency for two calls
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "elis/open").setMethodCallHandler { call, result ->
            try {
                val arg = call.arguments as String
                startActivity(
                    if (call.method == "share") Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, arg), null)
                    else Intent(Intent.ACTION_VIEW, Uri.parse(arg))
                )
                result.success(true)
            } catch (e: ActivityNotFoundException) {
                result.success(false)
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        ble?.onPermissionsResult(requestCode)
    }

    // Back finishes the activity (before Android 12) and takes the Dart side with it: nothing is left to watch
    override fun onDestroy() {
        ble?.closeAll() // the engine and its Dart links go with the activity
        if (isFinishing) stopService(Intent(this, ForegroundService::class.java))
        super.onDestroy()
    }
}
