import UIKit
import Flutter
import BackgroundTasks
import os.log

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // Register background task handlers
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: CaleeSyncPeriodicWorker.PERIODIC_TASK_IDENTIFIER,
      using: nil
    ) { task in
      CaleeSyncPeriodicWorker.handleTask(task: task)
    }
    
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: CaleeSyncPeriodicWorker.SYNC_TASK_IDENTIFIER,
      using: nil
    ) { task in
      CaleeSyncPeriodicWorker.handleTask(task: task)
    }
    
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: CaleeSyncPeriodicWorker.WATCHDOG_TASK_IDENTIFIER,
      using: nil
    ) { task in
      CaleeSyncPeriodicWorker.handleTask(task: task)
    }
    logBackgroundModesConfiguration()
    
    // Restore periodic sync task on app launch (equivalent to Android's BOOT_COMPLETED)
    // This ensures periodic tasks are restored after app restart or update
    DispatchQueue.global(qos: .default).async {
      if CaleeSyncPeriodicWorker.isPeriodicEnabled() {
        let interval = CaleeSyncPeriodicWorker.readConfiguredIntervalMinutes()
        CaleeSyncPeriodicWorker.ensurePeriodic(intervalMinutes: interval)
      } else {
        CaleeSyncPeriodicWorker.cancelPeriodic()
        CaleeSyncPeriodicWorker.cancelWatchdogAlarm()
      }
    }
    
    // Setup Pigeon APIs when Flutter engine is ready
    // This will be called after the Flutter view controller is created
    DispatchQueue.main.async {
      self.setupPigeonApis()
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func logBackgroundModesConfiguration() {
    let configuredModes =
      (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]) ?? []
    let hasFetch = configuredModes.contains("fetch")
    let hasProcessing = configuredModes.contains("processing")

    let configuredModesSummary = configuredModes.joined(separator: ",")
    Logger.default.info(
      "UIBackgroundModes configured: \(configuredModesSummary, privacy: .public); fetch=\(hasFetch, privacy: .public); processing=\(hasProcessing, privacy: .public)"
    )
  }
  
  private func setupPigeonApis() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      // Retry after a short delay if controller is not ready
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.setupPigeonApis()
      }
      return
    }
    
    let binaryMessenger = controller.engine.binaryMessenger
    
    // Setup Calendar API
    let calendarApi = CalendarHostApiImpl()
    NativeCalendarApiSetup.setUp(
      binaryMessenger: binaryMessenger,
      api: calendarApi
    )
    
    // Setup BackgroundSyncControlApi
    let backgroundSyncApi = BackgroundSyncControlApiImpl()
    BackgroundSyncControlApiSetup.setUp(
      binaryMessenger: binaryMessenger,
      api: backgroundSyncApi
    )
  }
}
