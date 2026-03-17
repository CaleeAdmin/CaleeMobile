package com.calee.caleesync.service

import android.app.Service
import android.content.AbstractThreadedSyncAdapter
import android.content.ContentProviderClient
import android.content.Context
import android.content.Intent
import android.content.SyncResult
import android.os.Bundle
import android.os.IBinder

class SyncService : Service() {
    private var syncAdapter: SyncAdapter? = null

    override fun onCreate() {
        synchronized(lock) {
            if (syncAdapter == null) {
                syncAdapter = SyncAdapter(applicationContext, true)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = syncAdapter?.syncAdapterBinder

    class SyncAdapter(context: Context, autoInitialize: Boolean) :
        AbstractThreadedSyncAdapter(context, autoInitialize) {
        override fun onPerformSync(
            account: android.accounts.Account?,
            extras: Bundle?,
            authority: String?,
            provider: ContentProviderClient?,
            syncResult: SyncResult?
        ) {
            // 这里留空，因为同步逻辑是由你在 Flutter/Plugin 里手动触发的
        }
    }

    companion object {
        private val lock = Any()
    }
}