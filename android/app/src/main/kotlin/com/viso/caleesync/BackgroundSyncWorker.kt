package com.viso.caleesync

import android.content.Context
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
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class CaleeSyncPeriodicWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        if (!runLock.compareAndSet(false, true)) {
            Log.i("CaleeSyncWorker", "skip trigger=${inputData.getString("trigger")} because another run is active")
            return Result.retry()
        }
        try {
        return runSyncTask(applicationContext, inputData.getString("trigger") ?: "periodic")
        } finally {
            runLock.set(false)
        }
    }

    companion object {
        private const val CHANNEL = "caleesync/background_sync"
        private const val PERIODIC_UNIQUE = "CaleeSyncPeriodicWorker"
        private const val ONE_OFF_UNIQUE = "CaleeSyncOneTimeWorker"
        private val runLock = AtomicBoolean(false)

        private fun constraints(): Constraints {
            return Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .setRequiresBatteryNotLow(true)
                .setRequiresStorageNotLow(true)
                .build()
        }

        fun schedulePeriodic(context: Context, intervalMinutes: Int): Operation {
            val bounded = intervalMinutes.coerceAtLeast(15).toLong()
            val request = PeriodicWorkRequestBuilder<CaleeSyncPeriodicWorker>(bounded, TimeUnit.MINUTES)
                .setConstraints(constraints())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
                .build()
            return WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(PERIODIC_UNIQUE, ExistingPeriodicWorkPolicy.UPDATE, request)
        }

        fun ensurePeriodic(context: Context, intervalMinutes: Int) {
            val infos = WorkManager.getInstance(context).getWorkInfosForUniqueWork(PERIODIC_UNIQUE).get()
            if (infos.any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.RUNNING }) return
            schedulePeriodic(context, intervalMinutes)
        }

        fun cancelPeriodic(context: Context): Operation {
            return WorkManager.getInstance(context).cancelUniqueWork(PERIODIC_UNIQUE)
        }

        fun enqueueOneOff(context: Context, reason: String, expedited: Boolean): Operation {
            val builder = OneTimeWorkRequestBuilder<CaleeSyncPeriodicWorker>()
                .setConstraints(constraints())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
                .setInputData(androidx.work.workDataOf("trigger" to reason))
            if (expedited) {
                builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            }
            return WorkManager.getInstance(context)
                .enqueueUniqueWork(ONE_OFF_UNIQUE, ExistingWorkPolicy.KEEP, builder.build())
        }

        fun readStatus(context: Context): Map<String, Any?> {
            val prefs = context.getSharedPreferences("calee_sync_bg", Context.MODE_PRIVATE)
            val periodicInfos = WorkManager.getInstance(context).getWorkInfosForUniqueWork(PERIODIC_UNIQUE).get()
            val periodicEnabled = periodicInfos.any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.RUNNING }
            val nextAt = prefs.getLong("periodic_next_at", 0L).takeIf { it > 0 }
            return mapOf(
                "periodicEnabled" to periodicEnabled,
                "lastRunAtMs" to prefs.getLong("last_run_at", 0L).takeIf { it > 0 },
                "lastResult" to prefs.getString("last_result", "unknown"),
                "lastReason" to prefs.getString("last_reason", ""),
                "nextScheduledAtMs" to nextAt,
            )
        }

        private fun runSyncTask(context: Context, trigger: String): Result {
            val prefs = context.getSharedPreferences("calee_sync_bg", Context.MODE_PRIVATE)
            prefs.edit().putLong("last_run_at", System.currentTimeMillis()).apply()
            Log.i("CaleeSyncWorker", "enter trigger=$trigger")

            val engine = FlutterEngine(context)
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)
            GeneratedPluginRegistrant.registerWith(engine)
            val latch = CountDownLatch(1)
            var workerResult: Result = Result.failure()

            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "caleeSyncBackgroundEntrypoint",
                )
            )

            channel.invokeMethod("runBackgroundSync", mapOf("trigger" to trigger), object : MethodChannel.Result {
                override fun success(result: Any?) {
                    val map = result as? Map<*, *>
                    val state = map?.get("state")?.toString() ?: "failure"
                    val reason = map?.get("reason")?.toString() ?: "unknown"
                    prefs.edit().putString("last_reason", reason).apply()
                    workerResult = when (state) {
                        "success" -> Result.success()
                        "retry" -> Result.retry()
                        else -> Result.failure()
                    }
                    prefs.edit().putString("last_result", state).apply()
                    latch.countDown()
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    prefs.edit().putString("last_result", "retry").putString("last_reason", "$errorCode:$errorMessage").apply()
                    workerResult = Result.retry()
                    latch.countDown()
                }

                override fun notImplemented() {
                    prefs.edit().putString("last_result", "failure").putString("last_reason", "not_implemented").apply()
                    workerResult = Result.failure()
                    latch.countDown()
                }
            })

            latch.await(90, TimeUnit.SECONDS)
            prefs.edit().putLong("periodic_next_at", System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(15)).apply()
            engine.destroy()
            Log.i("CaleeSyncWorker", "exit result=$workerResult")
            return workerResult
        }
    }
}
