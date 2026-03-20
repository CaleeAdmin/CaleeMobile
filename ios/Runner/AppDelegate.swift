import UIKit
import Flutter
import BackgroundTasks
import os.log

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var didRegisterForegroundPlugins = false
  private var didRegisterBackgroundSafePlugins = false
  private var launchedForBackgroundExecution = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    registerPluginsForLaunch(application, launchOptions)

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

    DispatchQueue.global(qos: .default).async {
      if CaleeSyncPeriodicWorker.isPeriodicEnabled() {
        let interval = CaleeSyncPeriodicWorker.readConfiguredIntervalMinutes()
        CaleeSyncPeriodicWorker.ensurePeriodic(intervalMinutes: interval)
      } else {
        CaleeSyncPeriodicWorker.cancelPeriodic()
        CaleeSyncPeriodicWorker.cancelWatchdogAlarm()
      }
      CaleeSyncPeriodicWorker.writeDiagnosticsFile()
    }

    DispatchQueue.main.async {
      self.setupPigeonApis()
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    ensureForegroundPluginsRegisteredIfNeeded()
    setupPigeonApis()
  }

  private func isBackgroundExecutionLaunch(
    _ application: UIApplication,
    _ launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if application.applicationState == .background {
      return true
    }

    guard let launchOptions, !launchOptions.isEmpty else {
      return false
    }

    let foregroundKeys: Set<UIApplication.LaunchOptionsKey> = [
      .url,
      .sourceApplication,
      .annotation,
      .shortcutItem,
      .userActivityDictionary,
      .remoteNotification,
      .localNotification,
    ]

    return foregroundKeys.isDisjoint(with: Set(launchOptions.keys))
      && application.applicationState != .active
  }

  private func registerPluginsForLaunch(
    _ application: UIApplication,
    _ launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) {
    if isBackgroundExecutionLaunch(application, launchOptions) {
      launchedForBackgroundExecution = true
      BackgroundSafePluginRegistrant.registerBackgroundPlugins(with: self)
      didRegisterBackgroundSafePlugins = true
      return
    }

    BackgroundSafePluginRegistrant.registerForegroundPlugins(with: self)
    didRegisterForegroundPlugins = true
  }

  @MainActor
  private func ensureForegroundPluginsRegisteredIfNeeded() {
    guard launchedForBackgroundExecution, !didRegisterForegroundPlugins else {
      return
    }

    BackgroundSafePluginRegistrant.registerForegroundPlugins(with: self)
    didRegisterForegroundPlugins = true
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
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.setupPigeonApis()
      }
      return
    }

    let binaryMessenger = controller.engine.binaryMessenger

    let calendarApi = CalendarHostApiImpl()
    NativeCalendarApiSetup.setUp(
      binaryMessenger: binaryMessenger,
      api: calendarApi
    )

    let backgroundSyncApi = BackgroundSyncControlApiImpl()
    BackgroundSyncControlApiSetup.setUp(
      binaryMessenger: binaryMessenger,
      api: backgroundSyncApi
    )
  }
}
