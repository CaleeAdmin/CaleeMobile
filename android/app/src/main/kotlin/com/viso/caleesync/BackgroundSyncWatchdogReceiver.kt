package com.viso.caleesync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class BackgroundSyncWatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            CaleeSyncPeriodicWorker.ACTION_WATCHDOG -> {
                if (!CaleeSyncPeriodicWorker.isPeriodicEnabled(context)) {
                    CaleeSyncPeriodicWorker.cancelWatchdogAlarm(context)
                    return
                }
                val pendingResult = goAsync()
                CoroutineScope(Dispatchers.Default).launch {
                    try {
                        val interval = CaleeSyncPeriodicWorker.readConfiguredIntervalMinutes(context)
                        CaleeSyncPeriodicWorker.ensurePeriodic(context, interval)
                        if (!CaleeSyncPeriodicWorker.shouldSkipWatchdogOneOff(context)) {
                            CaleeSyncPeriodicWorker.enqueueOneOff(context, "watchdog", expedited = false)
                        }
                        CaleeSyncPeriodicWorker.scheduleWatchdogAlarm(context, interval)
                    } finally {
                        pendingResult.finish()
                    }
                }
            }
        }
    }
}
