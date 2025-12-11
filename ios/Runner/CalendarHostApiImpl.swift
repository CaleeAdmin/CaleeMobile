import Foundation
import EventKit

/// Implementation of CalendarHostApi for iOS using EventKit.
class CalendarHostApiImpl: CalendarHostApi {
    private let eventStore: EKEventStore
    
    init(eventStore: EKEventStore) {
        self.eventStore = eventStore
    }
    
    func listCalendars() throws -> [PigeonCalendar?] {
        try ensureAuthorized()
        
        let calendars = eventStore.calendars(for: .event)
        return calendars.map { cal in
            let raw: [String: Any?] = [
                "calendarIdentifier": cal.calendarIdentifier,
                "title": cal.title,
                "type": cal.type.rawValue,
                "sourceTitle": cal.source.title,
                "sourceType": cal.source.sourceType.rawValue,
                "allowsContentModifications": cal.allowsContentModifications,
                "isImmutable": cal.isImmutable,
                "isSubscribed": cal.isSubscribed,
            ]
            NSLog("Calendar raw: \(raw)")
            
            // Extract calendar ID from identifier (EventKit uses string identifiers)
            // For compatibility, we'll use a hash or convert to numeric ID
            let calendarId = Int64(cal.calendarIdentifier.hashValue)
            
            // Determine account type
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
                accountType = "com.google"
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
            
            // Extract color (CGColor to Int)
            var colorInt: Int64 = 0
            if let components = cal.cgColor.components, components.count >= 3 {
                let r = Int64(components[0] * 255)
                let g = Int64(components[1] * 255)
                let b = Int64(components[2] * 255)
                colorInt = (r << 16) | (g << 8) | b
            }
            
            // Determine access level (EventKit doesn't have explicit access levels like Android)
            // We'll map based on allowsContentModifications
            let accessLevel: Int64 = cal.allowsContentModifications ? 700 : 400 // owner vs read-only
            
            return PigeonCalendar(
                id: calendarId,
                accountName: cal.source.title,
                accountType: accountType,
                ownerAccount: cal.source.title,
                name: cal.title,
                displayName: cal.title,
                color: colorInt,
                visible: true, // EventKit calendars are always visible when returned
                syncEvents: !cal.isSubscribed, // Subscribed calendars don't sync
                isPrimary: !cal.isSubscribed && cal.type == .local,
                isLocal: isLocal,
                accessLevel: accessLevel
            )
        }
    }
    
    func listEvents(window: TimeWindow) throws -> [PigeonEvent?] {
        try ensureAuthorized()
        
        let startDate = Date(timeIntervalSince1970: TimeInterval(window.startMillis) / 1000.0)
        let endDate = Date(timeIntervalSince1970: TimeInterval(window.endMillis) / 1000.0)
        
        var calendars = eventStore.calendars(for: .event)
        
        // Filter by calendar IDs if provided
        if let calendarIds = window.calendarIds, !calendarIds.isEmpty {
            // Convert calendar IDs to identifiers (we need to map back from hash)
            // For now, we'll use all calendars if IDs are provided
            // In a real implementation, you'd maintain a mapping
            let calendarIdSet = Set(calendarIds.compactMap { $0 })
            calendars = calendars.filter { cal in
                let calId = Int64(cal.calendarIdentifier.hashValue)
                return calendarIdSet.contains(calId)
            }
        }
        
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)
        
        return events.map { ev in
            let raw: [String: Any?] = [
                "eventIdentifier": ev.eventIdentifier,
                "title": ev.title,
                "startDate": ev.startDate.description,
                "endDate": ev.endDate.description,
                "isAllDay": ev.isAllDay,
                "timeZone": ev.timeZone?.identifier,
                "location": ev.location,
                "notes": ev.notes,
                "status": ev.status.rawValue,
                "organizer": ev.organizer?.name ?? ev.organizer?.url.absoluteString ?? "",
                "attendeesCount": ev.attendees?.count ?? 0
            ]
            NSLog("Event raw: \(raw)")
            
            // Convert event identifier to numeric ID
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
                recurrenceRule: nil, // EventKit doesn't expose RRULE directly
                recurrenceExceptionMillis: nil,
                attendees: ev.attendees?.map { $0.name ?? $0.url?.absoluteString ?? "" },
                organizer: ev.organizer?.name ?? ev.organizer?.url?.absoluteString,
                status: String(ev.status.rawValue),
                etag: nil,
                updatedAtMillis: nil,
                isCanceled: ev.status == .canceled
            )
        }
    }
    
    private func ensureAuthorized() throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            var granted = false
            let semaphore = DispatchSemaphore(value: 0)
            eventStore.requestAccess(to: .event) { ok, _ in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            if !granted {
                throw NSError(domain: "calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar permission denied"])
            }
        } else if status != .authorized {
            throw NSError(domain: "calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar permission denied"])
        }
    }
}

