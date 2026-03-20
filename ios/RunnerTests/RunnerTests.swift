import EventKit
import Flutter
import UIKit
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {

  func testOrderedCandidateSourceDescriptorsPrefersICloudFirst() {
    let local = source(id: "local", title: "On My iPhone", type: .local)
    let defaultCalDAV = source(id: "default", title: "Work", type: .calDAV)
    let iCloudPrimary = source(id: "icloud-1", title: "Personal", type: .mobileMe)
    let iCloudSecondary = source(id: "icloud-2", title: "Family", type: .mobileMe)

    let ordered = CalendarHostApiImpl.orderedCandidateSourceDescriptors(
      allSources: [local, defaultCalDAV, iCloudPrimary, iCloudSecondary],
      defaultSource: defaultCalDAV,
      writableEventCalendarSources: [defaultCalDAV, iCloudSecondary]
    )

    XCTAssertEqual(ordered.map(\.sourceIdentifier), ["icloud-1", "icloud-2", "default", "local"])
  }

  func testOrderedCandidateSourceDescriptorsFallbackOrderWithoutICloud() {
    let local = source(id: "local", title: "On My iPhone", type: .local)
    let defaultExchange = source(id: "exchange", title: "Work", type: .exchange)
    let existingCalDAV = source(id: "caldav", title: "Shared", type: .calDAV)

    let ordered = CalendarHostApiImpl.orderedCandidateSourceDescriptors(
      allSources: [local, defaultExchange, existingCalDAV],
      defaultSource: defaultExchange,
      writableEventCalendarSources: [existingCalDAV]
    )

    XCTAssertEqual(ordered.map(\.sourceIdentifier), ["exchange", "caldav", "local"])
  }

  func testOrderedCandidateSourceDescriptorsDedupesAndKeepsLocalLast() {
    let local = source(id: nil, title: "On My iPhone", type: .local)
    let duplicateLocal = source(id: nil, title: "On My iPhone", type: .local)
    let iCloud = source(id: "icloud", title: "Personal", type: .mobileMe)
    let duplicateICloud = source(id: "icloud", title: "Personal Duplicate", type: .mobileMe)
    let subscribed = source(id: "subscribed", title: "Holidays", type: .subscribed)

    let ordered = CalendarHostApiImpl.orderedCandidateSourceDescriptors(
      allSources: [duplicateLocal, iCloud, duplicateICloud, local, subscribed],
      defaultSource: duplicateICloud,
      writableEventCalendarSources: [subscribed, iCloud, duplicateLocal]
    )

    XCTAssertEqual(ordered.count, 2)
    XCTAssertEqual(ordered.first?.sourceIdentifier, "icloud")
    XCTAssertEqual(ordered.last?.sourceType, .local)
  }

  private func source(
    id: String?,
    title: String,
    type: EKSourceType
  ) -> CalendarHostApiImpl.CalendarCreationSourceDescriptor {
    CalendarHostApiImpl.CalendarCreationSourceDescriptor(
      sourceIdentifier: id,
      title: title,
      sourceType: type
    )
  }
}
