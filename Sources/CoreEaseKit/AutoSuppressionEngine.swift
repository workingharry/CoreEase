import Foundation
import IOKit.ps

/// Reads macOS power sources (Battery vs AC adapter)
public struct PowerSourceMonitor: Sendable {
    public static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }

        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               let state = desc[kIOPSPowerSourceStateKey as String] as? String {
                if state == (kIOPSBatteryPowerValue as String) {
                    return true
                }
            }
        }
        return false
    }
}

/// Rolling hysteresis window tracker for continuous high CPU load
public struct SustainedLoadTracker: Sendable {
    public let thresholdPercent: Double
    public let requiredConsecutiveSamples: Int
    private var consecutiveCount: Int = 0

    public init(thresholdPercent: Double = 75.0, requiredConsecutiveSamples: Int = 3) {
        self.thresholdPercent = thresholdPercent
        self.requiredConsecutiveSamples = max(1, requiredConsecutiveSamples)
    }

    /// Records a new CPU usage sample. Returns `true` if sustained threshold has been reached.
    public mutating func recordSample(cpuPercent: Double) -> Bool {
        if cpuPercent >= thresholdPercent {
            consecutiveCount += 1
            return consecutiveCount >= requiredConsecutiveSamples
        } else {
            consecutiveCount = 0
            return false
        }
    }

    public mutating func reset() {
        consecutiveCount = 0
    }
}

/// Configuration for intelligent automated CPU suppression
public struct AutoSuppressConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var cpuThreshold: Double
    public var sustainedSamples: Int
    public var onlyOnBattery: Bool
    public var autoEcoClamp: Bool
    public var autoThrottleLimit: Int

    public init(
        enabled: Bool = false,
        cpuThreshold: Double = 75.0,
        sustainedSamples: Int = 3,
        onlyOnBattery: Bool = true,
        autoEcoClamp: Bool = true,
        autoThrottleLimit: Int = 60
    ) {
        self.enabled = enabled
        self.cpuThreshold = cpuThreshold
        self.sustainedSamples = sustainedSamples
        self.onlyOnBattery = onlyOnBattery
        self.autoEcoClamp = autoEcoClamp
        self.autoThrottleLimit = autoThrottleLimit
    }
}

public struct AutoSuppressAction: Sendable, Equatable {
    public enum ActionType: Sendable, Equatable {
        case suppress
        case restore
    }
    public let pid: Int32
    public let name: String
    public let action: ActionType

    public init(pid: Int32, name: String, action: ActionType) {
        self.pid = pid
        self.name = name
        self.action = action
    }
}

/// Core evaluation engine for auto-suppression
public struct AutoSuppressionEngine: Sendable {
    public var config: AutoSuppressConfig
    private var loadTrackers: [Int32: SustainedLoadTracker] = [:]
    private var suppressedPIDs: Set<Int32> = []
    private var frontmostPID: Int32?

    public init(config: AutoSuppressConfig = AutoSuppressConfig()) {
        self.config = config
    }

    public func isAutoSuppressed(pid: Int32) -> Bool {
        return suppressedPIDs.contains(pid)
    }

    /// Informs the engine of the current active/frontmost application
    public mutating func updateFrontmostApp(pid: Int32?) -> [AutoSuppressAction] {
        var actions: [AutoSuppressAction] = []
        self.frontmostPID = pid

        // If the newly focused app was previously auto-suppressed, immediately unsuppress it!
        if let pid = pid, suppressedPIDs.contains(pid) {
            suppressedPIDs.remove(pid)
            loadTrackers.removeValue(forKey: pid)
            actions.append(AutoSuppressAction(pid: pid, name: "", action: .restore))
        }
        return actions
    }

    /// Evaluates active processes against load thresholds and power state
    public mutating func evaluate(processes: [TrackedProcess], isOnBattery: Bool) -> [AutoSuppressAction] {
        guard config.enabled else {
            return restoreAll()
        }

        if config.onlyOnBattery && !isOnBattery {
            return restoreAll()
        }

        var actions: [AutoSuppressAction] = []
        let activePIDs = Set(processes.map { $0.pid })

        // Cleanup stale PIDs that terminated
        suppressedPIDs = suppressedPIDs.intersection(activePIDs)
        loadTrackers = loadTrackers.filter { activePIDs.contains($0.key) }

        for proc in processes {
            // Safety: Never auto-suppress system protected processes or the frontmost app
            if proc.safetyTier == .protectedSystem || proc.pid == frontmostPID {
                if suppressedPIDs.contains(proc.pid) {
                    suppressedPIDs.remove(proc.pid)
                    loadTrackers.removeValue(forKey: proc.pid)
                    actions.append(AutoSuppressAction(pid: proc.pid, name: proc.name, action: .restore))
                }
                continue
            }

            // Evaluate sustained load
            var tracker = loadTrackers[proc.pid] ?? SustainedLoadTracker(
                thresholdPercent: config.cpuThreshold,
                requiredConsecutiveSamples: config.sustainedSamples
            )

            let isSustainedHigh = tracker.recordSample(cpuPercent: proc.cpuUsage)
            loadTrackers[proc.pid] = tracker

            if isSustainedHigh && !suppressedPIDs.contains(proc.pid) {
                suppressedPIDs.insert(proc.pid)
                actions.append(AutoSuppressAction(pid: proc.pid, name: proc.name, action: .suppress))
            } else if proc.cpuUsage < (config.cpuThreshold / 2.0) && suppressedPIDs.contains(proc.pid) {
                // Exit hysteresis: Load has naturally cooled down below half the threshold
                suppressedPIDs.remove(proc.pid)
                tracker.reset()
                loadTrackers[proc.pid] = tracker
                actions.append(AutoSuppressAction(pid: proc.pid, name: proc.name, action: .restore))
            }
        }

        return actions
    }

    public mutating func restoreAll() -> [AutoSuppressAction] {
        let actions = suppressedPIDs.map { AutoSuppressAction(pid: $0, name: "", action: .restore) }
        suppressedPIDs.removeAll()
        loadTrackers.removeAll()
        return actions
    }
}
