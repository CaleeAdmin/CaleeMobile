import Foundation
import EventKit

/// Swift implementation of the Pigeon-generated `NativeCalendarApi` protocol,
/// backed by EventKit. This replaces the older Objective-C implementation.
@objc class CalendarHostApiImpl: NSObject, NativeCalendarApi {
  private let caleeUidMarkerPattern = #"\n?\[CALEE_UID:([^\]]+)\]"#
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
    case .fullAccess: return "fullAccess"
    case .writeOnly: return "writeOnly"
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
      let localId = stableLocalIdentifier(for: event)
      var item = PlatformItem()
      item.localId = localId
      item.uid = extractCaleeUid(from: event) ?? derivedUidFromExternalIdentifier(event) ?? "local_\(localId)"

      item.title = event.title ?? ""
      item.notes = stripCaleeMetadata(from: event.notes)
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

  private func embedCaleeUid(into event: EKEvent, uid: String, originalNotes: String?) {
    let cleanNotes = stripCaleeMetadata(from: originalNotes)
    let trimmedUid = uid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedUid.isEmpty else {
      event.notes = cleanNotes
      return
    }

    let marker = "[CALEE_UID:\(trimmedUid)]"
    if let cleanNotes, !cleanNotes.isEmpty {
      event.notes = "\(cleanNotes)\n\(marker)"
    } else {
      event.notes = marker
    }
  }

  private func extractCaleeUid(from event: EKEvent) -> String? {
    guard let notes = event.notes, !notes.isEmpty,
          let regex = try? NSRegularExpression(pattern: caleeUidMarkerPattern) else {
      return nil
    }

    let nsNotes = notes as NSString
    let range = NSRange(location: 0, length: nsNotes.length)
    guard let match = regex.firstMatch(in: notes, options: [], range: range), match.numberOfRanges > 1 else {
      return nil
    }

    let uid = nsNotes.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    return uid.isEmpty ? nil : uid
  }

  private func stripCaleeMetadata(from notes: String?) -> String? {
    guard let notes, !notes.isEmpty,
          let regex = try? NSRegularExpression(pattern: caleeUidMarkerPattern) else {
      return notes
    }

    let fullRange = NSRange(location: 0, length: (notes as NSString).length)
    let stripped = regex.stringByReplacingMatches(in: notes, options: [], range: fullRange, withTemplate: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return stripped.isEmpty ? nil : stripped
  }

  private func stableLocalIdentifier(for event: EKEvent) -> String {
    if !event.calendarItemIdentifier.isEmpty {
      return event.calendarItemIdentifier
    }
    if let eventIdentifier = event.eventIdentifier, !eventIdentifier.isEmpty {
      return eventIdentifier
    }
    if let externalIdentifier = event.calendarItemExternalIdentifier, !externalIdentifier.isEmpty {
      return externalIdentifier
    }
    return UUID().uuidString
  }

  private func derivedUidFromExternalIdentifier(_ event: EKEvent) -> String? {
    guard let externalId = event.calendarItemExternalIdentifier, !externalId.isEmpty else {
      return nil
    }
    return externalId
  }

  private func findEvent(calendarId: String, matchingCaleeUid uid: String, store: EKEventStore) -> EKEvent? {
    let trimmedUid = uid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedUid.isEmpty, let calendar = store.calendar(withIdentifier: calendarId) else {
      return nil
    }

    let now = Date()
    let startDate = now.addingTimeInterval(-20 * 365 * 24 * 3600)
    let endDate = now.addingTimeInterval(20 * 365 * 24 * 3600)
    let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: [calendar])
    return store.events(matching: predicate).first { extractCaleeUid(from: $0) == trimmedUid }
  }

