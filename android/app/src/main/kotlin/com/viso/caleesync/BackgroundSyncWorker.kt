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
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
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
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit().putLong(KEY_LAST_RUN_AT, System.currentTimeMillis()).apply()
        Log.i(TAG, "enter trigger=$trigger")

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

                        val calendarApi = CalendarHostApiImpl(context)
                        NativeCalendarApi.setUp(localEngine.dartExecutor.binaryMessenger, calendarApi)

                        val runnerApi = BackgroundSyncRunnerApi(localEngine.dartExecutor.binaryMessenger)
                        localEngine.dartExecutor.executeDartEntrypoint(
                            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "caleeSyncBackgroundEntrypoint")
                        )

                        invokeRunBackgroundSync(
                            runnerApi = runnerApi,
                            trigger = trigger,
                            prefs = prefs,
                            continuation = continuation
                        ) { continuation.isActive }
                    } catch (t: Throwable) {
                        persistSnapshot(
                            prefs = prefs,
                            outcome = BackgroundRunOutcome.RETRY,
                            reason = "engine_init_error",
                            gateReason = BackgroundGateReason.UNKNOWN,
                            error = t.message,
                        )
                        if (continuation.isActive) {
                            continuation.resume(Result.retry())
                        }
                    }
                }
            }
        } ?: run {
            persistSnapshot(
                prefs = prefs,
                outcome = BackgroundRunOutcome.RETRY,
                reason = "timeout_waiting_for_background_sync",
                gateReason = BackgroundGateReason.UNKNOWN,
            )
            Result.retry()
        }

        withContext(Dispatchers.Main.immediate) {
            engine?.destroy()
        }

        if (trigger.contains("periodic", ignoreCase = true)) {
            val configuredInterval = inputData.getInt("intervalMinutes", 15).coerceAtLeast(15)
            prefs.edit()
                .putInt(KEY_PERIODIC_INTERVAL_MINUTES, configuredInterval)
                .putLong(KEY_PERIODIC_NEXT_AT, System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(configuredInterval.toLong()))
                .apply()
            scheduleWatchdogAlarm(context, configuredInterval)
        }
        Log.i(TAG, "exit result=$workerResult")
        return workerResult
    }

    private fun invokeRunBackgroundSync(
        runnerApi: BackgroundSyncRunnerApi,
        trigger: String,
        prefs: android.content.SharedPreferences,
        continuation: kotlin.coroutines.Continuation<Result>,
        isActive: () -> Boolean,
    ) {
        runnerApi.runBackgroundSync(BackgroundRunRequest(trigger, CONTRACT_VERSION.toLong())) { response ->
            response.fold(
                onSuccess = { runResult ->
                    val outcome = runResult.outcome
                    persistSnapshot(
                        prefs = prefs,
                        outcome = outcome,
                        reason = runResult.reason,
                        gateReason = runResult.gateReason,
                        error = runResult.error,
                    )
                    val mapped = mapOutcomeToWorkerResult(outcome)
                    Log.i(TAG, "classified outcome=${outcome.name} mapped=$mapped reason=${runResult.reason} gate=${runResult.gateReason.name} version=${runResult.contractVersion}")
                    if (isActive()) {
                        continuation.resume(mapped)
                    }
                },
                onFailure = { error ->
                    persistSnapshot(
                        prefs = prefs,
                        outcome = BackgroundRunOutcome.RETRY,
                        reason = "runner_channel_error",
                        gateReason = BackgroundGateReason.UNKNOWN,
                        error = error.message,
                    )
                    if (isActive()) {
                        continuation.resume(Result.retry())
                    }
                },
            )
        }
    }

    companion object {
        private const val TAG = "CaleeSyncWorker"
        private const val PREFS = "calee_sync_bg"
        private const val KEY_PERIODIC_ENABLED = "periodic_enabled"
        private const val KEY_PERIODIC_INTERVAL_MINUTES = "periodic_interval_minutes"
        private const val KEY_PERIODIC_NEXT_AT = "periodic_next_at"
        private const val KEY_LAST_RUN_AT = "last_run_at"
        private const val KEY_LAST_OUTCOME = "last_outcome"
        private const val CONTRACT_VERSION = 1
        private const val KEY_LAST_REASON = "last_reason"
        private const val KEY_LAST_GATE = "last_gate"
        private const val KEY_LAST_ERROR = "last_error"

        const val PERIODIC_UNIQUE = "CaleeSyncPeriodicWorker"
        const val SYNC_UNIQUE = "CaleeSyncSyncWorker"
        private const val WATCHDOG_INTERVAL_MINUTES = 20L
        private const val WATCHDOG_REQUEST_CODE = 90241
        const val ACTION_WATCHDOG = "com.viso.caleesync.ACTION_BACKGROUND_SYNC_WATCHDOG"

        private fun networkConnectedConstraints(): Constraints {
            return Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()
        }

        private fun mapOutcomeToWorkerResult(outcome: BackgroundRunOutcome): Result {
            return when (outcome) {
                BackgroundRunOutcome.SUCCESS, BackgroundRunOutcome.GATED -> Result.success()
                BackgroundRunOutcome.RETRY -> Result.retry()
                BackgroundRunOutcome.FAILURE -> Result.failure()
            }
        }

        private fun persistSnapshot(
            prefs: android.content.SharedPreferences,
            outcome: BackgroundRunOutcome,
            reason: String?,
            gateReason: BackgroundGateReason = BackgroundGateReason.NONE,
            error: String? = null,
        ) {
            prefs.edit()
                .putLong(KEY_LAST_RUN_AT, System.currentTimeMillis())
                .putString(KEY_LAST_OUTCOME, outcome.name.lowercase())
                .putString(KEY_LAST_REASON, reason ?: "")
                .putString(KEY_LAST_GATE, gateReason.name.lowercase())
                .putString(KEY_LAST_ERROR, error ?: "")
                .apply()
        }

        suspend fun schedulePeriodic(context: Context, intervalMinutes: Int): Operation {
            val bounded = intervalMinutes.coerceAtLeast(15).toLong()
            val request = PeriodicWorkRequestBuilder<CaleeSyncPeriodicWorker>(bounded, TimeUnit.MINUTES)
                .setInputData(androidx.work.workDataOf("trigger" to "periodic", "intervalMinutes" to bounded.toInt()))
                .setConstraints(networkConnectedConstraints())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
                .build()
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_PERIODIC_ENABLED, true)
                .putInt(KEY_PERIODIC_INTERVAL_MINUTES, bounded.toInt())
                .putLong(KEY_PERIODIC_NEXT_AT, System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(bounded))
                .apply()
            val operation = WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(PERIODIC_UNIQUE, ExistingPeriodicWorkPolicy.UPDATE, request)
            scheduleWatchdogAlarm(context, bounded.toInt())
            return operation
        }

        suspend fun ensurePeriodic(context: Context, intervalMinutes: Int) {
            val bounded = intervalMinutes.coerceAtLeast(15)
            val infos = awaitFuture(WorkManager.getInstance(context).getWorkInfosForUniqueWork(PERIODIC_UNIQUE))
            if (infos.any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.RUNNING }) {
                scheduleWatchdogAlarm(context, bounded)
                return
            }
            schedulePeriodic(context, bounded)
        }

        suspend fun cancelPeriodic(context: Context): Operation {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_PERIODIC_ENABLED, false)
                .remove(KEY_PERIODIC_NEXT_AT)
                .apply()
            cancelWatchdogAlarm(context)
            return WorkManager.getInstance(context).cancelUniqueWork(PERIODIC_UNIQUE)
        }

        suspend fun enqueueOneOff(context: Context, reason: String, expedited: Boolean): Operation {
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
                    Log.w(TAG, "Invalid expedited constraints; falling back to non-expedited one-off", iae)
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
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return prefs.getInt(KEY_PERIODIC_INTERVAL_MINUTES, 15).coerceAtLeast(15)
        }


        fun isPeriodicEnabled(context: Context): Boolean {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return prefs.getBoolean(KEY_PERIODIC_ENABLED, false)
        }


        private fun parseOutcome(raw: String?): BackgroundRunOutcome? {
            return when (raw?.lowercase()) {
                "success" -> BackgroundRunOutcome.SUCCESS
                "retry" -> BackgroundRunOutcome.RETRY
                "failure" -> BackgroundRunOutcome.FAILURE
                "gated" -> BackgroundRunOutcome.GATED
                else -> null
            }
        }


        private fun parseGateReason(raw: String?): BackgroundGateReason? {
            return when (raw?.lowercase()) {
                "none" -> BackgroundGateReason.NONE
                "no_network" -> BackgroundGateReason.NO_NETWORK
                "auth_invalid" -> BackgroundGateReason.AUTH_INVALID
                "binding_invalid" -> BackgroundGateReason.BINDING_INVALID
                "repair_required" -> BackgroundGateReason.REPAIR_REQUIRED
                "environment_blocked" -> BackgroundGateReason.ENVIRONMENT_BLOCKED
                "local_calendar_missing" -> BackgroundGateReason.LOCAL_CALENDAR_MISSING
                "unknown" -> BackgroundGateReason.UNKNOWN
                else -> null
            }
        }

        suspend fun readStatus(context: Context): BackgroundStatusDto {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val periodicInfos = awaitFuture(WorkManager.getInstance(context).getWorkInfosForUniqueWork(PERIODIC_UNIQUE))
            val syncInfos = awaitFuture(WorkManager.getInstance(context).getWorkInfosForUniqueWork(SYNC_UNIQUE))
            val periodicEnabled = prefs.getBoolean(KEY_PERIODIC_ENABLED, false) &&
                periodicInfos.any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.RUNNING }
            val workerRunning = (periodicInfos + syncInfos).any { it.state == WorkInfo.State.RUNNING }
            val configuredInterval = prefs.getInt(KEY_PERIODIC_INTERVAL_MINUTES, 15).takeIf { it >= 15 } ?: 15
            val nextAt = prefs.getLong(KEY_PERIODIC_NEXT_AT, 0L).takeIf { it > 0 }
            val lastRunAt = prefs.getLong(KEY_LAST_RUN_AT, 0L).takeIf { it > 0 }
            return BackgroundStatusDto(
                periodicEnabled = periodicEnabled,
                lastRunAtMs = lastRunAt,
                lastOutcome = prefs.getString(KEY_LAST_OUTCOME, "unknown")?.let { parseOutcome(it) },
                lastReason = prefs.getString(KEY_LAST_REASON, ""),
                lastGateReason = prefs.getString(KEY_LAST_GATE, "")?.let { parseGateReason(it) },
                lastError = prefs.getString(KEY_LAST_ERROR, ""),
                nextScheduledAtMs = nextAt,
                workerRunning = workerRunning,
                intervalMinutes = configuredInterval.toLong(),
                contractVersion = CONTRACT_VERSION.toLong(),
            )
        }

        private suspend fun <T> awaitFuture(future: ListenableFuture<T>): T = suspendCancellableCoroutine { cont ->
            future.addListener(
                {
                    try {
                        cont.resume(future.get())
                    } catch (t: Throwable) {
                        cont.resumeWithException(t)
                    }
                },
                java.util.concurrent.Executor { runnable -> runnable.run() },
            )
        }
    }
}
