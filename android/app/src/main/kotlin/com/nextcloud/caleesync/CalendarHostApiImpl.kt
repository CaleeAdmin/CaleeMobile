package com.nextcloud.caleesync

import android.content.ContentResolver
import android.content.ContentUris
import android.database.Cursor
import android.net.Uri
import android.provider.CalendarContract
import android.util.Log

/**
 * Implementation of CalendarHostApi for Android using Calendar Provider.
 */
private object CalendarAccessLevel {
    // Calendar access level constants (from CalendarContract.Calendars)
    const val CAL_ACCESS_OWNER = 700
    const val CAL_ACCESS_EDITOR = 600
    const val CAL_ACCESS_CONTRIBUTOR = 500
    const val CAL_ACCESS_READ_ONLY = 400
}
class CalendarHostApiImpl(
    private val contentResolver: ContentResolver
) : CalendarHostApi {

    override fun listCalendars(): List<PigeonCalendar?> {
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.ACCOUNT_TYPE,
            CalendarContract.Calendars.OWNER_ACCOUNT,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.CALENDAR_COLOR,
            CalendarContract.Calendars.VISIBLE,
            CalendarContract.Calendars.SYNC_EVENTS,
            CalendarContract.Calendars.IS_PRIMARY,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL
        )
        val cursor: Cursor? = contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            null,
            null,
            null
        )
        val result = mutableListOf<PigeonCalendar?>()
        cursor?.use {
            val idxId = it.getColumnIndex(CalendarContract.Calendars._ID)
            val idxAccountName = it.getColumnIndex(CalendarContract.Calendars.ACCOUNT_NAME)
            val idxAccountType = it.getColumnIndex(CalendarContract.Calendars.ACCOUNT_TYPE)
            val idxOwnerAccount = it.getColumnIndex(CalendarContract.Calendars.OWNER_ACCOUNT)
            val idxDisplayName = it.getColumnIndex(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME)
            val idxColor = it.getColumnIndex(CalendarContract.Calendars.CALENDAR_COLOR)
            val idxVisible = it.getColumnIndex(CalendarContract.Calendars.VISIBLE)
            val idxSyncEvents = it.getColumnIndex(CalendarContract.Calendars.SYNC_EVENTS)
            val idxPrimary = it.getColumnIndex(CalendarContract.Calendars.IS_PRIMARY)
            val idxAccess = it.getColumnIndex(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL)
            
            while (it.moveToNext()) {
                val raw = mutableMapOf<String, Any?>()
                it.columnNames.forEach { col ->
                    val colIdx = it.getColumnIndex(col)
                    if (colIdx >= 0) {
                        val value = when (it.getType(colIdx)) {
                            Cursor.FIELD_TYPE_STRING -> it.getString(colIdx)
                            Cursor.FIELD_TYPE_INTEGER -> it.getLong(colIdx)
                            Cursor.FIELD_TYPE_FLOAT -> it.getDouble(colIdx)
                            Cursor.FIELD_TYPE_BLOB -> it.getBlob(colIdx)?.toString()
                            Cursor.FIELD_TYPE_NULL -> null
                            else -> null
                        }
                        raw[col] = value
                    }
                }
                Log.d("CalendarDebug", "Calendar raw: $raw")
                
                val calendarId = if (idxId >= 0) it.getLong(idxId) else 0L
                val accountName = if (idxAccountName >= 0) it.getString(idxAccountName) ?: "" else ""
                val accountType = if (idxAccountType >= 0) it.getString(idxAccountType) ?: "" else ""
                val displayName = if (idxDisplayName >= 0) it.getString(idxDisplayName) else null
                
                result.add(
                    PigeonCalendar(
                        id = calendarId,
                        accountName = accountName,
                        accountType = accountType,
                        ownerAccount = if (idxOwnerAccount >= 0) it.getString(idxOwnerAccount) else null,
                        name = displayName, // Use displayName as name
                        displayName = displayName,
                        color = if (idxColor >= 0) it.getInt(idxColor).toLong() else 0L,
                        visible = if (idxVisible >= 0) (it.getInt(idxVisible) == 1) else true,
                        syncEvents = if (idxSyncEvents >= 0) (it.getInt(idxSyncEvents) == 1) else true,
                        isPrimary = if (idxPrimary >= 0) (it.getInt(idxPrimary) == 1) else false,
                        isLocal = accountType.isEmpty() || accountType == "LOCAL", // Determine if local calendar
                        accessLevel = if (idxAccess >= 0) it.getInt(idxAccess).toLong() else 0L
                    )
                )
            }
        }
        return result
    }

    override fun listEvents(window: TimeWindow): List<PigeonEvent?> {
        val eventsUri: Uri = CalendarContract.Instances.CONTENT_URI.buildUpon().apply {
            ContentUris.appendId(this, window.startMillis)
            ContentUris.appendId(this, window.endMillis)
        }.build()

        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.EVENT_LOCATION,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.CALENDAR_ID,
            CalendarContract.Instances.EVENT_TIMEZONE,
            CalendarContract.Instances.DESCRIPTION
        )

        val selectionArgs = mutableListOf<String>()
        val selection = StringBuilder().apply {
            if (!window.calendarIds.isNullOrEmpty()) {
                append("${CalendarContract.Instances.CALENDAR_ID} IN (")
                append(window.calendarIds.joinToString(",") { "?" })
                append(")")
                selectionArgs.addAll(window.calendarIds.filterNotNull().map { it.toString() })
            }
        }.toString().ifEmpty { null }

        val cursor = contentResolver.query(
            eventsUri,
            projection,
            selection,
            if (selectionArgs.isEmpty()) null else selectionArgs.toTypedArray(),
            "${CalendarContract.Instances.BEGIN} ASC"
        )

        val result = mutableListOf<PigeonEvent?>()
        cursor?.use {
            val idxEventId = it.getColumnIndex(CalendarContract.Instances.EVENT_ID)
            val idxBegin = it.getColumnIndex(CalendarContract.Instances.BEGIN)
            val idxEnd = it.getColumnIndex(CalendarContract.Instances.END)
            val idxTitle = it.getColumnIndex(CalendarContract.Instances.TITLE)
            val idxLoc = it.getColumnIndex(CalendarContract.Instances.EVENT_LOCATION)
            val idxAllDay = it.getColumnIndex(CalendarContract.Instances.ALL_DAY)
            val idxCalId = it.getColumnIndex(CalendarContract.Instances.CALENDAR_ID)
            val idxTz = it.getColumnIndex(CalendarContract.Instances.EVENT_TIMEZONE)
            val idxDesc = it.getColumnIndex(CalendarContract.Instances.DESCRIPTION)
            
            while (it.moveToNext()) {
                val raw = mutableMapOf<String, Any?>()
                it.columnNames.forEach { col ->
                    val colIdx = it.getColumnIndex(col)
                    if (colIdx >= 0) {
                        val value = when (it.getType(colIdx)) {
                            Cursor.FIELD_TYPE_STRING -> it.getString(colIdx)
                            Cursor.FIELD_TYPE_INTEGER -> it.getLong(colIdx)
                            Cursor.FIELD_TYPE_FLOAT -> it.getDouble(colIdx)
                            Cursor.FIELD_TYPE_BLOB -> it.getBlob(colIdx)?.toString()
                            Cursor.FIELD_TYPE_NULL -> null
                            else -> null
                        }
                        raw[col] = value
                    }
                }
                Log.d("CalendarDebug", "Event raw: $raw")
                
                result.add(
                    PigeonEvent(
                        id = if (idxEventId >= 0) it.getLong(idxEventId).toString() else "",
                        calendarId = if (idxCalId >= 0) it.getLong(idxCalId).toString() else "",
                        title = if (idxTitle >= 0) it.getString(idxTitle) ?: "" else "",
                        startMillis = if (idxBegin >= 0) it.getLong(idxBegin) else 0L,
                        endMillis = if (idxEnd >= 0) it.getLong(idxEnd) else 0L,
                        location = if (idxLoc >= 0) it.getString(idxLoc) else null,
                        allDay = if (idxAllDay >= 0) (it.getInt(idxAllDay) == 1) else false,
                        timeZone = if (idxTz >= 0) it.getString(idxTz) else null,
                        description = if (idxDesc >= 0) it.getString(idxDesc) else null,
                        isCanceled = false // Calendar Provider doesn't have a direct canceled status
                    )
                )
            }
        }
        return result
    }
}