  private func resolveEvent(byStableLocalId eventId: String?, store: EKEventStore) -> EKEvent? {
    guard let eventId, !eventId.isEmpty else {
      return nil
    }

    if let calendarItem = store.calendarItem(withIdentifier: eventId) as? EKEvent {
      return calendarItem
    }
    return store.event(withIdentifier: eventId)
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
      event.startDate = Date(timeIntervalSince1970: TimeInterval(start) / 1000.0)
      event.endDate = Date(timeIntervalSince1970: TimeInterval(end) / 1000.0)
      embedCaleeUid(into: event, uid: uid ?? "", originalNotes: notes)

      do {
        try store.save(event, span: .thisEvent, commit: true)
        completion(.success(stableLocalIdentifier(for: event)))
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

      var event = resolveEvent(byStableLocalId: request.eventId, store: store)
      if event == nil {
        event = findEvent(calendarId: request.calendarId, matchingCaleeUid: request.uid, store: store)
      }
      if event == nil {
        event = EKEvent(eventStore: store)
      }
      event?.calendar = calendar

      guard let event else {
        completion(.failure(
          FlutterError(code: "SAVE_ERROR", message: "Failed to create EKEvent", details: nil)
        ))
        return
      }

      event.title = request.title
      event.startDate = Date(timeIntervalSince1970: TimeInterval(request.start) / 1000.0)
      event.endDate = Date(timeIntervalSince1970: TimeInterval(request.end) / 1000.0)
      embedCaleeUid(into: event, uid: request.uid, originalNotes: request.notes)

      do {
        try store.save(event, span: .thisEvent, commit: true)
        completion(.success(stableLocalIdentifier(for: event)))
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
    return events.map { stableLocalIdentifier(for: $0) }
  }

  func deleteEvent(eventId: String) throws -> Bool {
    let store = try requireReadableEventStore()
    guard let event = resolveEvent(byStableLocalId: eventId, store: store) else {
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
      let candidateSources = orderedCandidateSourcesForCalendarCreation(store: store)
      guard !candidateSources.isEmpty else {
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

      let calendarColor = colorFromInt64(color)
      var attemptedSources: [String] = []
      var failureReasons: [String] = []

      for source in candidateSources {
        attemptedSources.append(describe(source: source))

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = displayName
        calendar.source = source
        calendar.cgColor = calendarColor

        do {
          try store.saveCalendar(calendar, commit: true)
          completion(.success(calendar.calendarIdentifier))
          return
        } catch {
          failureReasons.append("\(describe(source: source)): \(error.localizedDescription)")
        }
      }

      completion(.failure(
        FlutterError(
          code: "SAVE_ERROR",
          message: "Failed to save calendar to all candidate EventKit sources",
          details: [
            "attemptedSources": attemptedSources,
            "failureReasons": failureReasons,
            "accountName": accountName,
          ]
        )
      ))
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

  struct CalendarCreationSourceDescriptor: Equatable {
    let sourceIdentifier: String?
    let title: String
    let sourceType: EKSourceType
  }

  private func orderedCandidateSourcesForCalendarCreation(store: EKEventStore) -> [EKSource] {
    let allSources = store.sources
    let descriptors = Self.orderedCandidateSourceDescriptors(
      allSources: allSources.map(sourceDescriptor(from:)),
      defaultSource: store.defaultCalendarForNewEvents?.source.map(sourceDescriptor(from:)),
      writableEventCalendarSources: store.calendars(for: .event)
        .filter { $0.allowsContentModifications && $0.type != .subscription && $0.type != .birthday }
        .map { sourceDescriptor(from: $0.source) }
    )

    var remainingSourcesByIdentifier: [String: EKSource] = [:]
    var remainingSourcesByFallbackKey: [String: EKSource] = [:]
    for source in allSources {
      let sourceIdentifier = normalizedSourceIdentifier(source.sourceIdentifier)
      if let sourceIdentifier {
        remainingSourcesByIdentifier[sourceIdentifier] = source
      }
      remainingSourcesByFallbackKey[Self.sourceFallbackKey(title: source.title, sourceType: source.sourceType)] = source
    }

    var orderedSources: [EKSource] = []
    for descriptor in descriptors {
      if let sourceIdentifier = descriptor.sourceIdentifier,
         let source = remainingSourcesByIdentifier.removeValue(forKey: sourceIdentifier) {
        orderedSources.append(source)
        remainingSourcesByFallbackKey.removeValue(
          forKey: Self.sourceFallbackKey(title: source.title, sourceType: source.sourceType)
        )
      } else if let source = remainingSourcesByFallbackKey.removeValue(
        forKey: Self.sourceFallbackKey(title: descriptor.title, sourceType: descriptor.sourceType)
      ) {
        orderedSources.append(source)
      }
    }

    return orderedSources
  }

  static func orderedCandidateSourceDescriptors(
    allSources: [CalendarCreationSourceDescriptor],
    defaultSource: CalendarCreationSourceDescriptor?,
    writableEventCalendarSources: [CalendarCreationSourceDescriptor]
  ) -> [CalendarCreationSourceDescriptor] {
    var candidates: [CalendarCreationSourceDescriptor] = []

    candidates.append(contentsOf: allSources.filter {
      Self.isPreferredICloudSource($0) && Self.isEligibleCalendarCreationSource($0)
    }.map {
      CalendarCreationSourceDescriptor(
        sourceIdentifier: $0.sourceIdentifier,
        title: $0.title,
        sourceType: $0.sourceType
      )
    })

    if let defaultSource, Self.isEligibleCalendarCreationSource(defaultSource) {
      candidates.append(
        CalendarCreationSourceDescriptor(
          sourceIdentifier: defaultSource.sourceIdentifier,
          title: defaultSource.title,
          sourceType: defaultSource.sourceType
        )
      )
    }

    candidates.append(contentsOf: writableEventCalendarSources.filter(Self.isEligibleCalendarCreationSource).map {
      CalendarCreationSourceDescriptor(
        sourceIdentifier: $0.sourceIdentifier,
        title: $0.title,
        sourceType: $0.sourceType
      )
    })

    candidates.append(contentsOf: allSources.filter {
      $0.sourceType == .local && Self.isEligibleCalendarCreationSource($0)
    }.map {
      CalendarCreationSourceDescriptor(
        sourceIdentifier: $0.sourceIdentifier,
        title: $0.title,
        sourceType: $0.sourceType
      )
    })

    return Self.dedupeSources(candidates)
  }

  static func isPreferredICloudSource(_ source: CalendarCreationSourceDescriptor) -> Bool {
    source.sourceType == .mobileMe
  }

  static func isEligibleCalendarCreationSource(_ source: CalendarCreationSourceDescriptor) -> Bool {
    switch source.sourceType {
    case .subscribed, .birthdays:
      return false
    default:
      return true
    }
  }

  static func dedupeSources(
    _ sources: [CalendarCreationSourceDescriptor]
  ) -> [CalendarCreationSourceDescriptor] {
    var seenIdentifiers = Set<String>()
    var seenFallbackKeys = Set<String>()
    var deduped: [CalendarCreationSourceDescriptor] = []

    for source in sources {
      if let sourceIdentifier = source.sourceIdentifier {
        if seenIdentifiers.contains(sourceIdentifier) {
          continue
        }
        seenIdentifiers.insert(sourceIdentifier)
      } else {
        let fallbackKey = Self.sourceFallbackKey(title: source.title, sourceType: source.sourceType)
        if seenFallbackKeys.contains(fallbackKey) {
          continue
        }
        seenFallbackKeys.insert(fallbackKey)
      }
      deduped.append(source)
    }

    return deduped
  }

  private func sourceDescriptor(from source: EKSource) -> CalendarCreationSourceDescriptor {
    CalendarCreationSourceDescriptor(
      sourceIdentifier: normalizedSourceIdentifier(source.sourceIdentifier),
      title: source.title,
      sourceType: source.sourceType
    )
  }

  static func sourceFallbackKey(title: String, sourceType: EKSourceType) -> String {
    "\(title)::\(sourceType.rawValue)"
  }

  private func describe(source: EKSource) -> String {
    if let sourceIdentifier = normalizedSourceIdentifier(source.sourceIdentifier) {
      return "\(source.title) [\(string(from: source.sourceType))] {id=\(sourceIdentifier)}"
    }
    return "\(source.title) [\(string(from: source.sourceType))]"
  }

  private func normalizedSourceIdentifier(_ sourceIdentifier: String) -> String? {
    let trimmedIdentifier = sourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedIdentifier.isEmpty ? nil : trimmedIdentifier
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
