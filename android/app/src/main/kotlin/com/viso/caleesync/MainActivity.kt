package com.viso.caleesync

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        Log.d("CalendarAPI", "Setting up NativeCalendarApi implementation")
        val calendarApi = CalendarHostApiImpl(this)
        NativeCalendarApi.setUp(flutterEngine.dartExecutor.binaryMessenger, calendarApi)

        val controlApi = BackgroundSyncControlApiImpl(this)
        BackgroundSyncControlApi.setUp(flutterEngine.dartExecutor.binaryMessenger, controlApi)
        Log.d("CalendarAPI", "NativeCalendarApi and BackgroundSyncControlApi setup completed")
    }
}
