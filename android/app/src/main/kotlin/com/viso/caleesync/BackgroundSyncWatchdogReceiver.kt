package com.viso.caleesync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

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
                val interval = CaleeSyncPeriodicWorker.readConfiguredIntervalMinutes(context)
                CaleeSyncPeriodicWorker.ensurePeriodic(context, interval)
                CaleeSyncPeriodicWorker.enqueueOneOff(context, "watchdog", expedited = false)
                CaleeSyncPeriodicWorker.scheduleWatchdogAlarm(context, interval)
            }
        }
    }
}
