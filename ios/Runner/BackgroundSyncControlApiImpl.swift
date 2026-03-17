import Foundation
import BackgroundTasks
import Flutter

class BackgroundSyncControlApiImpl: BackgroundSyncControlApi {
    private let scheduler = BGTaskScheduler.shared
    
    func schedulePeriodic(intervalMinutes: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .default).async {
            do {
                let bounded = max(intervalMinutes, 15)
                try CaleeSyncPeriodicWorker.schedulePeriodic(intervalMinutes: Int(bounded))
                UserDefaults.standard.set(true, forKey: CaleeSyncPeriodicWorker.KEY_PERIODIC_ENABLED)
                UserDefaults.standard.set(Int(bounded), forKey: CaleeSyncPeriodicWorker.KEY_PERIODIC_INTERVAL_MINUTES)
                let nextAt = Date().addingTimeInterval(TimeInterval(bounded * 60))
                UserDefaults.standard.set(nextAt.timeIntervalSince1970 * 1000, forKey: CaleeSyncPeriodicWorker.KEY_PERIODIC_NEXT_AT)
                CaleeSyncPeriodicWorker.scheduleWatchdogAlarm(intervalMinutes: Int(bounded))
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    func cancelPeriodic(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .default).async {
            do {
                CaleeSyncPeriodicWorker.cancelPeriodic()
                UserDefaults.standard.set(false, forKey: CaleeSyncPeriodicWorker.KEY_PERIODIC_ENABLED)
                UserDefaults.standard.removeObject(forKey: CaleeSyncPeriodicWorker.KEY_PERIODIC_NEXT_AT)
                CaleeSyncPeriodicWorker.cancelWatchdogAlarm()
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    func ensurePeriodicScheduled(intervalMinutes: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .default).async {
            do {
                let bounded = max(intervalMinutes, 15)
                let isScheduled = CaleeSyncPeriodicWorker.isPeriodicScheduled()
                if !isScheduled {
                    try CaleeSyncPeriodicWorker.schedulePeriodic(intervalMinutes: Int(bounded))
                }
                CaleeSyncPeriodicWorker.scheduleWatchdogAlarm(intervalMinutes: Int(bounded))
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    func enqueueOneOff(reason: String, expedited: Bool, enqueuePolicy: OneOffEnqueuePolicy, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .default).async {
            do {
                try CaleeSyncPeriodicWorker.enqueueOneOff(reason: reason, expedited: expedited, enqueuePolicy: enqueuePolicy)
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    func getBackgroundStatus(completion: @escaping (Result<BackgroundStatusDto, Error>) -> Void) {
        DispatchQueue.global(qos: .default).async {
            do {
                let status = CaleeSyncPeriodicWorker.readStatus()
                DispatchQueue.main.async {
                    completion(.success(status))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}

