import Foundation
import CoreEaseKit
import XCTest

final class PolicyPersistenceTests: XCTestCase {
    func testPolicySaveAndLoad() {
        let store = ThrottlePolicyStore(storageKey: "test.throttle.policies")
        defer { store.clearAll() }

        // Test saving an Eco and Throttled policy by process name
        let policy = AppThrottlePolicy(
            appName: "Google Chrome",
            isEco: true,
            throttleLimitPercent: 70
        )
        store.setPolicy(policy)

        let loaded = store.getPolicy(for: "Google Chrome")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.appName, "Google Chrome")
        XCTAssertEqual(loaded?.isEco, true)
        XCTAssertEqual(loaded?.throttleLimitPercent, 70)

        // Test removing policy
        store.removePolicy(for: "Google Chrome")
        XCTAssertNil(store.getPolicy(for: "Google Chrome"))
    }

    func testPolicyMatchingAndReapply() {
        let store = ThrottlePolicyStore(storageKey: "test.throttle.matching")
        defer { store.clearAll() }

        let testPolicy = AppThrottlePolicy(
            appName: "TestRunner",
            isEco: true,
            throttleLimitPercent: 65
        )
        store.setPolicy(testPolicy)

        let activeProcs = [
            TrackedProcess(pid: 99991, name: "TestRunner", cpuUsage: 12.0),
            TrackedProcess(pid: 99992, name: "Safari", cpuUsage: 5.0)
        ]

        let matched = store.resolvePolicies(for: activeProcs)
        XCTAssertEqual(matched[99991]?.throttleLimitPercent, 65)
        XCTAssertEqual(matched[99991]?.isEco, true)
        XCTAssertNil(matched[99992]?.throttleLimitPercent)
    }
}
