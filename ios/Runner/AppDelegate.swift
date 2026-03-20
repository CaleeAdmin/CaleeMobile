import UIKit
import Flutter
import BackgroundTasks
import os.log

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var didRegisterForegroundPlugins = false
  private var didRegisterBackgroundSafePlugins = false
  private var launchedForBackgroundExecution = false
  private var didChooseBackgroundSafeLaunchMode = false

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

    let mode = didChooseBackgroundSafeLaunchMode
      ? "foreground_upgrade_after_background_launch"
      : "foreground_active"
    persistLaunchClassificationDiagnostics(
      mode: mode,
      application: application,
      launchOptions: nil
    )
    setupPigeonApis()
  }

  private func isBackgroundExecutionLaunch(
    _ application: UIApplication,
    _ launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if application.applicationState == .active {
      return false
    }

    let explicitForegroundKeys: Set<UIApplication.LaunchOptionsKey> = [
      .url,
      .sourceApplication,
      .annotation,
      .shortcutItem,
      .userActivityDictionary,
    ]

    guard let launchOptions else {
      return true
    }

    return explicitForegroundKeys.isDisjoint(with: Set(launchOptions.keys))
  }

  private func persistLaunchClassificationDiagnostics(
    mode: String,
    application: UIApplication,
    launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) {
    let prefs = UserDefaults.standard
    let launchOptionKeys = launchOptions?.keys.map { $0.rawValue }.sorted() ?? []

    let applicationState: String
    switch application.applicationState {
    case .active:
      applicationState = "active"
    case .inactive:
      applicationState = "inactive"
    case .background:
      applicationState = "background"
    @unknown default:
      applicationState = "unknown"
    }

    prefs.set(mode, forKey: "launch_classifier_mode")
    prefs.set(applicationState, forKey: "launch_classifier_app_state")
    prefs.set(launchOptions != nil, forKey: "launch_classifier_has_launch_options")
    prefs.set(launchOptionKeys, forKey: "launch_classifier_launch_option_keys")
    prefs.set(didRegisterBackgroundSafePlugins, forKey: "launch_classifier_did_use_background_safe_registrant")
    prefs.set(didRegisterForegroundPlugins, forKey: "launch_classifier_did_use_foreground_registrant")

    CaleeSyncPeriodicWorker.writeDiagnosticsFile()
  }

  private func registerPluginsForLaunch(
    _ application: UIApplication,
    _ launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) {
    if isBackgroundExecutionLaunch(application, launchOptions) {
      launchedForBackgroundExecution = true
      didChooseBackgroundSafeLaunchMode = true
      BackgroundSafePluginRegistrant.registerBackgroundPlugins(with: self)
      didRegisterBackgroundSafePlugins = true
      persistLaunchClassificationDiagnostics(
        mode: "background_safe",
        application: application,
        launchOptions: launchOptions
      )
      return
    }

    BackgroundSafePluginRegistrant.registerForegroundPlugins(with: self)
    didRegisterForegroundPlugins = true
    persistLaunchClassificationDiagnostics(
      mode: "foreground_full",
      application: application,
      launchOptions: launchOptions
    )
  }

  @MainActor
  private func ensureForegroundPluginsRegisteredIfNeeded() {
    guard launchedForBackgroundExecution, !didRegisterForegroundPlugins else {
      return
    }

    BackgroundSafePluginRegistrant.registerForegroundPlugins(with: self)
    didRegisterForegroundPlugins = true
    persistLaunchClassificationDiagnostics(
      mode: "foreground_upgrade_after_background_launch",
      application: UIApplication.shared,
      launchOptions: nil
    )
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
