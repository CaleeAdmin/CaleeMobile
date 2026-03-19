import Foundation
import EventKit

/// Swift implementation of the Pigeon-generated `NativeCalendarApi` protocol,
/// backed by EventKit. This replaces the older Objective-C implementation.
@objc class CalendarHostApiImpl: NSObject, NativeCalendarApi {
  private var eventStore = EKEventStore()
  private var lastKnownEventAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

  // MARK: - Permission

  func requestPermission(forTask: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
    refreshEventStore()

    if hasReadableEventAccess() {
      DispatchQueue.main.async {
        completion(.success(true))
      }
      return
    }

    let permissionCompletion: (Bool, Error?) -> Void = { [weak self] granted, error in
      guard let self else { return }

      if let error = error {
        DispatchQueue.main.async {
          completion(.failure(
            FlutterError(code: "PERMISSION_ERROR", message: error.localizedDescription, details: nil)
          ))
        }
        return
      }

      if granted {
        self.refreshEventStore(force: true)
      } else {
        self.refreshEventStore()
      }

      let readable = self.hasReadableEventAccess()
      DispatchQueue.main.async {
        completion(.success(readable))
      }
    }

    if #available(iOS 17.0, *) {
      eventStore.requestFullAccessToEvents(completion: permissionCompletion)
    } else {
      eventStore.requestAccess(to: .event, completion: permissionCompletion)
    }
  }

  // MARK: - Calendars

  func getCalendars() throws -> [PlatformCalendar] {
    let store = try requireReadableEventStore()
    var calendars: [PlatformCalendar] = []

    // iOS grouping: Source (account) -> Calendar
    for source in store.sources {
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

  private func requireReadableEventStore() throws -> EKEventStore {
    refreshEventStore()
    if hasReadableEventAccess() {
      return eventStore
    }

    refreshEventStore(force: true)
    if hasReadableEventAccess() {
      return eventStore
    }

    throw FlutterError(
      code: "PERMISSION_DENIED",
      message: "Calendar access not authorized",
      details: ["authorizationStatus": authorizationStatusDescription()]
    )
  }

  private func refreshEventStore(force: Bool = false) {
    let currentStatus = EKEventStore.authorizationStatus(for: .event)
    let statusChanged = currentStatus != lastKnownEventAuthorizationStatus

    eventStore.reset()

    if force || statusChanged {
      eventStore = EKEventStore()
    }

    lastKnownEventAuthorizationStatus = currentStatus
  }

  private func authorizationStatusDescription() -> String {
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, *) {
      switch status {
      case .notDetermined: return "notDetermined"
      case .restricted: return "restricted"
      case .denied: return "denied"
      case .authorized: return "authorized"
      case .fullAccess: return "fullAccess"
      case .writeOnly: return "writeOnly"
      @unknown default: return "unknown"
      }
    }

    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
  }

  private func hasReadableEventAccess() -> Bool {
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, *) {
      return status == .fullAccess || status == .authorized
    }
    return status == .authorized
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
    let store = try requireReadableEventStore()
    guard let calendar = store.calendar(withIdentifier: calendarId) else {
      return []
    }

    let startDate = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000.0)
    let endDate = Date(timeIntervalSince1970: TimeInterval(endMs) / 1000.0)

    let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: [calendar])
    let events = store.events(matching: predicate)

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
    do {
      let store = try requireReadableEventStore()
      guard let calendar = store.calendar(withIdentifier: calendarId) else {
        completion(.failure(
          FlutterError(code: "NOT_FOUND", message: "Calendar not found", details: nil)
        ))
        return
      }

      let event = EKEvent(eventStore: store)
      event.calendar = calendar
      event.title = title
      event.notes = notes
      event.startDate = Date(timeIntervalSince1970: TimeInterval(start) / 1000.0)
      event.endDate = Date(timeIntervalSince1970: TimeInterval(end) / 1000.0)

      do {
        try store.save(event, span: .thisEvent, commit: true)
        completion(.success(event.eventIdentifier))
      } catch {
        completion(.failure(
          FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil)
        ))
      }
    } catch {
      completion(.failure(error))
    }
  }

  func createOrUpdateEvent(
    request: CalendarEventRequest,
    completion: @escaping (Result<String?, Error>) -> Void
  ) {
    do {
      let store = try requireReadableEventStore()
      guard let calendar = store.calendar(withIdentifier: request.calendarId) else {
        completion(.failure(
          FlutterError(code: "NOT_FOUND", message: "Calendar not found", details: nil)
        ))
        return
      }

      var event: EKEvent?
      if let eventId = request.eventId, !eventId.isEmpty {
        event = store.event(withIdentifier: eventId)
      }
      if event == nil {
        event = EKEvent(eventStore: store)
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
        try store.save(event, span: .thisEvent, commit: true)
        completion(.success(event.eventIdentifier))
      } catch {
        completion(.failure(
          FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil)
        ))
      }
    } catch {
      completion(.failure(error))
    }
  }

  func getSystemEventIds(calendarId: String) throws -> [String] {
    let store = try requireReadableEventStore()
    guard let calendar = store.calendar(withIdentifier: calendarId) else {
      return []
    }

    // There is no API for "all" events, so use a wide window (±1 year from now).
    let now = Date()
    let startDate = now.addingTimeInterval(-365 * 24 * 3600)
    let endDate = now.addingTimeInterval(365 * 24 * 3600)

    let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: [calendar])
    let events = store.events(matching: predicate)
    return events.compactMap { $0.eventIdentifier }
  }

  func deleteEvent(eventId: String) throws -> Bool {
    let store = try requireReadableEventStore()
    guard let event = store.event(withIdentifier: eventId) else {
      return false
    }

    do {
      try store.remove(event, span: .thisEvent, commit: true)
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
    do {
      let store = try requireReadableEventStore()
      guard let source = selectWritableEventSourceForCalendarCreation(store: store) else {
        completion(.failure(
          FlutterError(
            code: "SOURCE_ERROR",
            message: "No writable EventKit source available for calendar creation",
            details: [
              "accountName": accountName,
              "availableSources": store.sources.map {
                "\($0.title) [\(string(from: $0.sourceType))]"
              }
            ]
          )
        ))
        return
      }

      let calendar = EKCalendar(for: .event, eventStore: store)
      calendar.title = displayName
      calendar.source = source
      calendar.cgColor = colorFromInt64(color)

      do {
        try store.saveCalendar(calendar, commit: true)
        completion(.success(calendar.calendarIdentifier))
      } catch {
        completion(.failure(
          FlutterError(
            code: "SAVE_ERROR",
            message: "Failed to save calendar to source \(source.title) [\(string(from: source.sourceType))]: \(error.localizedDescription)",
            details: [
              "sourceTitle": source.title,
              "sourceType": string(from: source.sourceType),
              "underlyingError": error.localizedDescription,
              "accountName": accountName,
            ]
          )
        ))
      }
    } catch {
      completion(.failure(error))
    }
  }

  func deleteCalendar(
    calendarId: String,
    accountName: String,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    do {
      let store = try requireReadableEventStore()
      guard let calendar = store.calendar(withIdentifier: calendarId) else {
        completion(.success(false))
        return
      }
      do {
        try store.removeCalendar(calendar, commit: true)
        completion(.success(true))
      } catch {
        completion(.failure(
          FlutterError(code: "DELETE_ERROR", message: error.localizedDescription, details: nil)
        ))
      }
    } catch {
      completion(.failure(error))
    }
  }

  func modifyCalendarTitle(
    calendarId: String,
    newTitle: String,
    accountName: String,
    accountType: String,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    do {
      let store = try requireReadableEventStore()
      guard let calendar = store.calendar(withIdentifier: calendarId) else {
        completion(.failure(
          FlutterError(code: "NOT_FOUND", message: "Calendar not found", details: nil)
        ))
        return
      }

      calendar.title = newTitle
      do {
        try store.saveCalendar(calendar, commit: true)
        completion(.success(true))
      } catch {
        completion(.failure(
          FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil)
        ))
      }
    } catch {
      completion(.failure(error))
    }
  }

  func setCalendarEnabled(
    calendarId: String,
    accountName: String,
    enabled: Bool,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    do {
      let store = try requireReadableEventStore()
      // iOS does not have a direct "enable/disable" flag; visibility is managed by the system UI.
      // We keep this as a no-op that just checks calendar existence and returns success.
      guard store.calendar(withIdentifier: calendarId) != nil else {
        completion(.failure(
          FlutterError(code: "NOT_FOUND", message: "Calendar not found", details: nil)
        ))
        return
      }

      // Nothing to persist; report success.
      completion(.success(true))
    } catch {
      completion(.failure(error))
    }
  }

  func isCalendarAccountSyncEnabled(
    accountName: String,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    do {
      let store = try requireReadableEventStore()
      if findSource(forAccountName: accountName, store: store) != nil {
        completion(.success(true))
      } else {
        completion(.success(false))
      }
    } catch {
      completion(.failure(error))
    }
  }

  // MARK: - Source helpers

  private func selectWritableEventSourceForCalendarCreation(store: EKEventStore) -> EKSource? {
    if let defaultSource = store.defaultCalendarForNewEvents?.source {
      return defaultSource
    }

    let writableEventCalendars = store.calendars(for: .event).filter {
      $0.allowsContentModifications && $0.type != .subscription
    }

    if let existingWritableSource = writableEventCalendars.first?.source {
      return existingWritableSource
    }

    return store.sources.first(where: { $0.sourceType == .local })
  }

  private func findSource(forAccountName accountName: String, store: EKEventStore) -> EKSource? {
    return store.sources.first(where: { $0.title == accountName })
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
