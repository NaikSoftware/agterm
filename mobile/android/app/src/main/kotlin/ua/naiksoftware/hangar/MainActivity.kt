package ua.naiksoftware.hangar

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
        // a web link opens in the browser; no url_launcher dependency for one call
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hangar/open").setMethodCallHandler { call, result ->
            try {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.arguments as String)))
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
