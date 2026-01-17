package com.nextcloud.caleesync

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import com.nextcloud.caleesync.PlatformCalendar
import com.nextcloud.caleesync.PlatformItem
import com.nextcloud.caleesync.NativeCalendarApi

class CalendarHostApiImpl(private val context: Context) : NativeCalendarApi {

    companion object {
        private val CALENDAR_PROJECTION = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.NAME,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
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
            CalendarContract.Events.CALENDAR_ID
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
            val cursor = context.contentResolver.query(
                uri,
                CALENDAR_PROJECTION,
                null,
                null,
                null
            )

            cursor?.use {
                while (it.moveToNext()) {
                    val id = it.getLong(it.getColumnIndexOrThrow(CalendarContract.Calendars._ID)).toString()
                    val name = it.getString(it.getColumnIndexOrThrow(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME))
                    val color = "#${Integer.toHexString(it.getInt(it.getColumnIndexOrThrow(CalendarContract.Calendars.CALENDAR_COLOR)))}"
                    val accessLevel = it.getInt(it.getColumnIndexOrThrow(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL))
                    val isReadOnly = accessLevel == CalendarContract.Calendars.CAL_ACCESS_READ
                    val visible = it.getInt(it.getColumnIndexOrThrow(CalendarContract.Calendars.VISIBLE)) == 1

                    // Android Calendar Provider 主要支持事件，不直接支持任务
                    // 但可以通过扩展属性或自定义字段来支持
                    calendars.add(PlatformCalendar(
                        id = id,
                        name = name,
                        color = color,
                        isReadOnly = isReadOnly,
                        supportsEvents = true,
                        supportsTasks = false // Android 原生不支持任务，但可以通过扩展实现
                    ))
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }

        return calendars
    }

    override fun getItems(calendarId: String, startMs: Long, endMs: Long): List<PlatformItem> {
        val items = mutableListOf<PlatformItem>()

        // 1. 先抓取活动 (Events)
        items.addAll(fetchEvents(calendarId, startMs, endMs))

        // 2. 再抓取任务 (Tasks)
        items.addAll(fetchTasks(calendarId))

        return items
    }

    // 1. 更新你的投影数组
    private val EVENT_PROJECTION = arrayOf(
        CalendarContract.Events._ID,
        CalendarContract.Events.TITLE,
        CalendarContract.Events.DESCRIPTION,
        CalendarContract.Events.EVENT_LOCATION,
        CalendarContract.Events.DTSTART,
        CalendarContract.Events.DTEND,
        CalendarContract.Events.ALL_DAY,
        CalendarContract.Events.LAST_DATE, // 对应 lastDate
        CalendarContract.Events.CALENDAR_ID,
        CalendarContract.Events._SYNC_ID // <--- 必须加上这一行
    )

    // 2. 修改 fetchEvents 里的读取逻辑（增加安全性检查）
    private fun fetchEvents(calendarId: String, startMs: Long, endMs: Long): List<PlatformItem> {
        val eventList = mutableListOf<PlatformItem>()
        val uri = CalendarContract.Events.CONTENT_URI

        // 注意：selection 保持不变
        val selection = "${CalendarContract.Events.CALENDAR_ID} = ? AND ${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ?"
        val selectionArgs = arrayOf(calendarId, startMs.toString(), endMs.toString())

        context.contentResolver.query(uri, EVENT_PROJECTION, selection, selectionArgs, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(cursor.getColumnIndexOrThrow(CalendarContract.Events._ID)).toString()

                // 使用 safe get，防止某些本地日历确实没有 _sync_id
                val syncIdIndex = cursor.getColumnIndex(CalendarContract.Events._SYNC_ID)
                val syncId = if (syncIdIndex != -1) cursor.getString(syncIdIndex) else null

                // 如果没有系统 UID，我们用 "local_" + ID 拼接一个，确保唯一性
                val uid = syncId ?: "local_event_$id"

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
            // 建议明确指定 Projection，避免获取不需要的列
            val projection = arrayOf("_id", "title", "description", "status", "is_closed", "dtstart", "due", "last_modified", "uid")

            // 注意：有些系统的 list_id 可能是 Long，有些是 String，这里保持一致
            val selection = "list_id = ?"
            val selectionArgs = arrayOf(calendarId)

            context.contentResolver.query(taskUri, projection, selection, selectionArgs, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    // 使用 getColumnIndex 防止字段不存在时崩溃
                    val idIdx = cursor.getColumnIndex("_id")
                    val titleIdx = cursor.getColumnIndex("title")
                    val statusIdx = cursor.getColumnIndex("status")
                    val closedIdx = cursor.getColumnIndex("is_closed")
                    val uidIdx = cursor.getColumnIndex("uid")

                    val id = if (idIdx != -1) cursor.getLong(idIdx).toString() else ""
                    val title = if (titleIdx != -1) cursor.getString(titleIdx) ?: "" else ""
                    val isClosed = if (closedIdx != -1) cursor.getInt(closedIdx) == 1 else false

                    taskList.add(PlatformItem(
                        localId = id,
                        uid = if (uidIdx != -1) cursor.getString(uidIdx) else "task_$id",
                        title = title,
                        notes = if (cursor.getColumnIndex("description") != -1) cursor.getString(cursor.getColumnIndex("description")) else null,
                        startTime = if (cursor.getColumnIndex("dtstart") != -1) cursor.getLong(cursor.getColumnIndex("dtstart")) else 0L,
                        endTime = if (cursor.getColumnIndex("due") != -1) cursor.getLong(cursor.getColumnIndex("due")) else 0L,
                        lastModified = if (cursor.getColumnIndex("last_modified") != -1) cursor.getLong(cursor.getColumnIndex("last_modified")) else 0L,
                        isTask = true,
                        status = if (isClosed) 2L else (if (statusIdx != -1) cursor.getInt(statusIdx).toLong() else 0L)
                    ))
                }
            }
        } catch (e: Exception) {
            // 这里很重要：如果用户没装 OpenTasks，query 会抛出 SecurityException 或 NullPointerException
            // 我们返回空列表，代表该设备不支持从系统层面读 Task
            return emptyList()
        }
        return taskList
    }

