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
import androidx.work.ListenableWorker
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
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

private typealias WorkResult = ListenableWorker.Result

class CaleeSyncPeriodicWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): WorkResult {
        if (isStopped) {
            Log.w(TAG, "worker stopped before start")
            return WorkResult.retry()
        }
        val trigger = inputData.getString("trigger") ?: "periodic"
        return runSyncTask(applicationContext, trigger)
    }

    private suspend fun runSyncTask(context: Context, trigger: String): WorkResult {
        if (isStopped) {
            Log.w(TAG, "runSyncTask aborted because worker is stopped")
            return WorkResult.retry()
        }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit().putLong(KEY_LAST_RUN_AT, System.currentTimeMillis()).apply()
        Log.i(TAG, "enter trigger=$trigger")

        var engine: FlutterEngine? = null
        var stage = STAGE_ENGINE_CREATED
        val workerResult = withTimeoutOrNull(WORKER_EXEC_TIMEOUT_MS) {
            suspendCancellableCoroutine<WorkResult> { continuation ->
                Handler(Looper.getMainLooper()).post {
                    try {
                        val loader = FlutterInjector.instance().flutterLoader()
                        loader.startInitialization(context)
                        loader.ensureInitializationComplete(context, null)

                        val localEngine = FlutterEngine(context)
                        GeneratedPluginRegistrant.registerWith(localEngine)
                        engine = localEngine
                        stage = STAGE_ENGINE_CREATED
                        persistStage(prefs, stage)

                        val calendarApi = CalendarHostApiImpl(context)
                        NativeCalendarApi.setUp(localEngine.dartExecutor.binaryMessenger, calendarApi)

                        val readyLatch = java.util.concurrent.CountDownLatch(1)
                        val runnerHostApi = object : BackgroundSyncRunnerHostApi {
                            override fun notifyBackgroundIsolateReady(contractVersion: Long, callback: (kotlin.Result<Unit>) -> Unit) {
                                prefs.edit().putLong(KEY_LAST_READY_VERSION, contractVersion).apply()
                                stage = STAGE_DART_READY_RECEIVED
                                persistStage(prefs, stage)
                                readyLatch.countDown()
                                callback(kotlin.Result.success(Unit))
                            }
                        }
                        BackgroundSyncRunnerHostApi.setUp(localEngine.dartExecutor.binaryMessenger, runnerHostApi)

                        val runnerApi = BackgroundSyncRunnerApi(localEngine.dartExecutor.binaryMessenger)
                        stage = STAGE_DART_ENTRYPOINT_STARTED
                        persistStage(prefs, stage)
                        localEngine.dartExecutor.executeDartEntrypoint(
                            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "caleeSyncBackgroundEntrypoint")
                        )

                        Thread {
                            val isReady = readyLatch.await(DART_READY_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                            Handler(Looper.getMainLooper()).post {
                                if (!continuation.isActive) {
                                    return@post
                                }
                                if (isStopped) {
                                    persistSnapshot(
                                        prefs = prefs,
                                        outcome = BackgroundRunOutcome.RETRY,
                                        reason = "worker_stopped",
                                        gateReason = BackgroundGateReason.UNKNOWN,
                                    )
                                    continuation.resume(WorkResult.retry())
                                    return@post
                                }
                                if (!isReady) {
                                    persistSnapshot(
                                        prefs = prefs,
                                        outcome = BackgroundRunOutcome.RETRY,
                                        reason = "dart_not_ready",
                                        gateReason = BackgroundGateReason.UNKNOWN,
                                    )
                                    continuation.resume(WorkResult.retry())
                                    return@post
                                }
                                invokeRunBackgroundSync(
                                    runnerApi = runnerApi,
                                    trigger = trigger,
                                    prefs = prefs,
                                    continuation = continuation,
                                    stageProvider = { stage },
                                    stageSetter = {
                                        stage = it
                                        persistStage(prefs, stage)
                                    },
                                ) { continuation.isActive }
                            }
                        }.start()
                    } catch (t: Throwable) {
                        persistSnapshot(
                            prefs = prefs,
                            outcome = BackgroundRunOutcome.RETRY,
                            reason = "engine_init_error",
                            gateReason = BackgroundGateReason.UNKNOWN,
                            error = t.message,
                        )
                        persistStage(prefs, stage)
                        if (continuation.isActive) {
                            continuation.resume(WorkResult.retry())
                        }
                    }
                }
            }
        } ?: run {
            persistSnapshot(
                prefs = prefs,
                outcome = BackgroundRunOutcome.RETRY,
                reason = "sync_timeout",
                gateReason = BackgroundGateReason.UNKNOWN,
                error = "worker_execution_timeout",
            )
            persistStage(prefs, stage)
            WorkResult.retry()
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
        persistStage(prefs, STAGE_WORKER_FINISHED)
        Log.i(TAG, "exit result=$workerResult")
        return workerResult
    }

    private fun invokeRunBackgroundSync(
        runnerApi: BackgroundSyncRunnerApi,
        trigger: String,
        prefs: android.content.SharedPreferences,
        continuation: kotlin.coroutines.Continuation<WorkResult>,
        stageProvider: () -> String,
        stageSetter: (String) -> Unit,
        isActive: () -> Boolean,
    ) {
        stageSetter(STAGE_RUN_SYNC_SENT)
        val runReturned = AtomicLong(0L)
        Thread {
            Thread.sleep(SYNC_REPLY_TIMEOUT_MS)
            if (runReturned.compareAndSet(0L, 1L) && isActive()) {
                persistSnapshot(
                    prefs = prefs,
                    outcome = BackgroundRunOutcome.RETRY,
                    reason = "engine_killed_or_no_reply",
                    gateReason = BackgroundGateReason.UNKNOWN,
                    error = "sync_reply_timeout",
                )
                persistStage(prefs, stageProvider())
                continuation.resume(WorkResult.retry())
            }
        }.start()

        runnerApi.runBackgroundSync(BackgroundRunRequest(trigger, CONTRACT_VERSION.toLong())) { response ->
            if (!runReturned.compareAndSet(0L, 1L)) {
                return@runBackgroundSync
            }
            response.fold(
                onSuccess = { runResult ->
                    stageSetter(STAGE_RUN_SYNC_REPLIED)
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
                    stageSetter(STAGE_RUN_SYNC_REPLIED)
                    persistSnapshot(
                        prefs = prefs,
                        outcome = BackgroundRunOutcome.RETRY,
                        reason = "runner_channel_error",
                        gateReason = BackgroundGateReason.UNKNOWN,
                        error = error.message,
                    )
                    if (isActive()) {
                        continuation.resume(WorkResult.retry())
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
        private const val KEY_LAST_STAGE = "last_stage"
        private const val KEY_LAST_STAGE_AT = "last_stage_at"
        private const val KEY_LAST_READY_VERSION = "last_ready_version"
        private const val KEY_LAST_ATTEMPT_AT = "last_attempt_at"

        private const val STAGE_ENGINE_CREATED = "ENGINE_CREATED"
        private const val STAGE_DART_ENTRYPOINT_STARTED = "DART_ENTRYPOINT_STARTED"
        private const val STAGE_DART_READY_RECEIVED = "DART_READY_RECEIVED"
        private const val STAGE_RUN_SYNC_SENT = "RUN_SYNC_SENT"
        private const val STAGE_RUN_SYNC_REPLIED = "RUN_SYNC_REPLIED"
        private const val STAGE_WORKER_FINISHED = "WORKER_FINISHED"

        private const val DART_READY_TIMEOUT_MS = 15_000L
        // Full background sync can legitimately take longer than 25s on large calendars.
        // Keep a dedicated reply timeout, but align it with a longer worker cap to avoid
        // prematurely classifying active runs as "killed_or_no_reply".
        private const val SYNC_REPLY_TIMEOUT_MS = 75_000L
        private const val WORKER_EXEC_TIMEOUT_MS = 120_000L
        private const val RECENT_ATTEMPT_WINDOW_MS = 30_000L

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

        private fun mapOutcomeToWorkerResult(outcome: BackgroundRunOutcome): WorkResult {
            return when (outcome) {
                BackgroundRunOutcome.SUCCESS, BackgroundRunOutcome.GATED -> WorkResult.success()
                BackgroundRunOutcome.RETRY -> WorkResult.retry()
                BackgroundRunOutcome.FAILURE -> WorkResult.failure()
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
                .putLong(KEY_LAST_ATTEMPT_AT, System.currentTimeMillis())
                .apply()
        }

        private fun persistStage(
            prefs: android.content.SharedPreferences,
            stage: String,
        ) {
            prefs.edit()
                .putString(KEY_LAST_STAGE, stage)
                .putLong(KEY_LAST_STAGE_AT, System.currentTimeMillis())
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
                .enqueueUniqueWork(SYNC_UNIQUE, ExistingWorkPolicy.KEEP, request)
        }

        fun shouldSkipWatchdogOneOff(context: Context): Boolean {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val lastAttemptAt = prefs.getLong(KEY_LAST_ATTEMPT_AT, 0L)
            if (lastAttemptAt > 0L && System.currentTimeMillis() - lastAttemptAt < RECENT_ATTEMPT_WINDOW_MS) {
                return true
            }
            val infos = WorkManager.getInstance(context).getWorkInfosForUniqueWork(SYNC_UNIQUE).get()
            return infos.any { it.state == WorkInfo.State.RUNNING || it.state == WorkInfo.State.ENQUEUED }
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
                lastStage = prefs.getString(KEY_LAST_STAGE, ""),
                lastStageAtMs = prefs.getLong(KEY_LAST_STAGE_AT, 0L).takeIf { it > 0 },
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
