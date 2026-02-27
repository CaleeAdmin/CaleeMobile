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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
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

        var stage = STAGE_ENGINE_CREATED
        val attemptStartedAt = System.currentTimeMillis()
        val workerResult = withTimeoutOrNull(WORKER_EXEC_TIMEOUT_MS) {
            suspendCancellableCoroutine<WorkResult> { continuation ->
                Handler(Looper.getMainLooper()).post {
                    try {
                        val holder = BackgroundEngineHolder.acquire(context, prefs) { updatedStage ->
                            stage = updatedStage
                            persistStage(prefs, stage)
                        }
                        invokeRunBackgroundSync(
                            runnerApi = holder.runnerApi,
                            trigger = trigger,
                            prefs = prefs,
                            continuation = continuation,
                            attemptStartedAt = attemptStartedAt,
                            stageProvider = { stage },
                            stageSetter = {
                                stage = it
                                persistStage(prefs, stage)
                            }
                        ) { continuation.isActive }
                    } catch (t: Throwable) {
                        val reason = when (t.message) {
                            "dart_not_ready" -> "dart_not_ready"
                            "ping_failed" -> "engine_ping_failed"
                            else -> "engine_init_error"
                        }
                        persistFailureContext(
                            prefs = prefs,
                            failureStage = stage,
                            failureStep = reason,
                            elapsedMs = System.currentTimeMillis() - attemptStartedAt,
                        )
                        persistSnapshot(
                            prefs = prefs,
                            outcome = BackgroundRunOutcome.RETRY,
                            reason = reason,
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
            persistFailureContext(
                prefs = prefs,
                failureStage = stage,
                failureStep = "worker_execution_timeout",
                elapsedMs = System.currentTimeMillis() - attemptStartedAt,
            )
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
        continuation: Continuation<WorkResult>,
        attemptStartedAt: Long,
        stageProvider: () -> String,
        stageSetter: (String) -> Unit,
        isActive: () -> Boolean,
    ) {
        stageSetter(STAGE_RUN_SYNC_SENT)
        val runReturned = AtomicLong(0L)

        Thread {
            Thread.sleep(SYNC_REPLY_TIMEOUT_MS)
            if (runReturned.compareAndSet(0L, 1L) && isActive()) {
                persistFailureContext(
                    prefs = prefs,
                    failureStage = stageProvider(),
                    failureStep = "sync_reply_timeout",
                    elapsedMs = System.currentTimeMillis() - attemptStartedAt,
                )
                persistSnapshot(
                    prefs = prefs,
                    outcome = BackgroundRunOutcome.RETRY,
                    reason = "engine_killed_or_no_reply",
                    gateReason = BackgroundGateReason.UNKNOWN,
                    error = "sync_reply_timeout",
                )
                safeResume(continuation, WorkResult.retry()) { isActive() }
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
                    safeResume(continuation, mapped) { isActive() }
                },
                onFailure = { error ->
                    stageSetter(STAGE_RUN_SYNC_REPLIED)
                    persistFailureContext(
                        prefs = prefs,
                        failureStage = stageProvider(),
                        failureStep = "runner_channel_error",
                        elapsedMs = System.currentTimeMillis() - attemptStartedAt,
                    )
                    persistSnapshot(
                        prefs = prefs,
                        outcome = BackgroundRunOutcome.RETRY,
                        reason = "runner_channel_error",
                        gateReason = BackgroundGateReason.UNKNOWN,
                        error = error.message,
                    )
                    safeResume(continuation, WorkResult.retry()) { isActive() }
                },
            )
        }
    }

    private fun safeResume(
        continuation: Continuation<WorkResult>,
        result: WorkResult,
        isActive: () -> Boolean,
    ) {
        if (!isActive()) return
        runCatching { continuation.resume(result) }
            .onFailure { resumeError -> Log.w(TAG, "resume skipped due to inactive/duplicate completion", resumeError) }
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
        private const val KEY_LAST_FAILURE_STAGE = "last_failure_stage"
        private const val KEY_LAST_FAILURE_ELAPSED_MS = "last_failure_elapsed_ms"
        private const val KEY_LAST_FAILURE_STEP = "last_failure_step"

        private const val STAGE_ENGINE_CREATED = "ENGINE_CREATED"
        private const val STAGE_DART_ENTRYPOINT_STARTED = "DART_ENTRYPOINT_STARTED"
        private const val STAGE_DART_READY_RECEIVED = "DART_READY_RECEIVED"
        private const val STAGE_RUN_SYNC_SENT = "RUN_SYNC_SENT"
        private const val STAGE_RUN_SYNC_REPLIED = "RUN_SYNC_REPLIED"
        private const val STAGE_WORKER_FINISHED = "WORKER_FINISHED"
        const val DART_READY_TIMEOUT_MS = 60_000L
        private const val SYNC_REPLY_TIMEOUT_MS = 90_000L
        private const val WORKER_EXEC_TIMEOUT_MS = 180_000L
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

        private fun persistFailureContext(
            prefs: android.content.SharedPreferences,
            failureStage: String,
            failureStep: String,
            elapsedMs: Long,
        ) {
            prefs.edit()
                .putString(KEY_LAST_FAILURE_STAGE, failureStage)
                .putLong(KEY_LAST_FAILURE_ELAPSED_MS, elapsedMs)
                .putString(KEY_LAST_FAILURE_STEP, failureStep)
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

        suspend fun enqueueOneOff(
            context: Context,
            reason: String,
            expedited: Boolean,
            enqueuePolicy: OneOffEnqueuePolicy = OneOffEnqueuePolicy.KEEP,
        ): Operation {
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

            val policy = if (enqueuePolicy == OneOffEnqueuePolicy.REPLACE) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP
            return WorkManager.getInstance(context)
                .enqueueUniqueWork(SYNC_UNIQUE, policy, request)
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

        private fun stateName(infos: List<WorkInfo>): String? {
            return infos.firstOrNull()?.state?.name
        }

        suspend fun readStatus(context: Context): BackgroundStatusDto {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val periodicInfos = awaitFuture(WorkManager.getInstance(context).getWorkInfosForUniqueWork(PERIODIC_UNIQUE))
            val syncInfos = awaitFuture(WorkManager.getInstance(context).getWorkInfosForUniqueWork(SYNC_UNIQUE))
            val periodicEnabled = prefs.getBoolean(KEY_PERIODIC_ENABLED, false)
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
                periodicWorkState = stateName(periodicInfos),
                oneOffWorkState = stateName(syncInfos),
                lastFailureStage = prefs.getString(KEY_LAST_FAILURE_STAGE, ""),
                lastFailureElapsedMs = prefs.getLong(KEY_LAST_FAILURE_ELAPSED_MS, 0L).takeIf { it > 0 },
                lastFailureStep = prefs.getString(KEY_LAST_FAILURE_STEP, ""),
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

private object BackgroundEngineHolder {
    private val lock = Any()
    private var active: ActiveEngine? = null

    data class ActiveEngine(
        val engine: FlutterEngine,
        val runnerApi: BackgroundSyncRunnerApi,
        val readyLatch: CountDownLatch,
        val generation: Long,
    )

    fun acquire(
        context: Context,
        prefs: android.content.SharedPreferences,
        stageSetter: (String) -> Unit,
    ): ActiveEngine {
        synchronized(lock) {
            val current = active
            if (current != null && waitForReady(current, stageSetter)) {
                return current
            }
            if (current != null) {
                destroyCurrent("stale_or_unhealthy")
            }
            val created = create(context, prefs, stageSetter)
            if (!waitForReady(created, stageSetter)) {
                destroy(created, "dart_not_ready")
                throw IllegalStateException("dart_not_ready")
            }
            stageSetter("HEALTHCHECK_SENT")
            if (!ping(created.runnerApi)) {
                destroy(created, "ping_failed")
                val recreated = create(context, prefs, stageSetter)
                if (!waitForReady(recreated, stageSetter)) {
                    destroy(recreated, "dart_not_ready_after_recreate")
                    throw IllegalStateException("dart_not_ready")
                }
                stageSetter("HEALTHCHECK_SENT")
                if (!ping(recreated.runnerApi)) {
                    destroy(recreated, "ping_failed_after_recreate")
                    throw IllegalStateException("ping_failed")
                }
                active = recreated
                return recreated
            }
            active = created
            return created
        }
    }

    private fun waitForReady(activeEngine: ActiveEngine, stageSetter: (String) -> Unit): Boolean {
        val ready = activeEngine.readyLatch.await(CaleeSyncPeriodicWorker.DART_READY_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        if (ready) {
            stageSetter("DART_READY_RECEIVED")
        }
        return ready
    }

    private fun ping(runnerApi: BackgroundSyncRunnerApi): Boolean {
        val latch = CountDownLatch(1)
        var healthy = false
        runnerApi.pingBackgroundIsolate { result ->
            healthy = result.getOrElse { false }
            latch.countDown()
        }
        latch.await(10, TimeUnit.SECONDS)
        return healthy
    }

    private fun create(
        context: Context,
        prefs: android.content.SharedPreferences,
        stageSetter: (String) -> Unit,
    ): ActiveEngine {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)

        val engine = FlutterEngine(context)
        stageSetter("ENGINE_CREATED")

        val calendarApi = CalendarHostApiImpl(context)
        NativeCalendarApi.setUp(engine.dartExecutor.binaryMessenger, calendarApi)

        val readyLatch = CountDownLatch(1)
        val runnerHostApi = object : BackgroundSyncRunnerHostApi {
            override fun notifyBackgroundIsolateReady(contractVersion: Long, callback: (Result<Unit>) -> Unit) {
                prefs.edit().putLong("last_ready_version", contractVersion).apply()
                stageSetter("DART_READY_RECEIVED")
                readyLatch.countDown()
                callback(Result.success(Unit))
            }
        }
        BackgroundSyncRunnerHostApi.setUp(engine.dartExecutor.binaryMessenger, runnerHostApi)

        stageSetter("DART_ENTRYPOINT_STARTED")
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "caleeSyncBackgroundEntrypoint"),
        )
        return ActiveEngine(
            engine = engine,
            runnerApi = BackgroundSyncRunnerApi(engine.dartExecutor.binaryMessenger),
            readyLatch = readyLatch,
            generation = System.nanoTime(),
        )
    }

    private fun destroyCurrent(reason: String) {
        active?.let { destroy(it, reason) }
        active = null
    }

    private fun destroy(activeEngine: ActiveEngine, reason: String) {
        Log.w("CaleeSyncWorker", "Destroying unhealthy engine generation=${activeEngine.generation} reason=$reason")
        Handler(Looper.getMainLooper()).post {
            runCatching { activeEngine.engine.destroy() }
        }
    }
}
