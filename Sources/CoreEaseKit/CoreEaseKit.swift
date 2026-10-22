import Foundation
import Darwin

/// Safety classification for macOS processes to prevent accidental system instability
public enum ProcessSafetyTier: String, Sendable, CaseIterable {
    case protectedSystem = "System Protected"
    case cautionDaemon = "System Daemon"
    case safeApp = "User App"

    public var badgeIcon: String {
        switch self {
        case .protectedSystem: return "shield.fill"
        case .cautionDaemon: return "exclamationmark.triangle.fill"
        case .safeApp: return "checkmark.seal.fill"
        }
    }

    public var recommendation: String {
        switch self {
        case .protectedSystem:
            return "Do not throttle or suspend: essential for macOS UI, window compositor, or core stability."
        case .cautionDaemon:
            return "System background daemon: E-Core Eco mode is safe, but avoid aggressive throttling."
        case .safeApp:
            return "Safe to throttle and clamp to E-Cores (browsers, editors, user tasks)."
        }
    }
}

public struct ProcessSafetyEvaluator: Sendable {
    private static let protectedServices: Set<String> = [
        "WindowServer",
        "launchd",
        "loginwindow",
        "diskarbitrationd",
        "opendirectoryd",
        "kernel_task",
        "distnoted",
        "notifyd",
        "fseventsd",
        "securityd",
        "coreaudiod"
    ]

    private static let cautionServices: Set<String> = [
        "bird",
        "cloudd",
        "fileproviderd",
        "sharingd",
        "rapportd",
        "nsurlsessiond",
        "nearbyd",
        "intelligenceflowd",
        "ospredictiond",
        "mds",
        "mds_stores",
        "mdworker",
        "syspolicyd",
        "analyticsd"
    ]

    public static func evaluate(name: String) -> ProcessSafetyTier {
        if protectedServices.contains(name) {
            return .protectedSystem
        } else if cautionServices.contains(name) || name.hasSuffix("d") {
            return .cautionDaemon
        }
        return .safeApp
    }
}

/// CoreEaseKit Model representing a running macOS Process
public struct TrackedProcess: Identifiable, Sendable {
    public let id: Int32
    public let name: String
    public let pid: Int32
    public var cpuUsage: Double
    public var isEfficiencyClamped: Bool
    public var throttleLimitPercent: Int?
    public var safetyTier: ProcessSafetyTier

    public init(pid: Int32, name: String, cpuUsage: Double = 0.0, isEfficiencyClamped: Bool = false, throttleLimitPercent: Int? = nil, safetyTier: ProcessSafetyTier = .safeApp) {
        self.id = pid
        self.pid = pid
        self.name = name
        self.cpuUsage = cpuUsage
        self.isEfficiencyClamped = isEfficiencyClamped
        self.throttleLimitPercent = throttleLimitPercent
        self.safetyTier = safetyTier
    }
}

/// Core scheduling manager for routing processes between Apple Silicon Efficiency (E-Cores) and Performance Cores (P-Cores)
public final class CoreScheduler: Sendable {
    public static let shared = CoreScheduler()

    public init() {}

    /// Restricts a process to run on Apple Silicon Efficiency Cores using Darwin Background QoS
    @discardableResult
    public func clampToEfficiencyCores(pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        process.arguments = ["-b", "-p", "\(pid)"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Resets a process from Efficiency-only back to default system scheduling (allows P-Cores)
    @discardableResult
    public func resetToDefaultCores(pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        process.arguments = ["-B", "-p", "\(pid)"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Dynamic CPU throttler that caps target process CPU usage to a user-defined percentage using micro-sliced POSIX signals
public final class CPUThrottler: @unchecked Sendable {
    public static let shared = CPUThrottler()

    private let queue = DispatchQueue(label: "com.coreease.throttler", attributes: .concurrent)
    private var activeThrottles: [Int32: DispatchWorkItem] = [:]
    private let lock = NSLock()

    public init() {}

    /// Starts throttling a process to a target maximum CPU percentage (10% - 90%)
    public func setLimit(pid: Int32, percent: Int) {
        stopThrottling(pid: pid)

        let clampedPercent = max(5, min(95, percent))
        let cycleDurationMs: Double = 100.0 // 100ms total cycle
        let workDurationMs = cycleDurationMs * (Double(clampedPercent) / 100.0)
        let sleepDurationMs = cycleDurationMs - workDurationMs

        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            while !(workItem?.isCancelled ?? true) {
                // Let the process run for workDurationMs
                kill(pid, SIGCONT)
                usleep(useconds_t(workDurationMs * 1000.0))

                if workItem?.isCancelled ?? true { break }

                // Suspend the process for sleepDurationMs
                kill(pid, SIGSTOP)
                usleep(useconds_t(sleepDurationMs * 1000.0))

                // Verify process still exists
                if kill(pid, 0) != 0 {
                    self?.stopThrottling(pid: pid)
                    break
                }
            }
            // Ensure process is running when throttling stops
            kill(pid, SIGCONT)
        }

        lock.lock()
        activeThrottles[pid] = workItem
        lock.unlock()

        queue.async(execute: workItem)
    }

    /// Stops throttling and restores process to run continuously
    public func stopThrottling(pid: Int32) {
        lock.lock()
        if let workItem = activeThrottles.removeValue(forKey: pid) {
            workItem.cancel()
        }
        lock.unlock()

        // Un-pause if suspended
        kill(pid, SIGCONT)
    }

    public func isThrottling(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeThrottles[pid] != nil
    }

    /// Stops throttling on all processes and ensures no processes are left paused
    public func stopAll() {
        lock.lock()
        let pids = Array(activeThrottles.keys)
        for (_, workItem) in activeThrottles {
            workItem.cancel()
        }
        activeThrottles.removeAll()
        lock.unlock()

        for pid in pids {
            kill(pid, SIGCONT)
        }
    }
}

/// Process Monitor to retrieve active CPU consumers
public final class ProcessMonitor: Sendable {
    public static let shared = ProcessMonitor()

    public init() {}

    /// Fetches top active processes with their current CPU usage
    public func getTopProcesses(limit: Int = 40) -> [TrackedProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Aceo", "pid,%cpu,comm", "-r"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return [] }
            let lines = output.components(separatedBy: "\n").dropFirst()

            var results: [TrackedProcess] = []
            for line in lines {
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                if parts.count >= 3,
                   let pid = Int32(parts[0]),
                   let cpu = Double(parts[1]) {
                    let fullPath = String(parts[2])
                    let name = (fullPath as NSString).lastPathComponent
                    if pid > 0 && name != "ps" && name != "coreease-cli" {
                        let tier = ProcessSafetyEvaluator.evaluate(name: name)
                        results.append(TrackedProcess(pid: pid, name: name, cpuUsage: cpu, safetyTier: tier))
                    }
                }
                if results.count >= limit { break }
            }
            return results
        } catch {
            return []
        }
    }
}
