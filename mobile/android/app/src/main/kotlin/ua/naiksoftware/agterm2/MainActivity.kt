package ua.naiksoftware.agterm2

import android.content.Intent
import com.dexterous.flutterlocalnotifications.ForegroundService
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // Back finishes the activity (before Android 12) and takes the Dart side with it: nothing is left to watch
    override fun onDestroy() {
        if (isFinishing) stopService(Intent(this, ForegroundService::class.java))
        super.onDestroy()
    }
}
