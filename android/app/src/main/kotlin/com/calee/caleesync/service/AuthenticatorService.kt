package com.calee.caleesync.service

import android.app.Service
import android.accounts.AbstractAccountAuthenticator
import android.accounts.Account
import android.accounts.AccountAuthenticatorResponse
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.IBinder

class AuthenticatorService : Service() {
    private lateinit var authenticator: Authenticator

    override fun onCreate() {
        authenticator = Authenticator(this)
    }

    override fun onBind(intent: Intent?): IBinder? = authenticator.iBinder

    class Authenticator(context: Context) : AbstractAccountAuthenticator(context) {
        override fun editProperties(r: AccountAuthenticatorResponse?, t: String?): Bundle? = null
        override fun addAccount(r: AccountAuthenticatorResponse?, t: String?, a: String?, o: Array<out String>?, b: Bundle?): Bundle? = null
        override fun confirmCredentials(r: AccountAuthenticatorResponse?, a: Account?, b: Bundle?): Bundle? = null
        override fun getAuthToken(r: AccountAuthenticatorResponse?, a: Account?, t: String?, b: Bundle?): Bundle? = null
        override fun getAuthTokenLabel(t: String?): String? = null
        override fun updateCredentials(r: AccountAuthenticatorResponse?, a: Account?, t: String?, b: Bundle?): Bundle? = null
        override fun hasFeatures(r: AccountAuthenticatorResponse?, a: Account?, f: Array<out String>?): Bundle? = null
    }
}