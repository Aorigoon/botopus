package com.example.botopus

import android.content.Intent
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.botopus/proot"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "startPRootService") {
                val command = call.argument<String>("command") ?: "sh"
                startUserLandService(command)
                result.success("Botopus PRoot Engine Service Started with command: $command")
            } else if (call.method == "stopPRootService") {
                stopUserLandService()
                result.success("Botopus PRoot Engine Stopped")
            } else {
                result.notImplemented()
            }
        }
    }

    private fun startUserLandService(command: String) {
        // Here we will bind the PRoot execution loops to a persistent Foreground Service.
        // And acquire WakeLock/WifiLock to bypass Android Phantom Process Killer.
        println("Starting PRoot with: $command")
        // Intent to start foreground service would go here
    }

    private fun stopUserLandService() {
        println("Stopping PRoot engine")
    }
}
