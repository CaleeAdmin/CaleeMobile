import Foundation
import EventKit

/// Swift implementation of the Pigeon-generated `NativeCalendarApi` protocol,
/// backed by EventKit. This replaces the older Objective-C implementation.
@objc class CalendarHostApiImpl: NSObject, NativeCalendarApi {
  private let eventStore = EKEventStore()

  // MARK: - Permission

  func requestPermission(forTask: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
    eventStore.requestAccess(to: .event) { granted, error in
      if let error = error {
        completion(.failure(
          FlutterError(code: "PERMISSION_ERROR", message: error.localizedDescription, details: nil)
        ))
      } else {
        completion(.success(granted))
      }
    }
  }

  // MARK: - Calendars

  func getCalendars() throws -> [PlatformCalendar] {
    let status = EKEventStore.authorizationStatus(for: .event)
    guard status == .authorized else {
      throw FlutterError(
        code: "PERMISSION_DENIED",
        message: "Calendar access not authorized",
        details: nil
      )
    }

    var calendars: [PlatformCalendar] = []

    // iOS grouping: Source (account) -> Calendar
    for source in eventStore.sources {
      let ekCalendars = source.calendars(for: .event)
      for ekCalendar in ekCalendars {
        var pc = PlatformCalendar()
        pc.id = ekCalendar.calendarIdentifier
        pc.name = ekCalendar.title

        // Account grouping info
        pc.accountName = source.title
        pc.accountType = string(from: source.sourceType)

        // Color
        if let color = ekCalendar.cgColor,
           let components = color.components,
           components.count >= 3 {
          let r = Int(components[0] * 255.0)
          let g = Int(components[1] * 255.0)
          let b = Int(components[2] * 255.0)
          pc.color = String(format: "#%02X%02X%02X", r, g, b)
        }

        pc.isReadOnly = !ekCalendar.allowsContentModifications
        pc.supportsEvents = true
        pc.supportsTasks = false
        pc.isSubscription = (ekCalendar.type == .subscription)

        calendars.append(pc)
      }
    }

    return calendars
  }

  private func string(from type: EKSourceType) -> String {
    switch type {
    case .local: return "Local"
    case .exchange: return "Exchange"
    case .calDAV: return "CalDAV"
    case .mobileMe: return "iCloud"
    case .subscribed: return "Subscribed"
    case .birthdays: return "Birthdays"
    @unknown default: return "Other"
    }
  }

  // MARK: - Events

  func getEvents(calendarId: String, startMs: Int64, endMs: Int64) throws -> [PlatformItem] {
    guard let calendar = eventStore.calendar(withIdentifier: calendarId) else {
      return []
    }

    let startDate = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000.0)
    let endDate = Date(timeIntervalSince1970: TimeInterval(endMs) / 1000.0)

