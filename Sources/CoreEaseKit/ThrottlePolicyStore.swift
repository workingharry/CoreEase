import Foundation

/// Persistent user throttle policy for an application
public struct AppThrottlePolicy: Codable, Sendable, Equatable {
    public let appName: String
    public var isEco: Bool
    public var throttleLimitPercent: Int?

    public init(appName: String, isEco: Bool = false, throttleLimitPercent: Int? = nil) {
        self.appName = appName
        self.isEco = isEco
        self.throttleLimitPercent = throttleLimitPercent
    }
}

/// Durable policy store backed by UserDefaults
public final class ThrottlePolicyStore: @unchecked Sendable {
    public static let shared = ThrottlePolicyStore()

    private let storageKey: String
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(storageKey: String = "com.coreease.throttle.policies", defaults: UserDefaults = .standard) {
        self.storageKey = storageKey
        self.defaults = defaults
    }

    /// Retrieve all configured policies keyed by application name
    public func getAllPolicies() -> [String: AppThrottlePolicy] {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([AppThrottlePolicy].self, from: data) else {
            return [:]
        }

        var map: [String: AppThrottlePolicy] = [:]
        for policy in list {
            map[policy.appName] = policy
        }
        return map
    }

    public func getPolicy(for appName: String) -> AppThrottlePolicy? {
        return getAllPolicies()[appName]
    }

    public func setPolicy(_ policy: AppThrottlePolicy) {
        lock.lock()
        defer { lock.unlock() }

        var current = loadList()
        current.removeAll { $0.appName == policy.appName }
        current.append(policy)
        saveList(current)
    }

    public func removePolicy(for appName: String) {
        lock.lock()
        defer { lock.unlock() }

        var current = loadList()
        current.removeAll { $0.appName == appName }
        saveList(current)
    }

    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }

    /// Matches and resolves stored user policies for active processes
    public func resolvePolicies(for processes: [TrackedProcess]) -> [Int32: AppThrottlePolicy] {
        let policies = getAllPolicies()
        var resolved: [Int32: AppThrottlePolicy] = [:]

        for proc in processes {
            if let policy = policies[proc.name] {
                resolved[proc.pid] = policy
            }
        }
        return resolved
    }

    private func loadList() -> [AppThrottlePolicy] {
        guard let data = defaults.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([AppThrottlePolicy].self, from: data) else {
            return []
        }
        return list
    }

    private func saveList(_ list: [AppThrottlePolicy]) {
        if let encoded = try? JSONEncoder().encode(list) {
            defaults.set(encoded, forKey: storageKey)
        }
    }
}
