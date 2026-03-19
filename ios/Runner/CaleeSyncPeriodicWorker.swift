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
    
    static let PERIODIC_TASK_IDENTIFIER = "com.calee.caleesync.periodic"
    static let SYNC_TASK_IDENTIFIER = "com.calee.caleesync.sync"
    static let WATCHDOG_TASK_IDENTIFIER = "com.calee.caleesync.watchdog"
    
    static let CONTRACT_VERSION: Int64 = 1
    static let DART_READY_TIMEOUT_MS: TimeInterval = 15.0
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
    
    static func schedulePeriodic(intervalMinutes: Int) throws {
        let bounded = max(intervalMinutes, 15)
        let request = BGAppRefreshTaskRequest(identifier: PERIODIC_TASK_IDENTIFIER)
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(bounded * 60))
        
        try BGTaskScheduler.shared.submit(request)
        Logger.default.info("Scheduled periodic task with interval: \(bounded) minutes")
    }
    
    static func cancelPeriodic() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: PERIODIC_TASK_IDENTIFIER)
        Logger.default.info("Cancelled periodic task")
    }
    
    static func isPeriodicScheduled() -> Bool {
        // Check if periodic is enabled in preferences
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
        
        let request = BGAppRefreshTaskRequest(identifier: WATCHDOG_TASK_IDENTIFIER)
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(watchdogInterval * 60))
        
        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.default.info("Scheduled watchdog alarm")
        } catch {
            Logger.default.error("Failed to schedule watchdog alarm: \(error.localizedDescription)")
        }
    }
    
    static func cancelWatchdogAlarm() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: WATCHDOG_TASK_IDENTIFIER)
        Logger.default.info("Cancelled watchdog alarm")
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
        let periodicEnabled = prefs.bool(forKey: KEY_PERIODIC_ENABLED) && isPeriodicScheduled()
        let configuredInterval = max(prefs.integer(forKey: KEY_PERIODIC_INTERVAL_MINUTES), 15)
        let nextAt = prefs.double(forKey: KEY_PERIODIC_NEXT_AT)
        let lastRunAt = prefs.double(forKey: KEY_LAST_RUN_AT)
        
        let lastOutcomeRaw = prefs.string(forKey: KEY_LAST_OUTCOME)
        let lastOutcome = parseOutcome(lastOutcomeRaw)
        
        let lastGateRaw = prefs.string(forKey: KEY_LAST_GATE)
        let lastGateReason = parseGateReason(lastGateRaw)
        
        // iOS doesn't have WorkManager states, so we use nil for work states
        // but we can check if tasks are scheduled
        let periodicWorkState: String? = isPeriodicScheduled() ? "ENQUEUED" : nil
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
        case "none": return .none
        case "no_network": return .noNetwork
        case "auth_invalid": return .authInvalid
        case "binding_invalid": return .bindingInvalid
        case "repair_required", "reconnect_required", "reconnect_verifying", "reconnect_mismatch":
            return .repairRequired
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
    }
    
    static func persistStage(_ stage: String) {
        let prefs = UserDefaults.standard
        let now = Date().timeIntervalSince1970 * 1000
        prefs.set(stage, forKey: KEY_LAST_STAGE)
        prefs.set(now, forKey: KEY_LAST_STAGE_AT)
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
                task.setTaskCompleted(success: false)
                return
            }
            let interval = readConfiguredIntervalMinutes()
            ensurePeriodic(intervalMinutes: interval)
            if !shouldSkipWatchdogOneOff() {
                do {
                    try enqueueOneOff(reason: "watchdog", expedited: false, enqueuePolicy: .replace)
                } catch {
                    Logger.default.error("Failed to enqueue watchdog one-off: \(error.localizedDescription)")
                }
            }
            scheduleWatchdogAlarm(intervalMinutes: interval)
            task.setTaskCompleted(success: true)
            return
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
        let prefs = UserDefaults.standard
        let nextAt = Date().addingTimeInterval(TimeInterval(intervalMinutes * 60))
        prefs.set(nextAt.timeIntervalSince1970 * 1000, forKey: KEY_PERIODIC_NEXT_AT)
        prefs.set(intervalMinutes, forKey: KEY_PERIODIC_INTERVAL_MINUTES)
        
        do {
            try schedulePeriodic(intervalMinutes: intervalMinutes)
            scheduleWatchdogAlarm(intervalMinutes: intervalMinutes)
        } catch {
            Logger.default.error("Failed to schedule next periodic task: \(error.localizedDescription)")
        }
    }
    
    static func ensurePeriodic(intervalMinutes: Int) {
        if !isPeriodicScheduled() {
            do {
                try schedulePeriodic(intervalMinutes: intervalMinutes)
            } catch {
                Logger.default.error("Failed to ensure periodic: \(error.localizedDescription)")
            }
        }
    }
    
    private static func runSyncTask(trigger: String, task: BGTask, attemptStartedAt: TimeInterval) {
        let prefs = UserDefaults.standard
        
        guard let window = UIApplication.shared.delegate?.window,
              let rootViewController = window?.rootViewController,
              let flutterViewController = rootViewController as? FlutterViewController else {
            // If no Flutter view controller, create a new engine
            createAndRunEngine(trigger: trigger, task: task)
            return
        }
        
        // Use existing Flutter engine
        let engine = flutterViewController.engine
        setupAndRunSync(engine: engine, trigger: trigger, task: task, attemptStartedAt: attemptStartedAt)
    }
    
    private static func createAndRunEngine(trigger: String, task: BGTask) {
        let attemptStartedAt = Date().timeIntervalSince1970 * 1000
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
        
        setupAndRunSync(engine: engine, trigger: trigger, task: task, attemptStartedAt: attemptStartedAt)
    }
    
    private static func setupAndRunSync(engine: FlutterEngine, trigger: String, task: BGTask, attemptStartedAt: TimeInterval) {
        let prefs = UserDefaults.standard
        var currentStage = STAGE_ENGINE_CREATED
        
        // Setup Calendar API implemented in Swift (conforms to NativeCalendarApi)
        let calendarApi = CalendarHostApiImpl()
        NativeCalendarApiSetup.setUp(binaryMessenger: engine.binaryMessenger, api: calendarApi)
        
        // Setup BackgroundSyncRunnerHostApi
        let readyLatch = DispatchSemaphore(value: 0)
        let runnerHostApi = BackgroundSyncRunnerHostApiImpl { contractVersion in
            prefs.set(contractVersion, forKey: KEY_LAST_READY_VERSION)
            currentStage = STAGE_DART_READY_RECEIVED
            persistStage(STAGE_DART_READY_RECEIVED)
            readyLatch.signal()
        }
        BackgroundSyncRunnerHostApiSetup.setUp(binaryMessenger: engine.binaryMessenger, api: runnerHostApi)
        
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