    let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: [calendar])
    let events = eventStore.events(matching: predicate)

    var items: [PlatformItem] = []
    for event in events {
      var item = PlatformItem()
      item.localId = event.eventIdentifier

      // Stable UID: prefer calendarItemExternalIdentifier, else local_<id>
      item.uid = resolveStableUid(for: event, localId: event.eventIdentifier)

      item.title = event.title ?? ""
      item.notes = event.notes
      item.location = event.location
      item.startTime = Int64(event.startDate.timeIntervalSince1970 * 1000.0)

      // End time: ensure it is after start, otherwise default to +1 hour
      var endDateEffective = event.endDate
      if endDateEffective == nil || endDateEffective! <= event.startDate {
        endDateEffective = event.startDate.addingTimeInterval(3600) // 1 hour default
      }
      if let endDateEffective {
        item.endTime = Int64(endDateEffective.timeIntervalSince1970 * 1000.0)
      }

      if let lastModified = event.lastModifiedDate {
        item.lastModified = Int64(lastModified.timeIntervalSince1970 * 1000.0)
      }

      item.isAllDay = event.isAllDay
      item.isTask = false
      item.status = 1 // 1 = confirmed

      items.append(item)
    }

    return items
  }

  private func resolveStableUid(for event: EKEvent, localId: String) -> String {
    if let externalId = event.calendarItemExternalIdentifier, !externalId.isEmpty {
      return externalId
    }
    return "local_\(localId)"
  }

  func createEvent(
    calendarId: String,
    title: String,
    start: Int64,
    end: Int64,
    notes: String?,
    uid: String?,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    guard let calendar = eventStore.calendar(withIdentifier: calendarId) else {
      completion(.failure(
        FlutterError(code: "NOT_FOUND", message: "Calendar not found", details: nil)
      ))
      return
    }

    let event = EKEvent(eventStore: eventStore)
    event.calendar = calendar
    event.title = title
    event.notes = notes
    event.startDate = Date(timeIntervalSince1970: TimeInterval(start) / 1000.0)
    event.endDate = Date(timeIntervalSince1970: TimeInterval(end) / 1000.0)

    do {
      try eventStore.save(event, span: .thisEvent, commit: true)
      completion(.success(event.eventIdentifier))
    } catch {
      completion(.failure(
        FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil)
      ))
    }
  }

  func createOrUpdateEvent(
    request: CalendarEventRequest,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    guard let calendar = eventStore.calendar(withIdentifier: request.calendarId) else {
      completion(.failure(
        FlutterError(code: "NOT_FOUND", message: "Calendar not found", details: nil)
      ))
      return
    }

    var event: EKEvent?
    if let eventId = request.eventId, !eventId.isEmpty {
      event = eventStore.event(withIdentifier: eventId)
    }
    if event == nil {
      event = EKEvent(eventStore: eventStore)
      event?.calendar = calendar
    }

    guard let event else {
      completion(.failure(
        FlutterError(code: "SAVE_ERROR", message: "Failed to create EKEvent", details: nil)
      ))
      return
    }

    event.title = request.title
    event.notes = request.notes
    event.startDate = Date(timeIntervalSince1970: TimeInterval(request.start) / 1000.0)
    event.endDate = Date(timeIntervalSince1970: TimeInterval(request.end) / 1000.0)

    do {
      try eventStore.save(event, span: .thisEvent, commit: true)
      completion(.success(event.eventIdentifier))
    } catch {
      completion(.failure(
        FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil)
      ))
    }
  }

  func getSystemEventIds(calendarId: String) throws -> [String] {
    guard let calendar = eventStore.calendar(withIdentifier: calendarId) else {
      return []
    }

    // There is no API for "all" events, so use a wide window (±1 year from now).
    let now = Date()
    let startDate = now.addingTimeInterval(-365 * 24 * 3600)
    let endDate = now.addingTimeInterval(365 * 24 * 3600)

    let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: [calendar])
    let events = eventStore.events(matching: predicate)
    return events.compactMap { $0.eventIdentifier }
  }

  func deleteEvent(eventId: String) throws -> Bool {
    guard let event = eventStore.event(withIdentifier: eventId) else {
      return false
    }

    do {
      try eventStore.remove(event, span: .thisEvent, commit: true)
      return true
    } catch {
      throw FlutterError(code: "DELETE_ERROR", message: error.localizedDescription, details: nil)
    }
  }

  // MARK: - Calendar management

  func createCalendar(
    displayName: String,
    accountName: String,
    color: Int64,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    guard let source = findOrCreateSource(forAccountName: accountName) else {
      completion(.failure(
        FlutterError(code: "SOURCE_ERROR", message: "Failed to find or create source", details: nil)
      ))
      return
    }

    let calendar = EKCalendar(for: .event, eventStore: eventStore)
    calendar.title = displayName
    calendar.source = source
    calendar.cgColor = colorFromInt64(color)

    do {
      try eventStore.saveCalendar(calendar, commit: true)
      completion(.success(calendar.calendarIdentifier))
    } catch {
      completion(.failure(
        FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil)
      ))
    }
  }

  func deleteCalendar(
    calendarId: String,
    accountName: String,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    guard let calendar = eventStore.calendar(withIdentifier: calendarId) else {
      completion(.success(false))
      return
    }
    do {
      try eventStore.removeCalendar(calendar, commit: true)
      completion(.success(true))
    } catch {
      completion(.failure(
        FlutterError(code: "DELETE_ERROR", message: error.localizedDescription, details: nil)
      ))
    }
  }

  func modifyCalendarTitle(
    calendarId: String,
    newTitle: String,
    accountName: String,
    accountType: String,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    guard let calendar = eventStore.calendar(withIdentifier: calendarId) else {
      completion(.failure(
        FlutterError(code: "NOT_FOUND", message: "Calendar not found", details: nil)
      ))
      return
    }

    calendar.title = newTitle
    do {
      try eventStore.saveCalendar(calendar, commit: true)
      completion(.success(true))
    } catch {
      completion(.failure(
        FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil)
      ))
    }
  }

  func setCalendarEnabled(
    calendarId: String,
    accountName: String,
    enabled: Bool,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    // iOS does not have a direct "enable/disable" flag; visibility is managed by the system UI.
    // We keep this as a no-op that just checks calendar existence and returns success.
    guard eventStore.calendar(withIdentifier: calendarId) != nil else {
      completion(.failure(
        FlutterError(code: "NOT_FOUND", message: "Calendar not found", details: nil)
      ))
      return
    }

    // Nothing to persist; report success.
    completion(.success(true))
  }

  func isCalendarAccountSyncEnabled(
    accountName: String,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    if findSource(forAccountName: accountName) != nil {
      completion(.success(true))
    } else {
      completion(.success(false))
    }
  }

  // MARK: - Source helpers

  private func findOrCreateSource(forAccountName accountName: String) -> EKSource? {
    if let existing = findSource(forAccountName: accountName) {
      return existing
    }

    // iOS sources are system-managed; we can't create new ones. Fallback to local or first available.
    let sources = eventStore.sources
    if let local = sources.first(where: { $0.sourceType == .local }) {
      return local
    }
    return sources.first
  }

  private func findSource(forAccountName accountName: String) -> EKSource? {
    return eventStore.sources.first(where: { $0.title == accountName })
  }

  // MARK: - Color helper

  private func colorFromInt64(_ colorValue: Int64) -> CGColor {
    // Android format: 0xAARRGGBB
    let alpha = CGFloat((colorValue >> 24) & 0xFF) / 255.0
    let red = CGFloat((colorValue >> 16) & 0xFF) / 255.0
    let green = CGFloat((colorValue >> 8) & 0xFF) / 255.0
    let blue = CGFloat(colorValue & 0xFF) / 255.0

    return UIColor(red: red, green: green, blue: blue, alpha: alpha).cgColor
  }
}


