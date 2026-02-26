package com.viso.caleesync

import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.WorkManager
import androidx.work.testing.WorkManagerTestInitHelper
import org.junit.Assert.assertTrue
import java.util.concurrent.TimeUnit
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BackgroundSyncWatchdogReceiverInstrumentationTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        WorkManagerTestInitHelper.initializeTestWorkManager(context)
        context.getSharedPreferences("calee_sync_bg", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test
    fun watchdogAction_whenPeriodicEnabled_enqueuesSyncWork() {
        context.getSharedPreferences("calee_sync_bg", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("periodic_enabled", true)
            .putInt("periodic_interval_minutes", 15)
            .commit()

        val receiver = BackgroundSyncWatchdogReceiver()
        receiver.onReceive(context, Intent(CaleeSyncPeriodicWorker.ACTION_WATCHDOG))

        val deadline = System.currentTimeMillis() + TimeUnit.SECONDS.toMillis(5)
        var found = false
        while (System.currentTimeMillis() < deadline) {
            val infos = WorkManager.getInstance(context)
                .getWorkInfosForUniqueWork(CaleeSyncPeriodicWorker.SYNC_UNIQUE)
                .get()
            if (infos.isNotEmpty()) {
                found = true
                break
            }
            Thread.sleep(100)
        }

        assertTrue("Expected watchdog to enqueue unique sync work", found)
    }
}
