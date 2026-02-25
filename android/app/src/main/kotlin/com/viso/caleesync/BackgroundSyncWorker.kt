package com.viso.caleesync

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.Operation
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

class CaleeSyncPeriodicWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val trigger = inputData.getString("trigger") ?: "periodic"
        return runSyncTask(applicationContext, trigger)
    }

    private suspend fun runSyncTask(context: Context, trigger: String): Result {
        val prefs = context.getSharedPreferences("calee_sync_bg", Context.MODE_PRIVATE)
        prefs.edit().putLong("last_run_at", System.currentTimeMillis()).apply()
        Log.i("CaleeSyncWorker", "enter trigger=$trigger")

        var engine: FlutterEngine? = null
        val workerResult = withTimeoutOrNull(90_000) {
            suspendCancellableCoroutine<Result> { continuation ->
                Handler(Looper.getMainLooper()).post {
                    try {
                        val loader = FlutterInjector.instance().flutterLoader()
                        loader.startInitialization(context)
                        loader.ensureInitializationComplete(context, null)

                        val localEngine = FlutterEngine(context)
                        GeneratedPluginRegistrant.registerWith(localEngine)
                        engine = localEngine

                        // Register Pigeon host APIs on the background engine as well.
                        val calendarApi = CalendarHostApiImpl(context)
                        NativeCalendarApi.setUp(localEngine.dartExecutor.binaryMessenger, calendarApi)

                        val channel = MethodChannel(localEngine.dartExecutor.binaryMessenger, CHANNEL)
                        localEngine.dartExecutor.executeDartEntrypoint(
                            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "caleeSyncBackgroundEntrypoint")
                        )

                        invokeRunBackgroundSync(
                            channel = channel,
                            trigger = trigger,
                            prefs = prefs,
                            continuation = continuation,
                            attempt = 0,
                        ) { continuation.isActive }
                    } catch (t: Throwable) {
                        prefs.edit().putString("last_result", "retry").putString("last_reason", t.message ?: "engine_init_error").apply()
                        if (continuation.isActive) {
                            continuation.resume(Result.retry())
                        }
                    }
                }
            }
        } ?: run {
            prefs.edit().putString("last_result", "retry").putString("last_reason", "timeout_waiting_for_background_sync").apply()
            Result.retry()
        }

        withContext(Dispatchers.Main.immediate) {
            engine?.destroy()
        }

        if (trigger.contains("periodic", ignoreCase = true)) {
            val configuredInterval = inputData.getInt("intervalMinutes", 15).coerceAtLeast(15)
            prefs.edit()
                .putInt("periodic_interval_minutes", configuredInterval)
                .putLong("periodic_next_at", System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(configuredInterval.toLong()))
                .apply()
            scheduleWatchdogAlarm(context, configuredInterval)
        }
        Log.i("CaleeSyncWorker", "exit result=$workerResult")
        return workerResult
    }

    private fun invokeRunBackgroundSync(
        channel: MethodChannel,
        trigger: String,
        prefs: android.content.SharedPreferences,
        continuation: kotlin.coroutines.Continuation<Result>,
        attempt: Int,
        isActive: () -> Boolean,
    ) {
        channel.invokeMethod("runBackgroundSync", mapOf("trigger" to trigger), object : MethodChannel.Result {
            override fun success(result: Any?) {
                val map = result as? Map<*, *>
                val state = map?.get("state")?.toString() ?: "failure"
                val reason = map?.get("reason")?.toString() ?: "unknown"
                prefs.edit().putString("last_reason", reason).putString("last_result", state).apply()
                if (isActive()) {
                    continuation.resume(
                        when (state) {
                            "success" -> Result.success()
                            "retry" -> Result.retry()
                            else -> Result.failure()
                        }
                    )
                }
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                prefs.edit().putString("last_result", "retry").putString("last_reason", "$errorCode:$errorMessage").apply()
                if (isActive()) {
                    continuation.resume(Result.retry())
                }
            }

            override fun notImplemented() {
                if (attempt < MAX_NOT_IMPLEMENTED_RETRIES) {
                    Handler(Looper.getMainLooper()).postDelayed({
                        invokeRunBackgroundSync(channel, trigger, prefs, continuation, attempt = attempt + 1, isActive = isActive)
                    }, NOT_IMPLEMENTED_RETRY_DELAY_MS)
                    return
                }
                prefs.edit().putString("last_result", "retry").putString("last_reason", "not_implemented").apply()
                if (isActive()) {
                    continuation.resume(Result.retry())
                }
            }
        })
    }

    companion object {
        private const val CHANNEL = "caleesync/background_sync"
        private const val PERIODIC_UNIQUE = "CaleeSyncPeriodicWorker"
        private const val SYNC_UNIQUE = "CaleeSyncSyncWorker"
        private const val MAX_NOT_IMPLEMENTED_RETRIES = 6
        private const val NOT_IMPLEMENTED_RETRY_DELAY_MS = 400L
        private const val WATCHDOG_INTERVAL_MINUTES = 20L
        private const val WATCHDOG_REQUEST_CODE = 90241
        const val ACTION_WATCHDOG = "com.viso.caleesync.ACTION_BACKGROUND_SYNC_WATCHDOG"

        private fun networkConnectedConstraints(): Constraints {
            return Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()
        }

        fun schedulePeriodic(context: Context, intervalMinutes: Int): Operation {
            val bounded = intervalMinutes.coerceAtLeast(15).toLong()
            val request = PeriodicWorkRequestBuilder<CaleeSyncPeriodicWorker>(bounded, TimeUnit.MINUTES)
                .setInputData(androidx.work.workDataOf("trigger" to "periodic", "intervalMinutes" to bounded.toInt()))
                .setConstraints(networkConnectedConstraints())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
                .build()
            context.getSharedPreferences("calee_sync_bg", Context.MODE_PRIVATE)
                .edit()
                .putBoolean("periodic_enabled", true)
                .putInt("periodic_interval_minutes", bounded.toInt())
                .putLong("periodic_next_at", System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(bounded))
                .apply()
            val operation = WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(PERIODIC_UNIQUE, ExistingPeriodicWorkPolicy.UPDATE, request)
            scheduleWatchdogAlarm(context, bounded.toInt())
            return operation
        }

        fun ensurePeriodic(context: Context, intervalMinutes: Int) {
            val bounded = intervalMinutes.coerceAtLeast(15)
            val infos = WorkManager.getInstance(context).getWorkInfosForUniqueWork(PERIODIC_UNIQUE).get()
            if (infos.any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.RUNNING }) {
                scheduleWatchdogAlarm(context, bounded)
                return
            }
            schedulePeriodic(context, bounded)
        }

        fun cancelPeriodic(context: Context): Operation {
            context.getSharedPreferences("calee_sync_bg", Context.MODE_PRIVATE)
                .edit()
                .putBoolean("periodic_enabled", false)
                .remove("periodic_next_at")
                .apply()
            cancelWatchdogAlarm(context)
            return WorkManager.getInstance(context).cancelUniqueWork(PERIODIC_UNIQUE)
        }

        fun enqueueOneOff(context: Context, reason: String, expedited: Boolean): Operation {
            val builder = OneTimeWorkRequestBuilder<CaleeSyncPeriodicWorker>()
                .setConstraints(networkConnectedConstraints())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
                .setInputData(androidx.work.workDataOf("trigger" to reason))

            val request = if (expedited) {
                try {
                    builder
                        .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                        .build()
                } catch (iae: IllegalArgumentException) {
                    Log.w("CaleeSyncWorker", "Invalid expedited constraints; falling back to non-expedited one-off", iae)
                    OneTimeWorkRequestBuilder<CaleeSyncPeriodicWorker>()
                        .setConstraints(networkConnectedConstraints())
                        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
                        .setInputData(androidx.work.workDataOf("trigger" to reason))
                        .build()
                }
            } else {
                builder.build()
            }

            return WorkManager.getInstance(context)
                .enqueueUniqueWork(SYNC_UNIQUE, ExistingWorkPolicy.REPLACE, request)
        }

        fun scheduleWatchdogAlarm(context: Context, intervalMinutes: Int? = null) {
            val bounded = (intervalMinutes ?: readConfiguredIntervalMinutes(context)).coerceAtLeast(15)
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val triggerAtMs = System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(maxOf(bounded.toLong(), WATCHDOG_INTERVAL_MINUTES))
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                WATCHDOG_REQUEST_CODE,
                Intent(context, BackgroundSyncWatchdogReceiver::class.java).setAction(ACTION_WATCHDOG),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMs, pendingIntent)
        }

        fun cancelWatchdogAlarm(context: Context) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                WATCHDOG_REQUEST_CODE,
                Intent(context, BackgroundSyncWatchdogReceiver::class.java).setAction(ACTION_WATCHDOG),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            alarmManager.cancel(pendingIntent)
            pendingIntent.cancel()
        }

        fun readConfiguredIntervalMinutes(context: Context): Int {
            val prefs = context.getSharedPreferences("calee_sync_bg", Context.MODE_PRIVATE)
            return prefs.getInt("periodic_interval_minutes", 15).coerceAtLeast(15)
        }


        fun isPeriodicEnabled(context: Context): Boolean {
            val prefs = context.getSharedPreferences("calee_sync_bg", Context.MODE_PRIVATE)
            return prefs.getBoolean("periodic_enabled", false)
        }

        fun readStatus(context: Context): Map<String, Any?> {
            val prefs = context.getSharedPreferences("calee_sync_bg", Context.MODE_PRIVATE)
            val periodicInfos = WorkManager.getInstance(context).getWorkInfosForUniqueWork(PERIODIC_UNIQUE).get()
            val syncInfos = WorkManager.getInstance(context).getWorkInfosForUniqueWork(SYNC_UNIQUE).get()
            val periodicEnabled = prefs.getBoolean("periodic_enabled", false) && periodicInfos.any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.RUNNING }
            val workerRunning = (periodicInfos + syncInfos).any { it.state == WorkInfo.State.RUNNING }
            val configuredInterval = prefs.getInt("periodic_interval_minutes", 15).takeIf { it >= 15 } ?: 15
            val nextAt = prefs.getLong("periodic_next_at", 0L).takeIf { it > 0 }
            return mapOf(
                "periodicEnabled" to periodicEnabled,
                "lastRunAtMs" to prefs.getLong("last_run_at", 0L).takeIf { it > 0 },
                "lastResult" to prefs.getString("last_result", "unknown"),
                "lastReason" to prefs.getString("last_reason", ""),
                "nextScheduledAtMs" to nextAt,
                "workerRunning" to workerRunning,
                "intervalMinutes" to configuredInterval,
            )
        }
    }
}

