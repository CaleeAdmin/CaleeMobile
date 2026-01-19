package com.nextcloud.caleesync

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.provider.CalendarContract
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.TimeZone

class CalendarHostApiImpl(private val context: Context) : NativeCalendarApi {

    companion object {
        private val CALENDAR_PROJECTION = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME, // 对应 accountName
            CalendarContract.Calendars.ACCOUNT_TYPE, // 对应 accountType
            CalendarContract.Calendars.CALENDAR_COLOR,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
            CalendarContract.Calendars.VISIBLE
        )

        private val EVENT_PROJECTION = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.TITLE,
            CalendarContract.Events.DESCRIPTION,
            CalendarContract.Events.EVENT_LOCATION,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND,
            CalendarContract.Events.ALL_DAY,
            CalendarContract.Events.LAST_DATE,
            CalendarContract.Events.CALENDAR_ID,
            )
    }

    override fun requestPermission(forTask: Boolean, callback: (Result<Boolean>) -> Unit) {
        try {
            val hasPermission = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.READ_CALENDAR
            ) == PackageManager.PERMISSION_GRANTED &&
                    ContextCompat.checkSelfPermission(
                        context,
                        Manifest.permission.WRITE_CALENDAR
                    ) == PackageManager.PERMISSION_GRANTED

            callback(Result.success(hasPermission))
        } catch (e: Exception) {
            callback(Result.failure(e))
        }
    }

    override fun getCalendars(): List<PlatformCalendar> {
        val calendars = mutableListOf<PlatformCalendar>()
        try {
            val uri = CalendarContract.Calendars.CONTENT_URI
            context.contentResolver.query(uri, CALENDAR_PROJECTION, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(cursor.getColumnIndexOrThrow(CalendarContract.Calendars._ID)).toString()
                    val name = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME))
                    val accountName = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Calendars.ACCOUNT_NAME))
                    val accountType = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Calendars.ACCOUNT_TYPE))
                    val colorInt = cursor.getInt(cursor.getColumnIndexOrThrow(CalendarContract.Calendars.CALENDAR_COLOR))
                    val colorHex = String.format("#%06X", (0xFFFFFF and colorInt))
                    val accessLevel = cursor.getInt(cursor.getColumnIndexOrThrow(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL))

                    // 权限判定：如果不是贡献者或所有者，则视为只读
                    val isReadOnly = accessLevel < CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR

                    calendars.add(PlatformCalendar(
                        id = id,
                        name = name,
                        accountName = accountName,
                        accountType = accountType,
                        color = colorHex,
                        isReadOnly = isReadOnly,
                        supportsEvents = true,
                        supportsTasks = false // 原生 Android 日历不支持任务
                    ))
                }
            }
        } catch (e: Exception) {
            Log.e("CalendarNative", "getCalendars error", e)
        }
        return calendars
    }

    override fun getEvents(calendarId: String, startMs: Long, endMs: Long): List<PlatformItem> {
        val items = mutableListOf<PlatformItem>()
        items.addAll(fetchEvents(calendarId, startMs, endMs))
        items.addAll(fetchTasks(calendarId))
        return items
    }

    private fun fetchEvents(calendarId: String, startMs: Long, endMs: Long): List<PlatformItem> {
        val eventList = mutableListOf<PlatformItem>()
        val uri = CalendarContract.Events.CONTENT_URI

        val selection = "${CalendarContract.Events.CALENDAR_ID} = ? AND ${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ? AND ${CalendarContract.Events.DELETED} = 0"
        val selectionArgs = arrayOf(calendarId, startMs.toString(), endMs.toString())

        context.contentResolver.query(uri, EVENT_PROJECTION, selection, selectionArgs, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(cursor.getColumnIndexOrThrow(CalendarContract.Events._ID)).toString()

                val uid = "system_event_$id"

                eventList.add(PlatformItem(
                    localId = id,
                    uid = uid,
                    title = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Events.TITLE)) ?: "",
                    notes = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Events.DESCRIPTION)),
                    startTime = cursor.getLong(cursor.getColumnIndexOrThrow(CalendarContract.Events.DTSTART)),
                    endTime = cursor.getLong(cursor.getColumnIndexOrThrow(CalendarContract.Events.DTEND)),
                    lastModified = cursor.getLong(cursor.getColumnIndexOrThrow(CalendarContract.Events.LAST_DATE)),
                    isTask = false,
                    isAllDay = cursor.getInt(cursor.getColumnIndexOrThrow(CalendarContract.Events.ALL_DAY)) == 1,
                    status = 1L
                ))
            }
        }
        return eventList
    }

    private fun fetchTasks(calendarId: String): List<PlatformItem> {
        val taskList = mutableListOf<PlatformItem>()
        val taskUri = Uri.parse("content://org.dmfs.tasks/tasks")
        try {
            val projection = arrayOf("_id", "title", "description", "status", "is_closed", "dtstart", "due", "last_modified", "uid")
            context.contentResolver.query(taskUri, projection, "list_id = ?", arrayOf(calendarId), null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(cursor.getColumnIndexOrThrow("_id")).toString()
                    val isClosed = cursor.getInt(cursor.getColumnIndexOrThrow("is_closed")) == 1
                    taskList.add(PlatformItem(
                        localId = id,
                        uid = cursor.getString(cursor.getColumnIndexOrThrow("uid")) ?: "task_$id",
                        title = cursor.getString(cursor.getColumnIndexOrThrow("title")) ?: "",
                        notes = cursor.getString(cursor.getColumnIndexOrThrow("description")),
                        startTime = cursor.getLong(cursor.getColumnIndexOrThrow("dtstart")),
                        endTime = cursor.getLong(cursor.getColumnIndexOrThrow("due")),
                        lastModified = cursor.getLong(cursor.getColumnIndexOrThrow("last_modified")),
                        isTask = true,
                        status = if (isClosed) 2L else cursor.getInt(cursor.getColumnIndexOrThrow("status")).toLong()
                    ))
                }
            }
        } catch (e: Exception) {
            return emptyList()
        }
        return taskList
    }

    override fun createEvent(
        calendarId: String,
        title: String,
        start: Long,
        end: Long,
        notes: String?,
        uid: String?, // 接收 Flutter 传过来的 UUID
        callback: (Result<String?>) -> Unit
    ) {
        try {
            val values = ContentValues().apply {
                put(CalendarContract.Events.DTSTART, start)
                put(CalendarContract.Events.DTEND, end)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DESCRIPTION, notes)
                put(CalendarContract.Events.CALENDAR_ID, calendarId.toLong())
                put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
                put(CalendarContract.Events.STATUS, CalendarContract.Events.STATUS_CONFIRMED)
            }

            val uri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
            callback(Result.success(uri?.lastPathSegment))
        } catch (e: Exception) {
            callback(Result.failure(e))
        }
    }

    override fun getSystemEventIds(calendarId: String): List<String> {
        val eventIds = mutableListOf<String>()
        val uri = CalendarContract.Events.CONTENT_URI
        val projection = arrayOf(CalendarContract.Events._ID)
        try {
            context.contentResolver.query(uri, projection, "${CalendarContract.Events.CALENDAR_ID} = ? AND ${CalendarContract.Events.DELETED} = 0", arrayOf(calendarId), null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    eventIds.add(cursor.getLong(0).toString())
                }
            }
        } catch (e: Exception) {
            Log.e("CalendarNative", "getSystemEventIds error", e)
        }
        return eventIds
    }

    override fun deleteEvent(eventId: String): Boolean {
        return try {
            val deleteUri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId.toLong())
            val rowsDeleted = context.contentResolver.delete(deleteUri, null, null)
            rowsDeleted > 0
        } catch (e: Exception) {
            false
        }
    }
}