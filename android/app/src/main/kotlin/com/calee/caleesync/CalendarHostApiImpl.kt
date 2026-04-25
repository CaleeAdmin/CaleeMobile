package com.calee.caleesync

import android.Manifest
import android.accounts.Account
import android.accounts.AccountManager
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import java.util.TimeZone
import android.provider.CalendarContract
import android.util.Log
import androidx.core.content.ContextCompat

class CalendarHostApiImpl(private val context: Context) : NativeCalendarApi {

    private data class CalendarAccount(val name: String, val type: String)

    private fun getCalendarAccount(calendarId: String): CalendarAccount? {
        val projection = arrayOf(
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.ACCOUNT_TYPE
        )

        return context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            "${CalendarContract.Calendars._ID} = ?",
            arrayOf(calendarId),
            null
        )?.use { cursor ->
            if (!cursor.moveToFirst()) {
                return null
            }

            val accountName = cursor.getString(0)
            val accountType = cursor.getString(1)
            if (accountName.isNullOrEmpty() || accountType.isNullOrEmpty()) {
                null
            } else {
                CalendarAccount(accountName, accountType)
            }
        }
    }

    private fun buildSyncAdapterEventUri(baseUri: Uri, calendarId: String): Uri {
        val account = getCalendarAccount(calendarId)
        return baseUri.buildUpon()
            .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, account?.name ?: "")
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, account?.type ?: "")
            .build()
    }

    private fun shouldUseSyncAdapterForEvents(calendarId: String): Boolean {
        return getCalendarAccount(calendarId)?.type == CalendarConstants.ACCOUNT_TYPE
    }

    private fun buildEventWriteUri(baseUri: Uri, calendarId: String): Uri {
        return if (shouldUseSyncAdapterForEvents(calendarId)) {
            buildSyncAdapterEventUri(baseUri, calendarId)
        } else {
            baseUri
        }
    }

    companion object {
        
        private val CALENDAR_PROJECTION = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME, // 对应 accountName
            CalendarContract.Calendars.ACCOUNT_TYPE, // 对应 accountType
            CalendarContract.Calendars.OWNER_ACCOUNT,
            CalendarContract.Calendars.CAL_SYNC1,
            CalendarContract.Calendars.CALENDAR_COLOR,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
            CalendarContract.Calendars.VISIBLE,
            CalendarContract.Calendars.CALENDAR_LOCATION
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

    private fun ensureCalendarAccount(accountName: String): Account {
        val manager = AccountManager.get(context)
        val existing = manager.getAccountsByType(CalendarConstants.ACCOUNT_TYPE).firstOrNull { it.name == accountName }
        if (existing != null) return existing

        val account = Account(accountName, CalendarConstants.ACCOUNT_TYPE)
        manager.addAccountExplicitly(account, null, null)
        return account
    }

    private fun enforceCalendarSyncSettings(account: Account) {
        val canWriteSyncSettings = ContextCompat.checkSelfPermission(
            context,
            android.Manifest.permission.WRITE_SYNC_SETTINGS
        ) == PackageManager.PERMISSION_GRANTED

        if (!canWriteSyncSettings) {
            Log.w("CalendarSync", "WRITE_SYNC_SETTINGS not granted; skipping setIsSyncable/setSyncAutomatically")
            return
        }

        try {
            ContentResolver.setIsSyncable(account, CalendarConstants.CALENDAR_AUTHORITY, 1)
            ContentResolver.setSyncAutomatically(account, CalendarConstants.CALENDAR_AUTHORITY, true)
        } catch (se: SecurityException) {
            Log.w("CalendarSync", "No permission to update sync settings for ${account.name}", se)
        }
    }

    private fun ensureAccountAndSync(accountName: String): Account {
        val account = ensureCalendarAccount(accountName)
        enforceCalendarSyncSettings(account)
        return account
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
            // 检查权限
            val hasPermission = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.READ_CALENDAR
            ) == PackageManager.PERMISSION_GRANTED

            if (!hasPermission) {
                Log.w("CalendarNative", "getCalendars: READ_CALENDAR permission not granted")
                return calendars
            }

            val uri = CalendarContract.Calendars.CONTENT_URI

            // 不再按 VISIBLE 过滤，支持获取隐藏日历
            context.contentResolver.query(uri, CALENDAR_PROJECTION, null, null, null)?.use { cursor ->
                // 预先获取列索引，避免在循环中重复查找，同时处理字段可能不存在的情况
                val idIndex = cursor.getColumnIndex(CalendarContract.Calendars._ID)
                val nameIndex = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME)
                val accountNameIndex = cursor.getColumnIndex(CalendarContract.Calendars.ACCOUNT_NAME)
                val accountTypeIndex = cursor.getColumnIndex(CalendarContract.Calendars.ACCOUNT_TYPE)
                val ownerAccountIndex = cursor.getColumnIndex(CalendarContract.Calendars.OWNER_ACCOUNT)
                val calSync1Index = cursor.getColumnIndex(CalendarContract.Calendars.CAL_SYNC1)
                val colorIndex = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_COLOR)
                val accessLevelIndex = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL)
                val locationIndex = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_LOCATION)

                // _ID 是必需字段，如果不存在则无法继续
                if (idIndex < 0) {
                    Log.e("CalendarNative", "getCalendars: _ID column not found")
                    return calendars
                }

                while (cursor.moveToNext()) {
                    try {
                        val id = cursor.getLong(idIndex).toString()

                        // 安全获取可选字段，字段不存在时返回 null
                        val name = if (nameIndex >= 0) cursor.getString(nameIndex) else null
                        val accountName = if (accountNameIndex >= 0) cursor.getString(accountNameIndex) else null
                        val accountType = if (accountTypeIndex >= 0) cursor.getString(accountTypeIndex) else null
                        val ownerAccount = if (ownerAccountIndex >= 0) cursor.getString(ownerAccountIndex) else null
                        val calSync1 = if (calSync1Index >= 0) cursor.getString(calSync1Index) else null

                        // 处理颜色：Android 日历颜色是 ARGB 格式（0xAARRGGBB）
                        // Flutter 端期望 #RRGGBB 格式（会自动加上 0xFF alpha）
                        // 所以需要提取 RGB 部分，去掉 alpha 和 0x 前缀
                        val colorHex = if (colorIndex >= 0) {
                            val colorInt = cursor.getInt(colorIndex)
                            if (colorInt != -1) {
                                // 提取 RGB 部分（去掉 alpha 通道），格式化为 #RRGGBB
                                // 注意：0x00000000（黑色）是有效颜色，只有 -1 表示未设置
                                val rgb = colorInt and 0x00FFFFFF // 去掉 alpha，保留 RGB
                                String.format("#%06X", rgb)
                            } else {
                                null // 未设置颜色（-1）
                            }
                        } else {
                            null // 字段不存在
                        }

                        // 处理访问级别，默认视为只读（更安全）
                        val isReadOnly = if (accessLevelIndex >= 0) {
                            val accessLevel = cursor.getInt(accessLevelIndex)
                            accessLevel < CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR
                        } else {
                            true // 字段不存在时默认视为只读
                        }

                        val calendarLocation = if (locationIndex >= 0) cursor.getString(locationIndex) else null
                        val normalizedLocation = calendarLocation?.trim()?.takeIf { it.isNotEmpty() }
                        val isSubscription = normalizedLocation?.let {
                            it.startsWith("http://", ignoreCase = true) ||
                                it.startsWith("https://", ignoreCase = true) ||
                                it.startsWith("webcal://", ignoreCase = true)
                        } ?: false

                        calendars.add(
                            PlatformCalendar(
                                id = id,
                                name = name,
                                accountName = accountName,
                                accountType = accountType,
                                ownerAccount = ownerAccount,
                                calSync1 = calSync1,
                                color = colorHex,
                                isReadOnly = isReadOnly,
                                supportsEvents = true,
                                supportsTasks = false, // 原生 Android 日历不支持任务
                                isSubscription = isSubscription,
                                subscriptionUrl = if (isSubscription) normalizedLocation else null
                            )
                        )
                    } catch (e: Exception) {
                        // 跳过有问题的记录，继续处理其他日历，避免单条记录错误导致整个方法失败
                        Log.w("CalendarNative", "getCalendars: Failed to parse calendar record, skipping", e)
                    }
                }
            }
        } catch (e: SecurityException) {
            Log.e("CalendarNative", "getCalendars: SecurityException - permission denied", e)
        } catch (e: Exception) {
            Log.e("CalendarNative", "getCalendars error", e)
        }
        return calendars
    }

    override fun getEvents(calendarId: String, startMs: Long, endMs: Long): List<PlatformItem> {
        val items = mutableListOf<PlatformItem>()
        items.addAll(fetchEvents(calendarId, startMs, endMs))
        return items
    }

    override fun createCalendar(
        displayName: String,
        accountName: String,
        color: Long,
        callback: (Result<String?>) -> Unit
    ) {
        val accountType = CalendarConstants.ACCOUNT_TYPE
        val cr = context.contentResolver
        ensureAccountAndSync(accountName)

        // 1. 构建带有 SyncAdapter 标识的 URI
        val uri = CalendarContract.Calendars.CONTENT_URI.buildUpon()
            .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, accountType)
            .build()

        // 2. 准备日历元数据
        val values = ContentValues().apply {
            put(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
            put(CalendarContract.Calendars.ACCOUNT_TYPE, accountType)
            put(CalendarContract.Calendars.NAME, displayName)
            put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, displayName)

            // 使用传入的颜色，Android 系统需要的是补码格式的 Int
            put(CalendarContract.Calendars.CALENDAR_COLOR, color.toInt())
            // 权限设置：设为 OWNER 才能增删改查
            put(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL, CalendarContract.Calendars.CAL_ACCESS_OWNER)
            put(CalendarContract.Calendars.OWNER_ACCOUNT, accountName)

            // 关键：允许提醒和可见性
            put(CalendarContract.Calendars.VISIBLE, 1)
            put(CalendarContract.Calendars.SYNC_EVENTS, 1)
            put(CalendarContract.Calendars.CALENDAR_TIME_ZONE, TimeZone.getDefault().id)

            // 🌟 必须：允许同步适配器对事件进行操作
            put(CalendarContract.Calendars.CAN_ORGANIZER_RESPOND, 1)
            put(CalendarContract.Calendars.ALLOWED_REMINDERS, "0,1,2") // 允许方法：METHOD_DEFAULT, METHOD_ALERT, METHOD_EMAIL
            put(CalendarContract.Calendars.ALLOWED_AVAILABILITY, "0,1") // 允许：AVAILABILITY_BUSY, AVAILABILITY_FREE
        }

        try {
            val resultUri = cr.insert(uri, values)
            val newId = resultUri?.lastPathSegment

            if (newId != null) {
                enforceCalendarSyncSettings(Account(accountName, accountType))
                callback(Result.success(newId))
            } else {
                callback(Result.failure(Exception("Calendar creation failed: URI is null")))
            }
        } catch (e: Exception) {
            // 捕获权限异常或数据库异常
            callback(Result.failure(e))
        }
    }

    override fun deleteCalendar(calendarId: String, accountName: String, callback: (Result<Boolean>) -> Unit) {
        val idLong = calendarId.toLongOrNull()
        if (idLong == null) {
            // 如果不是纯数字，说明不是系统合法的日历 ID
            Log.e("CalendarSync", "Invalid ID received: $calendarId")
            callback(Result.success(false)) // 优雅返回而非崩溃
            return
        }
        // 建议在子线程执行
        Thread {
            try {
                val accountType = CalendarConstants.ACCOUNT_TYPE
                val cr = context.contentResolver
                val idLong = calendarId.toLongOrNull() ?: throw IllegalArgumentException("Invalid ID")

                // 1. 构建 URI
                val baseUri = ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, idLong)

                // 2. 优先尝试同步删除（彻底抹除数据，不留残余）
                val syncUri = baseUri.buildUpon()
                    .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
                    .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
                    .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, accountType)
                    .build()

                var rows = cr.delete(syncUri, null, null)

                // 3. 兜底方案
                if (rows <= 0) {
                    // 如果是手动添加的本地日历，可能不受 SyncAdapter 管辖
                    rows = cr.delete(baseUri, null, null)
                }

                callback(Result.success(rows > 0))
            } catch (e: Exception) {
                Log.e("CalendarSync", "Delete failed: ${e.message}")
                callback(Result.failure(e))
            }
        }.start()
    }

    private fun fetchEvents(calendarId: String, startMs: Long, endMs: Long): List<PlatformItem> {
        val eventList = mutableListOf<PlatformItem>()
        val uri = CalendarContract.Events.CONTENT_URI

        // 1. 完善投影，增加 UID 存储列和 DURATION 列
        val EVENT_PROJECTION = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.TITLE,
            CalendarContract.Events.DESCRIPTION,
            CalendarContract.Events.EVENT_LOCATION,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND,
            CalendarContract.Events.DURATION,
            CalendarContract.Events.ALL_DAY,
            CalendarContract.Events.UID_2445,
            CalendarContract.Events.EVENT_TIMEZONE
        )

        val selection = "${CalendarContract.Events.CALENDAR_ID} = ? AND " +
                "${CalendarContract.Events.DTSTART} >= ? AND " +
                "${CalendarContract.Events.DTSTART} <= ? AND " +
                "${CalendarContract.Events.DELETED} = 0"
        val selectionArgs = arrayOf(calendarId, startMs.toString(), endMs.toString())

        context.contentResolver.query(uri, EVENT_PROJECTION, selection, selectionArgs, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(cursor.getColumnIndexOrThrow(CalendarContract.Events._ID)).toString()

                // 统一 UID 来源，保证每次同步读取到同一个值。
                // 优先级：UID_2445 -> local_<id>
                val uid = resolveStableUid(cursor, id)

                val startTime = cursor.getLong(cursor.getColumnIndexOrThrow(CalendarContract.Events.DTSTART))
                var endTime = cursor.getLong(cursor.getColumnIndexOrThrow(CalendarContract.Events.DTEND))

                // 💡 处理重复日程没有 DTEND 的情况
                if (endTime <= 0) {
                    val duration = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Events.DURATION))
                    endTime = calculateEndTime(startTime, duration)
                }

                eventList.add(PlatformItem(
                    localId = id,
                    uid = uid,
                    title = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Events.TITLE)) ?: "",
                    notes = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Events.DESCRIPTION)),
                    location = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Events.EVENT_LOCATION)),
                    eventTimezone = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Events.EVENT_TIMEZONE)),
                    startTime = startTime,
                    endTime = endTime,
                    isAllDay = cursor.getInt(cursor.getColumnIndexOrThrow(CalendarContract.Events.ALL_DAY)) == 1,
                    status = 1L
                ))
            }
        }
        return eventList
    }

    private fun resolveStableUid(cursor: android.database.Cursor, id: String): String {
        val uidCandidates = listOf(CalendarContract.Events.UID_2445)

        for (column in uidCandidates) {
            val index = cursor.getColumnIndex(column)
            if (index >= 0) {
                val value = cursor.getString(index)?.trim()
                if (!value.isNullOrEmpty()) return value
            }
        }

        return "local_$id"
    }

    // 2. 实现计算结束时间的工具函数
    private fun calculateEndTime(startTime: Long, duration: String?): Long {
        if (duration.isNullOrEmpty()) return startTime

        return try {
            // RFC5545 Duration 格式简单处理: P3600S, PT1H 等
            // 生产环境建议使用 org.rfc5545.icu.DurationParser 或类似的正则解析
            val seconds = parseRFC5545Duration(duration)
            startTime + (seconds * 1000)
        } catch (e: Exception) {
            Log.e("CalendarHost", "Duration parse error: $duration", e)
            startTime
        }
    }

    // 简单的 Duration 解析逻辑 (示例处理 PT1H 或 P3600S)
    private fun parseRFC5545Duration(duration: String): Long {
        // 这是一个极简实现，仅处理秒数结尾的情况。
        // 如果你的应用涉及复杂重复日程，建议引入专门的 ICS 解析库
        val regex = """PT?(\d+)([SHM])""".toRegex()
        val match = regex.find(duration)
        return if (match != null) {
            val (value, unit) = match.destructured
            when (unit) {
                "S" -> value.toLong()
                "M" -> value.toLong() * 60
                "H" -> value.toLong() * 3600
                else -> 0L
            }
        } else 0L
    }


    override fun createEvent(
        calendarId: String,
        title: String,
        start: Long,
        end: Long,
        notes: String?,
        uid: String?,
        location: String?,
        eventTimezone: String?,
        isAllDay: Boolean?,
        callback: (Result<String?>) -> Unit
    ) {
        try {
            // 1. 自动寻找这个 calendarId 对应的 accountName
            // 这样可以避免 "accountName" 变量未定义的错误
            var foundAccountName = "Calee" // 默认兜底
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

            // 2. 仅对本应用账号类型使用 sync-adapter URI，其余账号走普通写入。
            val eventInsertUri = if (shouldUseSyncAdapterForEvents(calendarId)) {
                CalendarContract.Events.CONTENT_URI.buildUpon()
                    .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
                    .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, foundAccountName)
                    .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, CalendarConstants.ACCOUNT_TYPE)
                    .build()
            } else {
                CalendarContract.Events.CONTENT_URI
            }

            val allDay = isAllDay == true
            val resolvedStart = if (allDay) {
                AllDayUtcNormalizer.normalizeAllDayUtcDateBoundary(start, eventTimezone)
            } else {
                start
            }
            val resolvedEnd = if (allDay) {
                AllDayUtcNormalizer.normalizeAllDayUtcDateBoundary(end, eventTimezone)
            } else {
                end
            }
            val finalEnd = if (allDay && resolvedEnd <= resolvedStart) {
                resolvedStart + 24L * 60L * 60L * 1000L
            } else {
                resolvedEnd
            }
            val resolvedTimezone = if (allDay) "UTC" else (eventTimezone ?: TimeZone.getDefault().id)

            val values = ContentValues().apply {
                put(CalendarContract.Events.DTSTART, resolvedStart)
                put(CalendarContract.Events.DTEND, finalEnd)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DESCRIPTION, notes)
                put(CalendarContract.Events.CALENDAR_ID, calendarId.toLong())
                put(CalendarContract.Events.EVENT_TIMEZONE, resolvedTimezone)
                put(CalendarContract.Events.EVENT_END_TIMEZONE, resolvedTimezone)
                put(CalendarContract.Events.EVENT_LOCATION, location)
                put(CalendarContract.Events.ALL_DAY, if (allDay) 1 else 0)

                // 将 UID 写入安全字段，兼容不同 ROM/Provider 的读取行为。
                uid?.let {
                    put(CalendarContract.Events.UID_2445, it)
                }

                // 设置状态和忙闲，确保在系统日历 App 中可见
                put(CalendarContract.Events.STATUS, CalendarContract.Events.STATUS_CONFIRMED)
                put(CalendarContract.Events.AVAILABILITY, CalendarContract.Events.AVAILABILITY_BUSY)
            }

            // 3. 执行插入
            val resultUri = context.contentResolver.insert(eventInsertUri, values)
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

    override fun createOrUpdateEvent(
        request: CalendarEventRequest,
        callback: (Result<String?>) -> Unit
    ) {
        try {
            val contentResolver = context.contentResolver
            val allDay = request.isAllDay == true
            val resolvedStart = if (allDay) {
                AllDayUtcNormalizer.normalizeAllDayUtcDateBoundary(request.start, request.eventTimezone)
            } else {
                request.start
            }
            val resolvedEnd = if (allDay) {
                AllDayUtcNormalizer.normalizeAllDayUtcDateBoundary(request.end, request.eventTimezone)
            } else {
                request.end
            }
            val finalEnd = if (allDay && resolvedEnd <= resolvedStart) {
                resolvedStart + 24L * 60L * 60L * 1000L
            } else {
                resolvedEnd
            }
            val resolvedTimezone = if (allDay) "UTC" else (request.eventTimezone ?: TimeZone.getDefault().id)

            val baseValues = ContentValues().apply {
                put(CalendarContract.Events.DTSTART, resolvedStart)
                put(CalendarContract.Events.DTEND, finalEnd)
                put(CalendarContract.Events.TITLE, request.title)
                put(CalendarContract.Events.DESCRIPTION, request.notes)
                put(CalendarContract.Events.CALENDAR_ID, request.calendarId.toLong())
                put(CalendarContract.Events.EVENT_TIMEZONE, resolvedTimezone)
                put(CalendarContract.Events.EVENT_END_TIMEZONE, resolvedTimezone)
                put(CalendarContract.Events.EVENT_LOCATION, request.location)
                put(CalendarContract.Events.ALL_DAY, if (allDay) 1 else 0)
            }

            val values = ContentValues().apply {
                putAll(baseValues)
                // UID 需要稳定写入，确保后续 getEvents 始终能返回同一 UID。
                put(CalendarContract.Events.UID_2445, request.uid)
            }

            if (request.eventId != null && request.eventId.isNotEmpty()) {
                // --- 执行更新 UPDATE ---
                val rows = updateEventById(request.eventId, request.calendarId, values)

                if (rows > 0) {
                    callback(Result.success(request.eventId))
                } else {
                    val canonicalEventId = chooseCanonicalEventId(
                        findExistingEventIdsByUid(request.calendarId, request.uid)
                    )
                    if (canonicalEventId != null) {
                        val fallbackRows = updateEventById(canonicalEventId, request.calendarId, values)
                        if (fallbackRows > 0) {
                            callback(Result.success(canonicalEventId))
                            return
                        }
                    }
                    callback(Result.failure(Exception("Event with ID ${request.eventId} not found for update")))
                }
            } else {
                val canonicalEventId = chooseCanonicalEventId(
                    findExistingEventIdsByUid(request.calendarId, request.uid)
                )
                if (canonicalEventId != null) {
                    val rows = updateEventById(canonicalEventId, request.calendarId, values)
                    if (rows > 0) {
                        callback(Result.success(canonicalEventId))
                        return
                    }
                }

                // --- 执行插入 INSERT ---
                val syncAdapterUri = buildEventWriteUri(CalendarContract.Events.CONTENT_URI, request.calendarId)
                var uri = contentResolver.insert(syncAdapterUri, values)

                if (uri == null) {
                    // 部分 ROM/Provider 对 sync-adapter 参数支持不稳定，回退到普通写入。
                    uri = contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
                }

                if (uri != null) {
                    val newId = uri.lastPathSegment
                    callback(Result.success(newId))
                } else {
                    callback(Result.failure(Exception("Failed to insert calendar event")))
                }
            }
        } catch (e: Exception) {
            callback(Result.failure(e))
        }
    }

    private fun findExistingEventIdsByUid(calendarId: String, uid: String): List<String> {
        if (uid.isBlank()) {
            return emptyList()
        }

        val eventIds = mutableListOf<String>()
        val projection = arrayOf(CalendarContract.Events._ID)
        val selection = "${CalendarContract.Events.CALENDAR_ID} = ? AND " +
            "${CalendarContract.Events.UID_2445} = ? AND " +
            "${CalendarContract.Events.DELETED} = 0"
        val selectionArgs = arrayOf(calendarId, uid)

        context.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                eventIds.add(cursor.getLong(0).toString())
            }
        }

        return eventIds
    }

    private fun chooseCanonicalEventId(eventIds: List<String>): String? {
        return eventIds
            .mapNotNull { it.toLongOrNull() }
            .minOrNull()
            ?.toString()
    }

    private fun updateEventById(eventId: String, calendarId: String, values: ContentValues): Int {
        val parsedEventId = eventId.toLongOrNull() ?: return 0
        val eventBaseUri = ContentUris.withAppendedId(
            CalendarContract.Events.CONTENT_URI,
            parsedEventId
        )
        val syncAdapterUpdateUri = buildEventWriteUri(eventBaseUri, calendarId)
        return try {
            context.contentResolver.update(syncAdapterUpdateUri, values, null, null)
        } catch (iae: IllegalArgumentException) {
            context.contentResolver.update(eventBaseUri, values, null, null)
        }
    }

    override fun getSystemEventIds(calendarId: String, startMs: Long, endMs: Long): List<String> {
        val eventIds = mutableListOf<String>()
        val uri = CalendarContract.Events.CONTENT_URI
        val projection = arrayOf(CalendarContract.Events._ID)
        val selection = "${CalendarContract.Events.CALENDAR_ID} = ? AND " +
            "${CalendarContract.Events.DELETED} = 0 AND " +
            "${CalendarContract.Events.DTSTART} < ? AND " +
            "${CalendarContract.Events.DTEND} > ?"
        val selectionArgs = arrayOf(calendarId, endMs.toString(), startMs.toString())
        try {
            context.contentResolver.query(uri, projection, selection, selectionArgs, null)?.use { cursor ->
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

    override fun setCalendarEnabled(
        calendarId: String,
        accountName: String,
        enabled: Boolean,
        callback: (Result<Boolean>) -> Unit
    ) {
        try {
            val idLong = calendarId.toLongOrNull() ?: run {
                callback(Result.success(false))
                return
            }

            val account = ensureAccountAndSync(accountName)
            val values = ContentValues().apply {
                put(CalendarContract.Calendars.SYNC_EVENTS, if (enabled) 1 else 0)
                put(CalendarContract.Calendars.VISIBLE, if (enabled) 1 else 0)
            }

            val updateUri = ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, idLong)
                .buildUpon()
                .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
                .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, account.name)
                .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, account.type)
                .build()

            val rows = context.contentResolver.update(updateUri, values, null, null)
            callback(Result.success(rows > 0))
        } catch (e: Exception) {
            callback(Result.failure(e))
        }
    }

    override fun isCalendarAccountSyncEnabled(
        accountName: String,
        callback: (Result<Boolean>) -> Unit
    ) {
        try {
            val account = ensureCalendarAccount(accountName)
            val canReadSyncSettings = ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.READ_SYNC_SETTINGS
            ) == PackageManager.PERMISSION_GRANTED

            if (!canReadSyncSettings) {
                Log.w("CalendarSync", "READ_SYNC_SETTINGS not granted; cannot read sync state")
                callback(Result.success(true))
                return
            }

            val isSyncable = try {
                ContentResolver.getIsSyncable(account, CalendarConstants.CALENDAR_AUTHORITY) > 0
            } catch (se: SecurityException) {
                Log.w("CalendarSync", "No permission to read syncable state", se)
                true
            }
            val autoSync = try {
                ContentResolver.getSyncAutomatically(account, CalendarConstants.CALENDAR_AUTHORITY)
            } catch (se: SecurityException) {
                Log.w("CalendarSync", "No permission to read auto-sync state", se)
                true
            }
            callback(Result.success(isSyncable && autoSync))
        } catch (e: Exception) {
            callback(Result.failure(e))
        }
    }
}
