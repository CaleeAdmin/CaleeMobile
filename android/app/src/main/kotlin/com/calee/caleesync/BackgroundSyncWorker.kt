package com.calee.caleesync

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
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
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException

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

        val runLease = tryAcquireRunLease(trigger)
        if (runLease == null) {
            val active = activeRunLeaseSnapshot()
            Log.w(
                TAG,
                "run skipped due to active run trigger=$trigger activeRunId=${active?.runId} activeTrigger=${active?.trigger} activeStartedAt=${active?.startedAt}",
            )
            return WorkResult.retry()
        }

        val runToken = UUID.randomUUID().toString()
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit().putLong(KEY_LAST_RUN_AT, System.currentTimeMillis()).apply()
        Log.i(TAG, "Worker start trigger=$trigger runToken=$runToken")

        var stage = STAGE_ENGINE_CREATED
        val attemptStartedAt = System.currentTimeMillis()
        val workerResult = try {
            withTimeout(WORKER_EXEC_TIMEOUT_MS) {
                val stageSetter: (String) -> Unit = {
                    stage = it
                    persistStage(prefs, stage)
                }
                BackgroundEngineHolder.startOrReuseOnMain(context, runToken, trigger)
                stageSetter(STAGE_DART_ENTRYPOINT_STARTED)

                when (BackgroundEngineHolder.awaitDartReadyOnWorker(runToken, DART_READY_TIMEOUT_MS)) {
                    BackgroundEngineHolder.ReadyResult.READY -> {
                        stageSetter(STAGE_DART_READY_RECEIVED)
                    }
                    BackgroundEngineHolder.ReadyResult.NOT_READY_TIMEOUT -> {
                        stageSetter(STAGE_DART_READY_TIMEOUT)
                        throw IllegalStateException("dart_not_ready")
                    }
                    BackgroundEngineHolder.ReadyResult.CANCELLED -> {
                        stageSetter(STAGE_DART_READY_TIMEOUT)
                        throw IllegalStateException("worker_cancelled")
                    }
                }

                stageSetter(STAGE_RUN_SYNC_SENT)
                BackgroundEngineHolder.invokeRunOnMain(runToken, BackgroundRunRequest(trigger, CONTRACT_VERSION.toLong()))
                when (val runResult = BackgroundEngineHolder.awaitRunReplyOnWorker(runToken, SYNC_REPLY_TIMEOUT_MS)) {
                    is BackgroundEngineHolder.RunResult.REPLY -> {
                        stageSetter(STAGE_RUN_SYNC_REPLIED)
                        val result = runResult.payload
                        persistSnapshot(
                            prefs = prefs,
                            outcome = result.outcome,
                            reason = result.reason,
                            gateReason = result.gateReason,
                            error = result.error,
                        )
                        mapOutcomeToWorkerResult(result.outcome)
                    }
                    is BackgroundEngineHolder.RunResult.NO_REPLY_TIMEOUT -> {
                        stageSetter(STAGE_RUN_SYNC_TIMEOUT)
                        throw IllegalStateException("sync_reply_timeout")
                    }
                    is BackgroundEngineHolder.RunResult.CHANNEL_ERROR -> {
                        stageSetter(STAGE_RUN_SYNC_REPLIED)
                        throw IllegalStateException("runner_channel_error:${runResult.message}")
                    }
                    is BackgroundEngineHolder.RunResult.CANCELLED -> {
                        stageSetter(STAGE_RUN_SYNC_TIMEOUT)
                        throw IllegalStateException("worker_cancelled")
                    }
                }
            }
        } catch (t: Throwable) {
            val elapsedMs = System.currentTimeMillis() - attemptStartedAt
            val reason = when {
                t is TimeoutCancellationException -> "worker_execution_timeout"
                t.message == "dart_not_ready" -> "dart_not_ready"
                t.message == "sync_reply_timeout" -> "sync_reply_timeout"
                t.message?.startsWith("runner_channel_error") == true -> "runner_channel_error"
                t.message == "worker_cancelled" -> "worker_cancelled"
                else -> "engine_or_run_error"
            }
            Log.e(TAG, "Worker failure message=${t.message} stage=$stage elapsedMs=$elapsedMs reason=$reason", t)
            withContext(Dispatchers.Main.immediate) {
                BackgroundEngineHolder.markUnhealthyAndDestroyOnMain(reason)
            }
            persistFailureContext(
                prefs = prefs,
                failureStage = stage,
                failureStep = reason,
                elapsedMs = elapsedMs,
            )
            persistSnapshot(
                prefs = prefs,
                outcome = BackgroundRunOutcome.RETRY,
                reason = reason,
                gateReason = BackgroundGateReason.UNKNOWN,
                error = t.message,
            )
            persistStage(prefs, stage)
            WorkResult.retry()
        } finally {
            val elapsedMs = System.currentTimeMillis() - attemptStartedAt
            Log.i(TAG, "Worker finished trigger=$trigger runToken=$runToken stage=$stage elapsedMs=$elapsedMs")
            releaseRunLease(runLease)
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
        Log.i(TAG, "exit result=$workerResult runToken=$runToken")
        return workerResult
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
        private const val STAGE_DART_READY_TIMEOUT = "DART_READY_TIMEOUT"
        private const val STAGE_RUN_SYNC_SENT = "RUN_SYNC_SENT"
        private const val STAGE_RUN_SYNC_REPLIED = "RUN_SYNC_REPLIED"
        private const val STAGE_RUN_SYNC_TIMEOUT = "RUN_SYNC_TIMEOUT"
        private const val STAGE_WORKER_FINISHED = "WORKER_FINISHED"
        const val DART_READY_TIMEOUT_MS = 60_000L
        private const val WORKER_EXEC_TIMEOUT_MS = 180_000L
        private const val SYNC_REPLY_TIMEOUT_MS = WORKER_EXEC_TIMEOUT_MS - 10_000L
        private const val RECENT_ATTEMPT_WINDOW_MS = 30_000L

        const val PERIODIC_UNIQUE = "CaleeSyncPeriodicWorker"
        const val SYNC_UNIQUE = "CaleeSyncSyncWorker"
        private const val WATCHDOG_INTERVAL_MINUTES = 20L
        private const val WATCHDOG_REQUEST_CODE = 90241
        const val ACTION_WATCHDOG = "com.calee.caleesync.ACTION_BACKGROUND_SYNC_WATCHDOG"
        private val runLeaseLock = Any()
        private val runIdCounter = AtomicLong(0L)
        private var activeRunLease: ActiveRunLease? = null

        private data class ActiveRunLease(
            val runId: Long,
            val trigger: String,
            val startedAt: Long,
        )

        private fun tryAcquireRunLease(trigger: String): Long? {
            synchronized(runLeaseLock) {
                if (activeRunLease != null) {
                    return null
                }
                val runId = runIdCounter.incrementAndGet()
                activeRunLease = ActiveRunLease(runId = runId, trigger = trigger, startedAt = System.currentTimeMillis())
                return runId
            }
        }

        private fun releaseRunLease(runId: Long?) {
            synchronized(runLeaseLock) {
                if (runId != null && activeRunLease?.runId == runId) {
                    activeRunLease = null
                }
            }
        }

        private fun activeRunLeaseSnapshot(): ActiveRunLease? {
            synchronized(runLeaseLock) {
                return activeRunLease
            }
        }

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
    private const val TAG = "CaleeSyncWorker"

    enum class HolderState {
        IDLE,
        STARTING,
        READY,
        RUNNING,
        UNHEALTHY,
    }

    enum class ReadyResult {
        READY,
        NOT_READY_TIMEOUT,
        CANCELLED,
    }

    sealed class RunResult {
        data class REPLY(val payload: BackgroundRunResult) : RunResult()
        data object NO_REPLY_TIMEOUT : RunResult()
        data class CHANNEL_ERROR(val message: String?) : RunResult()
        data object CANCELLED : RunResult()
    }

    data class EngineHandle(
        val generation: Long,
    )

    private val lock = Any()
    private val holderScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private var engine: FlutterEngine? = null
    private var runnerApi: BackgroundSyncRunnerApi? = null
    private var generation: Long = 0L
    private var state: HolderState = HolderState.IDLE
    private var dartReady: Boolean = false
    private var activeRunToken: String? = null
    private var readyDeferred: CompletableDeferred<ReadyResult>? = null
    private var runDeferred: CompletableDeferred<RunResult>? = null

    suspend fun startOrReuseOnMain(context: Context, runToken: String, trigger: String): EngineHandle = runOnMain {
        requireMainThread("startOrReuseOnMain")
        val shouldCreate = synchronized(lock) {
            val unhealthy = state == HolderState.UNHEALTHY
            state = if (engine != null && dartReady && !unhealthy) HolderState.READY else HolderState.STARTING
            activeRunToken = runToken
            readyDeferred = CompletableDeferred()
            runDeferred = CompletableDeferred()
            engine == null || unhealthy
        }
        if (shouldCreate) {
            val nextGeneration = synchronized(lock) { generation + 1 }
            Log.i(TAG, "Creating new engine gen=$nextGeneration trigger=$trigger runToken=$runToken")
            createEngineOnMain(context.applicationContext)
        }

        synchronized(lock) {
            if (engine != null && dartReady) {
                state = HolderState.READY
                readyDeferred?.takeIf { !it.isCompleted }?.complete(ReadyResult.READY)
                Log.i(TAG, "Reusing existing engine gen=$generation trigger=$trigger runToken=$runToken")
            } else {
                state = HolderState.STARTING
            }
            EngineHandle(generation = generation)
        }
    }

    suspend fun awaitDartReadyOnWorker(runToken: String, timeoutMs: Long): ReadyResult {
        requireNotMainThread("awaitDartReadyOnWorker")
        val deferred = synchronized(lock) {
            if (activeRunToken != runToken) {
                Log.w(TAG, "dart_not_ready: token mismatch expected=$activeRunToken actual=$runToken generation=$generation")
                return ReadyResult.NOT_READY_TIMEOUT
            }
            if (dartReady && engine != null && state != HolderState.UNHEALTHY) {
                return ReadyResult.READY
            }
            readyDeferred ?: CompletableDeferred<ReadyResult>().also { readyDeferred = it }
        }
        return try {
            withTimeout(timeoutMs) { deferred.await() }
        } catch (_: TimeoutCancellationException) {
            Log.e(TAG, "dart_not_ready: timeout timeoutMs=$timeoutMs runToken=$runToken generation=$generation")
            markUnhealthy("dart_ready_timeout:$runToken")
            requestDestroyOnMain("dart_ready_timeout:$runToken")
            ReadyResult.NOT_READY_TIMEOUT
        } catch (_: kotlinx.coroutines.CancellationException) {
            markUnhealthy("dart_ready_cancelled:$runToken")
            requestDestroyOnMain("dart_ready_cancelled:$runToken")
            ReadyResult.CANCELLED
        }
    }

    suspend fun invokeRunOnMain(runToken: String, request: BackgroundRunRequest) = runOnMain {
        requireMainThread("invokeRunOnMain")
        val (api, runGen) = synchronized(lock) {
            check(activeRunToken == runToken) { "invokeRunOnMain token mismatch expected=$activeRunToken actual=$runToken" }
            check(state == HolderState.READY) { "invokeRunOnMain requires READY state, actual=$state" }
            state = HolderState.RUNNING
            Pair(runnerApi ?: error("Runner API unavailable"), generation)
        }

        api.runBackgroundSync(request) { response ->
            holderScope.launch(Dispatchers.Main.immediate) {
                val result = response.fold(
                    onSuccess = { RunResult.REPLY(it) },
                    onFailure = { RunResult.CHANNEL_ERROR(it.message) },
                )
                onRunReply(runToken = runToken, callbackGeneration = runGen, result = result)
            }
        }
    }

    suspend fun awaitRunReplyOnWorker(runToken: String, timeoutMs: Long): RunResult {
        requireNotMainThread("awaitRunReplyOnWorker")
        val deferred = synchronized(lock) {
            if (activeRunToken != runToken) {
                return RunResult.NO_REPLY_TIMEOUT
            }
            runDeferred ?: CompletableDeferred<RunResult>().also { runDeferred = it }
        }
        return try {
            withTimeout(timeoutMs) { deferred.await() }
        } catch (_: TimeoutCancellationException) {
            markUnhealthy("run_reply_timeout:$runToken")
            requestDestroyOnMain("run_reply_timeout:$runToken")
            RunResult.NO_REPLY_TIMEOUT
        } catch (_: kotlinx.coroutines.CancellationException) {
            markUnhealthy("run_reply_cancelled:$runToken")
            requestDestroyOnMain("run_reply_cancelled:$runToken")
            RunResult.CANCELLED
        }
    }

    suspend fun destroyOnMain(reason: String) = runOnMain {
        requireMainThread("destroyOnMain")
        val engineToDestroy = synchronized(lock) {
            val toDestroy = engine
            engine = null
            runnerApi = null
            state = HolderState.IDLE
            dartReady = false
            activeRunToken = null
            readyDeferred?.takeIf { !it.isCompleted }?.complete(ReadyResult.NOT_READY_TIMEOUT)
            runDeferred?.takeIf { !it.isCompleted }?.complete(RunResult.NO_REPLY_TIMEOUT)
            readyDeferred = null
            runDeferred = null
            toDestroy
        }
        if (engineToDestroy != null) {
            Log.w(TAG, "Destroying engine generation=$generation reason=$reason")
            runCatching { engineToDestroy.destroy() }
                .onFailure { Log.w(TAG, "engine destroy failed reason=$reason", it) }
        }
    }

    fun markUnhealthy(reason: String) {
        synchronized(lock) {
            state = HolderState.UNHEALTHY
            dartReady = false
            activeRunToken = null
            readyDeferred?.takeIf { !it.isCompleted }?.complete(ReadyResult.NOT_READY_TIMEOUT)
            runDeferred?.takeIf { !it.isCompleted }?.complete(RunResult.NO_REPLY_TIMEOUT)
        }
        Log.w(TAG, "Engine marked unhealthy reason=$reason generation=$generation")
    }

    suspend fun markUnhealthyAndDestroyOnMain(reason: String) {
        markUnhealthy(reason)
        destroyOnMain(reason)
    }

    private fun requestDestroyOnMain(reason: String) {
        holderScope.launch(Dispatchers.Main.immediate) {
            destroyOnMain(reason)
        }
    }

    private fun createEngineOnMain(context: Context) {
        requireMainThread("createEngineOnMain")
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)

        val nextEngine = FlutterEngine(context)
        NativeCalendarApi.setUp(nextEngine.dartExecutor.binaryMessenger, CalendarHostApiImpl(context))

        val engineGen = synchronized(lock) {
            generation += 1
            engine = nextEngine
            runnerApi = BackgroundSyncRunnerApi(nextEngine.dartExecutor.binaryMessenger)
            dartReady = false
            state = HolderState.STARTING
            generation
        }
        Log.i(TAG, "Engine created gen=$engineGen")

        BackgroundSyncRunnerHostApi.setUp(
            nextEngine.dartExecutor.binaryMessenger,
            object : BackgroundSyncRunnerHostApi {
                override fun notifyBackgroundIsolateReady(contractVersion: Long, callback: (Result<Unit>) -> Unit) {
                    callback(Result.success(Unit))
                    onDartReady(engineGen)
                }
            },
        )

        nextEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "caleeSyncBackgroundEntrypoint"),
        )
    }

    private fun onDartReady(callbackGeneration: Long) {
        requireMainThread("onDartReady")
        synchronized(lock) {
            if (callbackGeneration != generation) {
                Log.w(TAG, "Ignoring stale dart ready callback callbackGen=$callbackGeneration generation=$generation")
                return
            }
            dartReady = true
            state = HolderState.READY
            readyDeferred?.takeIf { !it.isCompleted }?.complete(ReadyResult.READY)
        }
    }

    private fun onRunReply(runToken: String, callbackGeneration: Long, result: RunResult) {
        requireMainThread("onRunReply")
        synchronized(lock) {
            if (runToken != activeRunToken || callbackGeneration != generation) {
                Log.w(TAG, "Ignoring stale run reply token=$runToken active=$activeRunToken callbackGen=$callbackGeneration generation=$generation")
                return
            }
            state = HolderState.READY
            runDeferred?.takeIf { !it.isCompleted }?.complete(result)
        }
    }

    private suspend fun <T> runOnMain(block: () -> T): T {
        return withContext(Dispatchers.Main.immediate) { block() }
    }

    private fun requireMainThread(operation: String) {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "$operation must run on the main thread"
        }
    }

    private fun requireNotMainThread(operation: String) {
        check(Looper.myLooper() != Looper.getMainLooper()) {
            "$operation must never run on main thread"
        }
    }
}