    override fun upsertItem(calendarId: String, item: PlatformItem, callback: (Result<String>) -> Unit) {
        try {
            val values = ContentValues().apply {
                put(CalendarContract.Events.CALENDAR_ID, calendarId.toLong())
                put(CalendarContract.Events.TITLE, item.title ?: "")
                put(CalendarContract.Events.DESCRIPTION, item.notes)
                put(CalendarContract.Events.EVENT_LOCATION, item.location)
                put(CalendarContract.Events.DTSTART, item.startTime)
                put(CalendarContract.Events.DTEND, item.endTime)
                put(CalendarContract.Events.ALL_DAY, if (item.isAllDay == true) 1 else 0)
                put(CalendarContract.Events.EVENT_TIMEZONE, "UTC")
                put(CalendarContract.Events.STATUS, CalendarContract.Events.STATUS_CONFIRMED)
            }

            val uri = if (item.localId != null) {
                // 更新现有事件
                val eventUri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, item.localId!!.toLong())
                context.contentResolver.update(eventUri, values, null, null)
                item.localId!!
            } else {
                // 创建新事件
                val newUri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
                newUri?.lastPathSegment ?: throw Exception("Failed to create event")
            }

            callback(Result.success(uri))
        } catch (e: Exception) {
            callback(Result.failure(e))
        }
    }

    override fun deleteItem(localId: String, callback: (Result<Unit>) -> Unit) {
        try {
            val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, localId.toLong())
            val rowsDeleted = context.contentResolver.delete(uri, null, null)

            if (rowsDeleted > 0) {
                callback(Result.success(Unit))
            } else {
                callback(Result.failure(Exception("Event not found or could not be deleted")))
            }
        } catch (e: Exception) {
            callback(Result.failure(e))
        }
    }
}
