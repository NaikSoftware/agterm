package ua.naiksoftware.elis

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.view.inputmethod.InputMethodManager
import android.webkit.CookieManager
import android.webkit.WebView
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "elis/open").setMethodCallHandler { call, result ->
            try {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.arguments as String)))
                result.success(true)
            } catch (e: ActivityNotFoundException) {
                result.success(false)
            }
        }
        // a hidden page's web view keeps native focus and the keyboard, which Flutter's focus tree does not reach
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "elis/focus").setMethodCallHandler { call, result ->
            if (call.method != "release") return@setMethodCallHandler result.notImplemented()
            (currentFocus as? WebView)?.let { web ->
                getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(web.windowToken, 0)
                web.clearFocus()
            }
            result.success(null)
        }
        // a page tunnel's cookie: HttpOnly and SameSite, which webview_flutter's cookie API cannot set
        val cookies = CookieManager.getInstance()
        cookies.removeSessionCookies(null) // a killed app cleared no tunnel cookie
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "elis/cookie").setMethodCallHandler { call, result ->
            if (call.method != "set") return@setMethodCallHandler result.notImplemented()
            cookies.setCookie(call.argument<String>("url"), call.argument<String>("cookie")) { ok ->
                cookies.flush()
                result.success(ok)
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
