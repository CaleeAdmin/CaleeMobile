package com.nextcloud.caleesync

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.nextcloud.caleesync.NativeCalendarApi

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Set up the Pigeon API implementation
        Log.d("CalendarAPI", "Setting up NativeCalendarApi implementation")
        val calendarApi = CalendarHostApiImpl(this)
        NativeCalendarApi.setUp(flutterEngine.dartExecutor.binaryMessenger, calendarApi)
        Log.d("CalendarAPI", "NativeCalendarApi setup completed")
    }
}

