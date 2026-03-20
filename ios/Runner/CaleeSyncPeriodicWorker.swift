import Foundation
import BackgroundTasks
import Flutter
import UIKit
import os.log

class CaleeSyncPeriodicWorker {
    static let TAG = "CaleeSyncWorker"
    static let PREFS = "calee_sync_bg"
    static let KEY_PERIODIC_ENABLED = "periodic_enabled"
    static let KEY_PERIODIC_INTERVAL_MINUTES = "periodic_interval_minutes"
    static let KEY_PERIODIC_NEXT_AT = "periodic_next_at"
    static let KEY_LAST_RUN_AT = "last_run_at"
    static let KEY_LAST_OUTCOME = "last_outcome"
    static let KEY_LAST_REASON = "last_reason"
    static let KEY_LAST_GATE = "last_gate"
    static let KEY_LAST_ERROR = "last_error"
    static let KEY_LAST_STAGE = "last_stage"
    static let KEY_LAST_STAGE_AT = "last_stage_at"
    static let KEY_LAST_READY_VERSION = "last_ready_version"
    static let KEY_LAST_ATTEMPT_AT = "last_attempt_at"
    static let KEY_LAST_FAILURE_STAGE = "last_failure_stage"
    static let KEY_LAST_FAILURE_ELAPSED_MS = "last_failure_elapsed_ms"
    static let KEY_LAST_FAILURE_STEP = "last_failure_step"
    static let KEY_LAUNCH_CLASSIFIER_MODE = "launch_classifier_mode"
    static let KEY_LAUNCH_CLASSIFIER_APP_STATE = "launch_classifier_app_state"
    static let KEY_LAUNCH_CLASSIFIER_HAS_LAUNCH_OPTIONS = "launch_classifier_has_launch_options"
    static let KEY_LAUNCH_CLASSIFIER_LAUNCH_OPTION_KEYS = "launch_classifier_launch_option_keys"
    static let KEY_LAUNCH_CLASSIFIER_DID_USE_BACKGROUND_SAFE_REGISTRANT = "launch_classifier_did_use_background_safe_registrant"
    static let KEY_LAUNCH_CLASSIFIER_DID_USE_FOREGROUND_REGISTRANT = "launch_classifier_did_use_foreground_registrant"

    static let PERIODIC_TASK_IDENTIFIER = "com.calee.caleesync.periodic"
    static let SYNC_TASK_IDENTIFIER = "com.calee.caleesync.sync"
    static let WATCHDOG_TASK_IDENTIFIER = "com.calee.caleesync.watchdog"

    static let CONTRACT_VERSION: Int64 = 1
    static let DART_READY_TIMEOUT_MS: TimeInterval = 18.0
    static let SYNC_REPLY_TIMEOUT_MS: TimeInterval = 25.0
    static let WORKER_EXEC_TIMEOUT_MS: TimeInterval = 90.0
    static let RECENT_ATTEMPT_WINDOW_MS: TimeInterval = 30.0
    static let WATCHDOG_INTERVAL_MINUTES: Int64 = 20

    static let STAGE_ENGINE_CREATED = "ENGINE_CREATED"
    static let STAGE_DART_ENTRYPOINT_STARTED = "DART_ENTRYPOINT_STARTED"
    static let STAGE_DART_READY_RECEIVED = "DART_READY_RECEIVED"
    static let STAGE_DART_READY_TIMEOUT = "DART_READY_TIMEOUT"
    static let STAGE_RUN_SYNC_SENT = "RUN_SYNC_SENT"
    static let STAGE_RUN_SYNC_REPLIED = "RUN_SYNC_REPLIED"
    static let STAGE_RUN_SYNC_TIMEOUT = "RUN_SYNC_TIMEOUT"
    static let STAGE_WORKER_FINISHED = "WORKER_FINISHED"

    private static var currentEngine: FlutterEngine?
    private static var isRunning = false

    static func diagnosticsDirectoryUrl() -> URL? {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Logger.default.error("Failed to resolve documents directory for diagnostics export")
            return nil
        }

