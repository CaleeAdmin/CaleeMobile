import Flutter
import UIKit
import EventKit

// --- Pigeon generated definitions (inlined) ---
private func wrapResult(_ result: Any?) -> [Any?] {
  return [result]
}

private func wrapError(_ error: Any) -> [Any?] {
  if let flutterError = error as? FlutterError {
    return [
      flutterError.code,
      flutterError.message,
      flutterError.details,
    ]
  }
  return [
    "\(error)",
    "\(type(of: error))",
    "Stacktrace: \(Thread.callStackSymbols)",
  ]
}

private func nilOrValue<T>(_ value: Any?) -> T? {
  if value is NSNull { return nil }
  return value as! T?
}

struct TimeWindow {
  var startMillis: Int64
  var endMillis: Int64
  var calendarIds: [Int64?]? = nil

  static func fromList(_ list: [Any?]) -> TimeWindow? {
    let startMillis = list[0] is Int64 ? list[0] as! Int64 : Int64(list[0] as! Int32)
    let endMillis = list[1] is Int64 ? list[1] as! Int64 : Int64(list[1] as! Int32)
    let calendarIds: [Int64?]? = nilOrValue(list[2])
    return TimeWindow(startMillis: startMillis, endMillis: endMillis, calendarIds: calendarIds)
  }
  func toList() -> [Any?] {
    return [startMillis, endMillis, calendarIds]
  }
}

struct PigeonCalendar {
  var id: Int64
  var accountName: String
  var accountType: String
  var ownerAccount: String? = nil
  var name: String? = nil
  var displayName: String? = nil
  var color: Int64
  var visible: Bool
  var syncEvents: Bool
  var isPrimary: Bool
  var isLocal: Bool
  var accessLevel: Int64

  static func fromList(_ list: [Any?]) -> PigeonCalendar? {
    let id = list[0] is Int64 ? list[0] as! Int64 : Int64(list[0] as! Int32)
    let accountName = list[1] as! String
    let accountType = list[2] as! String
    let ownerAccount: String? = nilOrValue(list[3])
    let name: String? = nilOrValue(list[4])
    let displayName: String? = nilOrValue(list[5])
    let color = list[6] is Int64 ? list[6] as! Int64 : Int64(list[6] as! Int32)
    let visible = list[7] as! Bool
    let syncEvents = list[8] as! Bool
    let isPrimary = list[9] as! Bool
    let isLocal = list[10] as! Bool
    let accessLevel = list[11] is Int64 ? list[11] as! Int64 : Int64(list[11] as! Int32)
    return PigeonCalendar(
      id: id,
      accountName: accountName,
      accountType: accountType,
      ownerAccount: ownerAccount,
      name: name,
      displayName: displayName,
      color: color,
      visible: visible,
      syncEvents: syncEvents,
      isPrimary: isPrimary,
      isLocal: isLocal,
      accessLevel: accessLevel
    )
  }
  func toList() -> [Any?] {
    return [
      id,
      accountName,
      accountType,
      ownerAccount,
      name,
      displayName,
      color,
      visible,
      syncEvents,
      isPrimary,
      isLocal,
      accessLevel,
    ]
  }
}

struct PigeonEvent {
  var id: String
  var calendarId: String
  var title: String
  var startMillis: Int64
  var endMillis: Int64
  var description: String? = nil
  var location: String? = nil
  var allDay: Bool
  var timeZone: String? = nil
  var recurrenceRule: String? = nil
  var recurrenceExceptionMillis: [Int64?]? = nil
  var attendees: [String?]? = nil
  var organizer: String? = nil
  var status: String? = nil
  var etag: String? = nil
  var updatedAtMillis: Int64? = nil
  var isCanceled: Bool

