package com.viso.caleesync

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.viso.caleesync.NativeCalendarApi

class MainActivity : FlutterActivity() {
    private val backgroundChannel = "caleesync/background_sync"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Set up the Pigeon API implementation
        Log.d("CalendarAPI", "Setting up NativeCalendarApi implementation")
        val calendarApi = CalendarHostApiImpl(this)
        NativeCalendarApi.setUp(flutterEngine.dartExecutor.binaryMessenger, calendarApi)
        Log.d("CalendarAPI", "NativeCalendarApi setup completed")

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, backgroundChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "schedulePeriodic" -> {
                    val interval = call.argument<Int>("intervalMinutes") ?: 15
                    CaleeSyncPeriodicWorker.schedulePeriodic(this, interval)
                    result.success(true)
                }

                "cancelPeriodic" -> {
                    CaleeSyncPeriodicWorker.cancelPeriodic(this)
                    result.success(true)
                }

                "enqueueOneOff" -> {
                    val reason = call.argument<String>("reason") ?: "manual"
                    val expedited = call.argument<Boolean>("expedited") ?: false
                    try {
                        CaleeSyncPeriodicWorker.enqueueOneOff(this, reason, expedited)
                        result.success(true)
                    } catch (e: IllegalArgumentException) {
                        Log.e("CaleeSyncWorker", "enqueueOneOff failed", e)
                        result.error("invalid_work_request", e.message, null)
                    }
                }

                "ensurePeriodicScheduled" -> {
                    val interval = call.argument<Int>("intervalMinutes") ?: 15
                    CaleeSyncPeriodicWorker.ensurePeriodic(this, interval)
                    result.success(true)
                }

                "getBackgroundStatus" -> result.success(CaleeSyncPeriodicWorker.readStatus(this))
                else -> result.notImplemented()
            }
        }
    }
}
