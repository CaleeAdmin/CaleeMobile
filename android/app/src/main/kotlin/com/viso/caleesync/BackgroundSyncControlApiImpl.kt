package com.viso.caleesync

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class BackgroundSyncControlApiImpl(private val context: Context) : BackgroundSyncControlApi {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun schedulePeriodic(intervalMinutes: Long, callback: (Result<Unit>) -> Unit) {
        scope.launch {
            runCatching {
                CaleeSyncPeriodicWorker.schedulePeriodic(context, intervalMinutes.toInt())
            }.fold(
                onSuccess = { callback(Result.success(Unit)) },
                onFailure = { callback(Result.failure(it)) },
            )
        }
    }

    override fun cancelPeriodic(callback: (Result<Unit>) -> Unit) {
        scope.launch {
            runCatching {
                CaleeSyncPeriodicWorker.cancelPeriodic(context)
            }.fold(
                onSuccess = { callback(Result.success(Unit)) },
                onFailure = { callback(Result.failure(it)) },
            )
        }
    }

    override fun ensurePeriodicScheduled(intervalMinutes: Long, callback: (Result<Unit>) -> Unit) {
        scope.launch {
            runCatching {
                CaleeSyncPeriodicWorker.ensurePeriodic(context, intervalMinutes.toInt())
            }.fold(
                onSuccess = { callback(Result.success(Unit)) },
                onFailure = { callback(Result.failure(it)) },
            )
        }
    }

    override fun enqueueOneOff(reason: String, expedited: Boolean, enqueuePolicy: OneOffEnqueuePolicy, callback: (Result<Unit>) -> Unit) {
        scope.launch {
            runCatching {
                CaleeSyncPeriodicWorker.enqueueOneOff(context, reason, expedited, enqueuePolicy)
            }.fold(
                onSuccess = { callback(Result.success(Unit)) },
                onFailure = { callback(Result.failure(it)) },
            )
        }
    }

    override fun getBackgroundStatus(callback: (Result<BackgroundStatusDto>) -> Unit) {
        scope.launch {
            runCatching {
                CaleeSyncPeriodicWorker.readStatus(context)
            }.fold(
                onSuccess = { callback(Result.success(it)) },
                onFailure = { callback(Result.failure(it)) },
            )
        }
    }
}
