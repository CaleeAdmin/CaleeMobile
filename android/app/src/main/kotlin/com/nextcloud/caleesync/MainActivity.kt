package com.nextcloud.caleesync

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Register Pigeon CalendarHostApi implementation
        CalendarHostApi.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            CalendarHostApiImpl(contentResolver)
        )
    }
}

