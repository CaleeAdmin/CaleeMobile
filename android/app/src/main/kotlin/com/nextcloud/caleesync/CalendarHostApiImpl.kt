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

    // CalendarHostApiImpl.kt 内部实现参考
    override fun createCalendar(displayName: String, accountName: String, callback: (Result<String?>) -> Unit) {
        try {
            val accountType = "com.nextcloud.caleesync"
            val cr = context.contentResolver

            val uri = CalendarContract.Calendars.CONTENT_URI.buildUpon()
                .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
                .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
                .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, accountType)
                .build()

            // 🌟 直接执行插入，不查询 existingId
            val values = ContentValues().apply {
                put(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
                put(CalendarContract.Calendars.ACCOUNT_TYPE, accountType)
                put(CalendarContract.Calendars.NAME, displayName)
                put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, displayName)
                put(CalendarContract.Calendars.CALENDAR_COLOR, -0xcc4a1b)
                put(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL, CalendarContract.Calendars.CAL_ACCESS_OWNER)
                put(CalendarContract.Calendars.OWNER_ACCOUNT, accountName)
                put(CalendarContract.Calendars.VISIBLE, 1)
                put(CalendarContract.Calendars.SYNC_EVENTS, 1)
                put(CalendarContract.Calendars.CALENDAR_TIME_ZONE, TimeZone.getDefault().id)
            }

            val resultUri = cr.insert(uri, values)
            val newId = resultUri?.lastPathSegment // 这次它会返回 8, 9, 10...

            callback(Result.success(newId))
        } catch (e: Exception) {
            callback(Result.failure(e))
        }
    }

    override fun deleteCalendar(calendarId: String, accountName: String, accountType: String, callback: (Result<Boolean>) -> Unit) {
        try {
            val cr = context.contentResolver
            val idLong = calendarId.toLong()

            // 尝试方式 A：带同步适配器参数（最安全，但对参数要求极严）
            val syncUri = ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, idLong)
                .buildUpon()
                .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
                .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
                .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, accountType)
                .build()

            var rows = cr.delete(syncUri, null, null)

            // 🌟 兜底方案 B：如果 A 失败了，尝试普通删除（不带账户参数）
            if (rows == 0) {
                Log.w("CalendarSync", "Sync delete failed, trying simple delete for ID: $calendarId")
                val simpleUri = ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, idLong)
                rows = cr.delete(simpleUri, null, null)
            }

            Log.d("CalendarSync", "Final delete result: $rows rows affected")
            callback(Result.success(rows > 0))
        } catch (e: Exception) {
            callback(Result.failure(e))
        }
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
        uid: String?,
        callback: (Result<String?>) -> Unit
    ) {
        try {
            // 1. 自动寻找这个 calendarId 对应的 accountName
            // 这样可以避免 "accountName" 变量未定义的错误
            var foundAccountName = "Nextcloud" // 默认兜底
            val calendarCursor = context.contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                arrayOf(CalendarContract.Calendars.ACCOUNT_NAME),
                "${CalendarContract.Calendars._ID} = ?",
                arrayOf(calendarId),
                null
            )
            calendarCursor?.use {
                if (it.moveToFirst()) {
                    foundAccountName = it.getString(0)
                }
            }

            // 2. 构建带有同步权限的 URI
            // 注意：ACCOUNT_TYPE 必须与你创建日历时写死的一致 (建议统一用 com.nextcloud.caleesync)
            val syncUri = CalendarContract.Events.CONTENT_URI.buildUpon()
                .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
                .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, foundAccountName)
                .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, "com.nextcloud.caleesync")
                .build()

            val values = ContentValues().apply {
                put(CalendarContract.Events.DTSTART, start)
                put(CalendarContract.Events.DTEND, end)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DESCRIPTION, notes)
                put(CalendarContract.Events.CALENDAR_ID, calendarId.toLong())
                put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)

                // 将 Nextcloud 的 UID 存入系统事件的 _SYNC_ID，这对防止重复同步非常重要
                uid?.let { put(CalendarContract.Events._SYNC_ID, it) }

                // 设置状态和忙闲，确保在系统日历 App 中可见
                put(CalendarContract.Events.STATUS, CalendarContract.Events.STATUS_CONFIRMED)
                put(CalendarContract.Events.AVAILABILITY, CalendarContract.Events.AVAILABILITY_BUSY)
            }

            // 3. 执行插入
            val resultUri = context.contentResolver.insert(syncUri, values)
            val newEventId = resultUri?.lastPathSegment

            if (newEventId != null) {
                Log.d("CalendarSync", "✅ 成功写入系统日历: $title, 系统ID: $newEventId")
                callback(Result.success(newEventId))
            } else {
                callback(Result.failure(Exception("Insert failed: URI is null")))
            }

        } catch (e: Exception) {
            Log.e("CalendarSync", "❌ 插入事件异常: ${e.message}")
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

    override fun modifyCalendarTitle(
        calendarId: String,
        newTitle: String,
        accountName: String,
        accountType: String,
        callback: (Result<Boolean>) -> Unit
    ) {
        try {
            val cr = context.contentResolver
            val idLong = calendarId.toLong()

            // 1. 构建更新的内容
            val values = ContentValues().apply {
                put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, newTitle)
                // 建议同步修改本地名称字段
                put(CalendarContract.Calendars.NAME, newTitle)
            }

            // 2. 构建带账户信息的 URI (作为同步适配器修改需要权限)
            val updateUri = ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, idLong)
                .buildUpon()
                .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
                .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
                .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, accountType)
                .build()

            // 3. 执行更新
            val rows = cr.update(updateUri, values, null, null)

            Log.d("CalendarSync", "Rename result: $rows rows affected for ID $calendarId")
            callback(Result.success(rows > 0))
        } catch (e: Exception) {
            Log.e("CalendarSync", "Rename failed: ${e.message}")
            callback(Result.failure(e))
        }
    }
}