  static func fromList(_ list: [Any?]) -> PigeonEvent? {
    let id = list[0] as! String
    let calendarId = list[1] as! String
    let title = list[2] as! String
    let startMillis = list[3] is Int64 ? list[3] as! Int64 : Int64(list[3] as! Int32)
    let endMillis = list[4] is Int64 ? list[4] as! Int64 : Int64(list[4] as! Int32)
    let description: String? = nilOrValue(list[5])
    let location: String? = nilOrValue(list[6])
    let allDay = list[7] as! Bool
    let timeZone: String? = nilOrValue(list[8])
    let recurrenceRule: String? = nilOrValue(list[9])
    let recurrenceExceptionMillis: [Int64?]? = nilOrValue(list[10])
    let attendees: [String?]? = nilOrValue(list[11])
    let organizer: String? = nilOrValue(list[12])
    let status: String? = nilOrValue(list[13])
    let etag: String? = nilOrValue(list[14])
    let updatedAtMillis = list[15] as? Int64
    let isCanceled = list[16] as! Bool
    return PigeonEvent(
      id: id,
      calendarId: calendarId,
      title: title,
      startMillis: startMillis,
      endMillis: endMillis,
      description: description,
      location: location,
      allDay: allDay,
      timeZone: timeZone,
      recurrenceRule: recurrenceRule,
      recurrenceExceptionMillis: recurrenceExceptionMillis,
      attendees: attendees,
      organizer: organizer,
      status: status,
      etag: etag,
      updatedAtMillis: updatedAtMillis,
      isCanceled: isCanceled
    )
  }
  func toList() -> [Any?] {
    return [
      id,
      calendarId,
      title,
      startMillis,
      endMillis,
      description,
      location,
      allDay,
      timeZone,
      recurrenceRule,
      recurrenceExceptionMillis,
      attendees,
      organizer,
      status,
      etag,
      updatedAtMillis,
      isCanceled,
    ]
  }
}

class CalendarHostApiCodecReader: FlutterStandardReader {
  override func readValue(ofType type: UInt8) -> Any? {
    switch type {
    case 128:
      return PigeonCalendar.fromList(self.readValue() as! [Any?])
    case 129:
      return PigeonEvent.fromList(self.readValue() as! [Any?])
    case 130:
      return TimeWindow.fromList(self.readValue() as! [Any?])
    default:
      return super.readValue(ofType: type)
    }
  }
}

class CalendarHostApiCodecWriter: FlutterStandardWriter {
  override func writeValue(_ value: Any) {
    if let value = value as? PigeonCalendar {
      super.writeByte(128)
      super.writeValue(value.toList())
    } else if let value = value as? PigeonEvent {
      super.writeByte(129)
      super.writeValue(value.toList())
    } else if let value = value as? TimeWindow {
      super.writeByte(130)
      super.writeValue(value.toList())
    } else {
      super.writeValue(value)
    }
  }
}

class CalendarHostApiCodecReaderWriter: FlutterStandardReaderWriter {
  override func reader(with data: Data) -> FlutterStandardReader {
    return CalendarHostApiCodecReader(data: data)
  }

  override func writer(with data: NSMutableData) -> FlutterStandardWriter {
    return CalendarHostApiCodecWriter(data: data)
  }
}

class CalendarHostApiCodec: FlutterStandardMessageCodec {
  static let shared = CalendarHostApiCodec(readerWriter: CalendarHostApiCodecReaderWriter())
}

protocol CalendarHostApi {
  func listCalendars() throws -> [PigeonCalendar?]
  func listEvents(window: TimeWindow) throws -> [PigeonEvent?]
}

class CalendarHostApiSetup {
  static var codec: FlutterStandardMessageCodec { CalendarHostApiCodec.shared }
  static func setUp(binaryMessenger: FlutterBinaryMessenger, api: CalendarHostApi?, messageChannelSuffix: String = "") {
    let channelSuffix = messageChannelSuffix.count > 0 ? ".\(messageChannelSuffix)" : ""
    let listCalendarsChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.calendar_api.CalendarHostApi.listCalendars\(channelSuffix)", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      listCalendarsChannel.setMessageHandler { _, reply in
        do {
          let result = try api.listCalendars()
          reply(wrapResult(result))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      listCalendarsChannel.setMessageHandler(nil)
    }
    let listEventsChannel = FlutterBasicMessageChannel(name: "dev.flutter.pigeon.calendar_api.CalendarHostApi.listEvents\(channelSuffix)", binaryMessenger: binaryMessenger, codec: codec)
    if let api = api {
      listEventsChannel.setMessageHandler { message, reply in
        let args = message as! [Any?]
        let windowArg = args[0] as! TimeWindow
        do {
          let result = try api.listEvents(window: windowArg)
          reply(wrapResult(result))
        } catch {
          reply(wrapError(error))
        }
      }
    } else {
      listEventsChannel.setMessageHandler(nil)
    }
  }
}
// --- End inline Pigeon definitions ---