        let diagnosticsDirectory = documentsDirectory.appendingPathComponent("background_sync_diagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            return diagnosticsDirectory
        } catch {
            Logger.default.error("Failed to create diagnostics directory: \(error.localizedDescription)")
            return nil
        }
    }

    static func diagnosticsFileUrl() -> URL? {
        diagnosticsDirectoryUrl()?.appendingPathComponent("latest_native_background_state.json", isDirectory: false)
    }

    static func writeDiagnosticsFile() {
        let prefs = UserDefaults.standard
        guard let diagnosticsFileUrl = diagnosticsFileUrl() else { return }

        let payload: [String: Any] = [
            KEY_LAST_RUN_AT: jsonNumber(from: prefs, key: KEY_LAST_RUN_AT),
            KEY_LAST_ATTEMPT_AT: jsonNumber(from: prefs, key: KEY_LAST_ATTEMPT_AT),
            KEY_LAST_OUTCOME: jsonString(from: prefs, key: KEY_LAST_OUTCOME),
            KEY_LAST_REASON: jsonString(from: prefs, key: KEY_LAST_REASON),
            KEY_LAST_GATE: jsonString(from: prefs, key: KEY_LAST_GATE),
            KEY_LAST_ERROR: jsonString(from: prefs, key: KEY_LAST_ERROR),
            KEY_LAST_STAGE: jsonString(from: prefs, key: KEY_LAST_STAGE),
            KEY_LAST_STAGE_AT: jsonNumber(from: prefs, key: KEY_LAST_STAGE_AT),
            KEY_LAST_FAILURE_STAGE: jsonString(from: prefs, key: KEY_LAST_FAILURE_STAGE),
            KEY_LAST_FAILURE_STEP: jsonString(from: prefs, key: KEY_LAST_FAILURE_STEP),
            KEY_LAST_FAILURE_ELAPSED_MS: jsonNumber(from: prefs, key: KEY_LAST_FAILURE_ELAPSED_MS),
            KEY_LAST_READY_VERSION: jsonNumber(from: prefs, key: KEY_LAST_READY_VERSION),
            KEY_PERIODIC_ENABLED: jsonBool(from: prefs, key: KEY_PERIODIC_ENABLED),
            KEY_PERIODIC_INTERVAL_MINUTES: jsonNumber(from: prefs, key: KEY_PERIODIC_INTERVAL_MINUTES),
            KEY_PERIODIC_NEXT_AT: jsonNumber(from: prefs, key: KEY_PERIODIC_NEXT_AT),
            KEY_LAUNCH_CLASSIFIER_MODE: jsonString(from: prefs, key: KEY_LAUNCH_CLASSIFIER_MODE),
            KEY_LAUNCH_CLASSIFIER_APP_STATE: jsonString(from: prefs, key: KEY_LAUNCH_CLASSIFIER_APP_STATE),
            KEY_LAUNCH_CLASSIFIER_HAS_LAUNCH_OPTIONS: jsonBool(from: prefs, key: KEY_LAUNCH_CLASSIFIER_HAS_LAUNCH_OPTIONS),
            KEY_LAUNCH_CLASSIFIER_LAUNCH_OPTION_KEYS: jsonArray(from: prefs, key: KEY_LAUNCH_CLASSIFIER_LAUNCH_OPTION_KEYS),
            KEY_LAUNCH_CLASSIFIER_DID_USE_BACKGROUND_SAFE_REGISTRANT: jsonBool(from: prefs, key: KEY_LAUNCH_CLASSIFIER_DID_USE_BACKGROUND_SAFE_REGISTRANT),
            KEY_LAUNCH_CLASSIFIER_DID_USE_FOREGROUND_REGISTRANT: jsonBool(from: prefs, key: KEY_LAUNCH_CLASSIFIER_DID_USE_FOREGROUND_REGISTRANT)
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            try data.write(to: diagnosticsFileUrl, options: .atomic)
        } catch {
            Logger.default.error("Failed to write diagnostics file: \(error.localizedDescription)")
        }
    }


    static func schedulePeriodic(intervalMinutes: Int) throws {
        let prefs = UserDefaults.standard
        let bounded = max(intervalMinutes, 15)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: PERIODIC_TASK_IDENTIFIER)
        let request = BGAppRefreshTaskRequest(identifier: PERIODIC_TASK_IDENTIFIER)
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(bounded * 60))

        try BGTaskScheduler.shared.submit(request)
        prefs.set(bounded, forKey: KEY_PERIODIC_INTERVAL_MINUTES)
        let nextAtMs = (request.earliestBeginDate?.timeIntervalSince1970 ?? 0) * 1000
        prefs.set(nextAtMs, forKey: KEY_PERIODIC_NEXT_AT)
        Logger.default.info("Scheduled periodic task with interval: \(bounded) minutes")
        writeDiagnosticsFile()
    }

    static func cancelPeriodic() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: PERIODIC_TASK_IDENTIFIER)
        Logger.default.info("Cancelled periodic task")
        let prefs = UserDefaults.standard
        prefs.removeObject(forKey: KEY_PERIODIC_NEXT_AT)
        writeDiagnosticsFile()
    }

    static func isPeriodicScheduled() -> Bool {
        // Non-authoritative helper retained for legacy call sites.
        return UserDefaults.standard.bool(forKey: KEY_PERIODIC_ENABLED)
    }

    static func enqueueOneOff(reason: String, expedited: Bool, enqueuePolicy: OneOffEnqueuePolicy) throws {
        let request = BGProcessingTaskRequest(identifier: SYNC_TASK_IDENTIFIER)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        if expedited {
            // iOS doesn't have expedited tasks, but we can set a shorter delay
            request.earliestBeginDate = Date(timeIntervalSinceNow: 0)
        } else {
            request.earliestBeginDate = Date(timeIntervalSinceNow: 1)
        }

        // Store trigger reason in user defaults
        UserDefaults.standard.set(reason, forKey: "\(SYNC_TASK_IDENTIFIER)_trigger")

        // iOS BGTaskScheduler doesn't support replace policy directly,
        // but we can cancel existing task if policy is replace
        if enqueuePolicy == .replace {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: SYNC_TASK_IDENTIFIER)
        }

        try BGTaskScheduler.shared.submit(request)
        Logger.default.info("Enqueued one-off task with reason: \(reason), policy: \(enqueuePolicy.rawValue)")
    }

    static func scheduleWatchdogAlarm(intervalMinutes: Int) {
        let bounded = max(intervalMinutes, 15)
        let watchdogInterval = max(Int64(bounded), WATCHDOG_INTERVAL_MINUTES)

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: WATCHDOG_TASK_IDENTIFIER)
        let request = BGAppRefreshTaskRequest(identifier: WATCHDOG_TASK_IDENTIFIER)
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(watchdogInterval * 60))

        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.default.info("Scheduled watchdog alarm")
            writeDiagnosticsFile()
        } catch {
            Logger.default.error("Failed to schedule watchdog alarm: \(error.localizedDescription)")
        }
    }

    static func cancelWatchdogAlarm() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: WATCHDOG_TASK_IDENTIFIER)
        Logger.default.info("Cancelled watchdog alarm")
        writeDiagnosticsFile()
    }

    static func shouldSkipWatchdogOneOff() -> Bool {
        let prefs = UserDefaults.standard
        let lastAttemptAt = prefs.double(forKey: KEY_LAST_ATTEMPT_AT)
        if lastAttemptAt > 0 {
            let timeSinceLastAttempt = Date().timeIntervalSince1970 - lastAttemptAt / 1000.0
            if timeSinceLastAttempt < RECENT_ATTEMPT_WINDOW_MS {
                return true
            }
        }
        // Check if sync task is already running
        return isRunning
    }

    static func readConfiguredIntervalMinutes() -> Int {
        let prefs = UserDefaults.standard
        return max(prefs.integer(forKey: KEY_PERIODIC_INTERVAL_MINUTES), 15)
    }

    static func isPeriodicEnabled() -> Bool {
        let prefs = UserDefaults.standard
        return prefs.bool(forKey: KEY_PERIODIC_ENABLED)
    }

    static func readStatus() -> BackgroundStatusDto {
        let prefs = UserDefaults.standard
        let periodicEnabled = prefs.bool(forKey: KEY_PERIODIC_ENABLED)
        let configuredInterval = max(prefs.integer(forKey: KEY_PERIODIC_INTERVAL_MINUTES), 15)
        let nextAt = prefs.double(forKey: KEY_PERIODIC_NEXT_AT)
        let lastRunAt = prefs.double(forKey: KEY_LAST_RUN_AT)

        let lastOutcomeRaw = prefs.string(forKey: KEY_LAST_OUTCOME)
        let lastOutcome = parseOutcome(lastOutcomeRaw)

        let lastGateRaw = prefs.string(forKey: KEY_LAST_GATE)
        let lastGateReason = parseGateReason(lastGateRaw)

        // iOS does not expose authoritative BGTaskScheduler queue state.
        let periodicWorkState: String? = nil
        let oneOffWorkState: String? = isRunning ? "RUNNING" : nil

        return BackgroundStatusDto(
            periodicEnabled: periodicEnabled,
            lastRunAtMs: lastRunAt > 0 ? Int64(lastRunAt) : nil,
            lastOutcome: lastOutcome,
            lastReason: prefs.string(forKey: KEY_LAST_REASON),
            lastGateReason: lastGateReason,
            lastError: prefs.string(forKey: KEY_LAST_ERROR),
            lastStage: prefs.string(forKey: KEY_LAST_STAGE),
            lastStageAtMs: {
                let stageAt = prefs.double(forKey: KEY_LAST_STAGE_AT)
                return stageAt > 0 ? Int64(stageAt) : nil
            }(),
            nextScheduledAtMs: nextAt > 0 ? Int64(nextAt) : nil,
            periodicWorkState: periodicWorkState,
            oneOffWorkState: oneOffWorkState,
            lastFailureStage: prefs.string(forKey: KEY_LAST_FAILURE_STAGE),
            lastFailureElapsedMs: {
                let elapsed = prefs.double(forKey: KEY_LAST_FAILURE_ELAPSED_MS)
                return elapsed > 0 ? Int64(elapsed) : nil
            }(),
            lastFailureStep: prefs.string(forKey: KEY_LAST_FAILURE_STEP),
            workerRunning: isRunning,
            intervalMinutes: Int64(configuredInterval),
            contractVersion: CONTRACT_VERSION
        )
    }

    private static func jsonString(from prefs: UserDefaults, key: String) -> Any {
        guard let value = prefs.object(forKey: key) else { return NSNull() }
        if let stringValue = value as? String {
            return stringValue.isEmpty ? NSNull() : stringValue
        }
        return String(describing: value)
    }

    private static func jsonNumber(from prefs: UserDefaults, key: String) -> Any {
        guard let value = prefs.object(forKey: key) else { return NSNull() }
        if let number = value as? NSNumber {
            return number
        }
        if let doubleValue = value as? Double {
            return NSNumber(value: doubleValue)
        }
        if let intValue = value as? Int {
            return NSNumber(value: intValue)
        }
        if let int64Value = value as? Int64 {
            return NSNumber(value: int64Value)
        }
        return NSNull()
    }

    private static func jsonBool(from prefs: UserDefaults, key: String) -> Any {
        guard let value = prefs.object(forKey: key) else { return NSNull() }
        if let boolValue = value as? Bool {
            return boolValue
        }
        return NSNull()
    }


    private static func jsonArray(from prefs: UserDefaults, key: String) -> Any {
        guard let value = prefs.object(forKey: key) else { return NSNull() }
        if let arrayValue = value as? [String] {
            return arrayValue
        }
        return NSNull()
    }

    private static func parseOutcome(_ raw: String?) -> BackgroundRunOutcome? {
        guard let raw = raw?.lowercased() else { return nil }
        switch raw {
        case "success": return .success
        case "retry": return .retry
        case "failure": return .failure
        case "gated": return .gated
        default: return nil
        }
    }

    private static func parseGateReason(_ raw: String?) -> BackgroundGateReason? {
        guard let raw = raw?.lowercased() else { return nil }
        switch raw {
        case "none": return BackgroundGateReason.none
        case "no_network": return .noNetwork
        case "auth_invalid": return .authInvalid
        case "binding_invalid": return .bindingInvalid
        case "repair_required": return .repairRequired
        case "environment_blocked": return .environmentBlocked
        case "local_calendar_missing": return .localCalendarMissing
        case "unknown": return .unknown
        default: return nil
        }
    }

    static func persistSnapshot(
        outcome: BackgroundRunOutcome,
        reason: String?,
        gateReason: BackgroundGateReason = .none,
        error: String? = nil
    ) {
        let prefs = UserDefaults.standard
        let now = Date().timeIntervalSince1970 * 1000
        prefs.set(now, forKey: KEY_LAST_RUN_AT)
        prefs.set(outcome.rawValue, forKey: KEY_LAST_OUTCOME)
        prefs.set(reason ?? "", forKey: KEY_LAST_REASON)
        prefs.set(gateReason.rawValue, forKey: KEY_LAST_GATE)
        prefs.set(error ?? "", forKey: KEY_LAST_ERROR)
        prefs.set(now, forKey: KEY_LAST_ATTEMPT_AT)
        writeDiagnosticsFile()
    }

    static func persistFailureContext(
        failureStage: String,
        failureStep: String,
        elapsedMs: TimeInterval
    ) {
        let prefs = UserDefaults.standard
        prefs.set(failureStage, forKey: KEY_LAST_FAILURE_STAGE)
        prefs.set(elapsedMs * 1000, forKey: KEY_LAST_FAILURE_ELAPSED_MS)
        prefs.set(failureStep, forKey: KEY_LAST_FAILURE_STEP)
        writeDiagnosticsFile()
    }

    static func persistStage(_ stage: String) {
        let prefs = UserDefaults.standard
        let now = Date().timeIntervalSince1970 * 1000
        prefs.set(stage, forKey: KEY_LAST_STAGE)
        prefs.set(now, forKey: KEY_LAST_STAGE_AT)
        writeDiagnosticsFile()
    }

    static func handleTask(task: BGTask) {
        let prefs = UserDefaults.standard
        let attemptStartedAt = Date().timeIntervalSince1970 * 1000
        prefs.set(attemptStartedAt, forKey: KEY_LAST_RUN_AT)

        var trigger = "periodic"
        if task.identifier == SYNC_TASK_IDENTIFIER {
            trigger = UserDefaults.standard.string(forKey: "\(SYNC_TASK_IDENTIFIER)_trigger") ?? "oneoff"
        } else if task.identifier == WATCHDOG_TASK_IDENTIFIER {
            if !isPeriodicEnabled() {
                cancelWatchdogAlarm()
                persistFailureContext(
                    failureStage: STAGE_WORKER_FINISHED,
                    failureStep: "watchdog_periodic_disabled",
                    elapsedMs: 0
                )
                persistSnapshot(
                    outcome: .failure,
                    reason: "watchdog_ignored_periodic_disabled",
                    gateReason: .environmentBlocked,
                    error: "periodic_disabled"
                )
                persistStage(STAGE_WORKER_FINISHED)
                task.setTaskCompleted(success: false)
                return
            }
            let interval = readConfiguredIntervalMinutes()
            trigger = "watchdog"
            ensurePeriodic(intervalMinutes: interval)
        }

        Logger.default.info("Enter trigger=\(trigger)")

        isRunning = true

        // Schedule next periodic task if this is a periodic run
        if trigger.contains("periodic") {
            let interval = max(prefs.integer(forKey: KEY_PERIODIC_INTERVAL_MINUTES), 15)
            scheduleNextPeriodicTask(intervalMinutes: interval)
        }

        let expirationHandler = {
            let elapsedMs = (Date().timeIntervalSince1970 * 1000) - attemptStartedAt
            persistFailureContext(
                failureStage: STAGE_WORKER_FINISHED,
                failureStep: "worker_execution_timeout",
                elapsedMs: elapsedMs / 1000.0
            )
            persistSnapshot(
                outcome: .retry,
                reason: "sync_timeout",
                gateReason: .unknown,
                error: "worker_execution_timeout"
            )
            persistStage(STAGE_WORKER_FINISHED)
            isRunning = false
            currentEngine = nil
            task.setTaskCompleted(success: false)
        }

        task.expirationHandler = expirationHandler

        // Create Flutter engine and run sync
        DispatchQueue.main.async {
            runSyncTask(trigger: trigger, task: task, attemptStartedAt: attemptStartedAt)
        }
    }

    private static func scheduleNextPeriodicTask(intervalMinutes: Int) {
        do {
            try schedulePeriodic(intervalMinutes: intervalMinutes)
            scheduleWatchdogAlarm(intervalMinutes: intervalMinutes)
        } catch {
            Logger.default.error("Failed to schedule next periodic task: \(error.localizedDescription)")
        }
    }

    static func ensurePeriodic(intervalMinutes: Int) {
        do {
            try schedulePeriodic(intervalMinutes: intervalMinutes)
            scheduleWatchdogAlarm(intervalMinutes: intervalMinutes)
        } catch {
            Logger.default.error("Failed to ensure periodic: \(error.localizedDescription)")
            return
        }
        writeDiagnosticsFile()
    }

    private static func runSyncTask(trigger: String, task: BGTask, attemptStartedAt: TimeInterval) {
        guard let window = UIApplication.shared.delegate?.window,
              let rootViewController = window?.rootViewController,
              let flutterViewController = rootViewController as? FlutterViewController else {
            // If no Flutter view controller, create a new engine
            createAndRunEngine(trigger: trigger, task: task, attemptStartedAt: attemptStartedAt)
            return
        }

        // Use existing Flutter engine
        let engine = flutterViewController.engine
        setupAndRunSync(engine: engine, trigger: trigger, task: task, attemptStartedAt: attemptStartedAt)
    }

    private static func createAndRunEngine(trigger: String, task: BGTask, attemptStartedAt: TimeInterval) {
        let engine = FlutterEngine(name: "backgroundSyncEngine")
        guard engine.run(withEntrypoint: "caleeSyncBackgroundEntrypoint") else {
            let elapsedMs = (Date().timeIntervalSince1970 * 1000) - attemptStartedAt
            persistFailureContext(
                failureStage: STAGE_ENGINE_CREATED,
                failureStep: "engine_init_error",
                elapsedMs: elapsedMs / 1000.0
            )
            persistSnapshot(
                outcome: .retry,
                reason: "engine_init_error",
                gateReason: .unknown,
                error: "Failed to create Flutter engine"
            )
            task.setTaskCompleted(success: false)
            isRunning = false
            return
        }

        currentEngine = engine
        persistStage(STAGE_ENGINE_CREATED)
        BackgroundSafePluginRegistrant.registerBackgroundPlugins(with: engine)

        setupAndRunSync(engine: engine, trigger: trigger, task: task, attemptStartedAt: attemptStartedAt)
    }

    private static func setupAndRunSync(engine: FlutterEngine, trigger: String, task: BGTask, attemptStartedAt: TimeInterval) {
        let prefs = UserDefaults.standard
        var currentStage = STAGE_ENGINE_CREATED

        let readyLatch = DispatchSemaphore(value: 0)
        let runnerHostApi = BackgroundSyncRunnerHostApiImpl { contractVersion in
            prefs.set(contractVersion, forKey: KEY_LAST_READY_VERSION)
            currentStage = STAGE_DART_READY_RECEIVED
            persistStage(STAGE_DART_READY_RECEIVED)
            readyLatch.signal()
        }
        BackgroundSyncRunnerHostApiSetup.setUp(binaryMessenger: engine.binaryMessenger, api: runnerHostApi)

        // Setup Calendar API implemented in Swift (conforms to NativeCalendarApi)
        let calendarApi = CalendarHostApiImpl()
        NativeCalendarApiSetup.setUp(binaryMessenger: engine.binaryMessenger, api: calendarApi)

        currentStage = STAGE_DART_ENTRYPOINT_STARTED
        persistStage(STAGE_DART_ENTRYPOINT_STARTED)

        // Wait for Dart to be ready
        DispatchQueue.global(qos: .default).async {
            let waitResult = readyLatch.wait(timeout: .now() + DART_READY_TIMEOUT_MS)
            let isReady = (waitResult == .success)

            if !isReady {
                let elapsedMs = (Date().timeIntervalSince1970 * 1000) - attemptStartedAt
                currentStage = STAGE_DART_READY_TIMEOUT
                persistFailureContext(
                    failureStage: currentStage,
                    failureStep: "dart_not_ready",
                    elapsedMs: elapsedMs / 1000.0
                )
                persistSnapshot(
                    outcome: .retry,
                    reason: "dart_not_ready",
                    gateReason: .unknown
                )
                persistStage(currentStage)
                task.setTaskCompleted(success: false)
                isRunning = false
                currentEngine = nil
                return
            }

            // Invoke runBackgroundSync
            let runnerApi = BackgroundSyncRunnerApi(binaryMessenger: engine.binaryMessenger)
            persistStage(STAGE_RUN_SYNC_SENT)

            let request = BackgroundRunRequest(trigger: trigger, contractVersion: CONTRACT_VERSION)
            var hasReplied = false

            // Timeout handler
            DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + SYNC_REPLY_TIMEOUT_MS) {
                if !hasReplied {
                    hasReplied = true
                    let elapsedMs = (Date().timeIntervalSince1970 * 1000) - attemptStartedAt
                    currentStage = STAGE_RUN_SYNC_TIMEOUT
                    persistFailureContext(
                        failureStage: currentStage,
                        failureStep: "sync_reply_timeout",
                        elapsedMs: elapsedMs / 1000.0
                    )
                    persistSnapshot(
                        outcome: .retry,
                        reason: "engine_killed_or_no_reply",
                        gateReason: .unknown,
                        error: "sync_reply_timeout"
                    )
                    persistStage(currentStage)
                    task.setTaskCompleted(success: false)
                    isRunning = false
                    currentEngine = nil
                }
            }

            runnerApi.runBackgroundSync(request: request) { result in
                guard !hasReplied else { return }
                hasReplied = true

                switch result {
                case .success(let runResult):
                    persistStage(STAGE_RUN_SYNC_REPLIED)
                    let outcome = runResult.outcome
                    persistSnapshot(
                        outcome: outcome,
                        reason: runResult.reason,
                        gateReason: runResult.gateReason,
                        error: runResult.error
                    )
                    Logger.default.info("Classified outcome=\(outcome.rawValue) mapped=\(outcome == .success || outcome == .gated ? "success" : "retry") reason=\(runResult.reason) gate=\(runResult.gateReason.rawValue) version=\(runResult.contractVersion)")

                    let success = (outcome == .success || outcome == .gated)
                    persistStage(STAGE_WORKER_FINISHED)
                    task.setTaskCompleted(success: success)
                    isRunning = false
                    currentEngine = nil

                case .failure(let error):
                    let elapsedMs = (Date().timeIntervalSince1970 * 1000) - attemptStartedAt
                    currentStage = STAGE_RUN_SYNC_REPLIED
                    persistFailureContext(
                        failureStage: currentStage,
                        failureStep: "runner_channel_error",
                        elapsedMs: elapsedMs / 1000.0
                    )
                    persistStage(currentStage)
                    persistSnapshot(
                        outcome: .retry,
                        reason: "runner_channel_error",
                        gateReason: .unknown,
                        error: error.localizedDescription
                    )
                    task.setTaskCompleted(success: false)
                    isRunning = false
                    currentEngine = nil
                }
            }
        }
    }
}

// Helper class for BackgroundSyncRunnerHostApi
class BackgroundSyncRunnerHostApiImpl: BackgroundSyncRunnerHostApi {
    private let onReady: (Int64) -> Void

    init(onReady: @escaping (Int64) -> Void) {
        self.onReady = onReady
    }

    func notifyBackgroundIsolateReady(contractVersion: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
        onReady(contractVersion)
        completion(.success(()))
    }
}

extension os.Logger {
    private static var subsystem = Bundle.main.bundleIdentifier!
    static let `default` = Logger(subsystem: subsystem, category: "CaleeSyncWorker")
}