// Fallback inline implementation to ensure Pigeon types are available in scope.
class CalendarHostApiImpl: CalendarHostApi {
  private let eventStore: EKEventStore
  init(eventStore: EKEventStore) {
    self.eventStore = eventStore
  }

  func listCalendars() throws -> [PigeonCalendar?] {
    return eventStore.calendars(for: .event).map { cal in
      let calendarId = Int64(cal.calendarIdentifier.hashValue)
      let accountType: String
      let isLocal: Bool
      switch cal.source.sourceType {
      case .local:
        accountType = "LOCAL"
        isLocal = true
      case .calDAV:
        accountType = "caldav"
        isLocal = false
      case .exchange:
        accountType = "exchange"
        isLocal = false
      case .mobileMe:
        accountType = "mobileme"
        isLocal = false
      case .subscribed:
        accountType = "subscribed"
        isLocal = false
      @unknown default:
        accountType = "unknown"
        isLocal = false
      }
      var colorInt: Int64 = 0
      if let components = cal.cgColor.components, components.count >= 3 {
        let r = Int64(components[0] * 255)
        let g = Int64(components[1] * 255)
        let b = Int64(components[2] * 255)
        colorInt = (r << 16) | (g << 8) | b
      }
      let accessLevel: Int64 = cal.allowsContentModifications ? 700 : 400
      return PigeonCalendar(
        id: calendarId,
        accountName: cal.source.title,
        accountType: accountType,
        ownerAccount: cal.source.title,
        name: cal.title,
        displayName: cal.title,
        color: colorInt,
        visible: true,
        syncEvents: !cal.isSubscribed,
        isPrimary: !cal.isSubscribed && cal.type == .local,
        isLocal: isLocal,
        accessLevel: accessLevel
      )
    }
  }

  func listEvents(window: TimeWindow) throws -> [PigeonEvent?] {
    let startDate = Date(timeIntervalSince1970: TimeInterval(window.startMillis) / 1000.0)
    let endDate = Date(timeIntervalSince1970: TimeInterval(window.endMillis) / 1000.0)
    var calendars = eventStore.calendars(for: .event)
    if let ids = window.calendarIds, !ids.isEmpty {
      let idSet = Set(ids.compactMap { $0 })
      calendars = calendars.filter { idSet.contains(Int64($0.calendarIdentifier.hashValue)) }
    }
    let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
    let events = eventStore.events(matching: predicate)
    return events.map { ev in
      let eventId = Int64(ev.eventIdentifier.hashValue)
      let calendarId = Int64(ev.calendar.calendarIdentifier.hashValue)
      return PigeonEvent(
        id: String(eventId),
        calendarId: String(calendarId),
        title: ev.title ?? "",
        startMillis: Int64(ev.startDate.timeIntervalSince1970 * 1000),
        endMillis: Int64(ev.endDate.timeIntervalSince1970 * 1000),
        description: ev.notes,
        location: ev.location,
        allDay: ev.isAllDay,
        timeZone: ev.timeZone?.identifier,
        recurrenceRule: nil,
        recurrenceExceptionMillis: nil,
        attendees: ev.attendees?.map { $0.name ?? $0.url.absoluteString },
        organizer: ev.organizer?.name ?? ev.organizer?.url.absoluteString,
        status: String(ev.status.rawValue),
        etag: nil,
        updatedAtMillis: nil,
        isCanceled: ev.status == .canceled
      )
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller: FlutterViewController = window?.rootViewController as! FlutterViewController
    
    // Register Pigeon CalendarHostApi implementation
    let eventStore = EKEventStore()
    let calendarApiImpl = CalendarHostApiImpl(eventStore: eventStore)
    CalendarHostApiSetup.setUp(
      binaryMessenger: controller.binaryMessenger,
      api: calendarApiImpl
    )

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
