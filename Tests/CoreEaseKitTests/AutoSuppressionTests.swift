import Foundation
import CoreEaseKit
import XCTest

final class AutoSuppressionTests: XCTestCase {
    func testPowerStateDetection() {
        let isBattery = PowerSourceMonitor.isOnBattery()
        // Should evaluate to a boolean without crashing or hanging
        XCTAssertTrue(isBattery == true || isBattery == false)
    }

    func testHysteresisTrackerTriggersAfterSustainedThreshold() {
        var tracker = SustainedLoadTracker(thresholdPercent: 75.0, requiredConsecutiveSamples: 3)

        // Sample 1: High
        XCTAssertFalse(tracker.recordSample(cpuPercent: 85.0))
        // Sample 2: Drop below threshold (resets counter)
        XCTAssertFalse(tracker.recordSample(cpuPercent: 30.0))
        // Sample 3: High
        XCTAssertFalse(tracker.recordSample(cpuPercent: 90.0))
        // Sample 4: High
        XCTAssertFalse(tracker.recordSample(cpuPercent: 88.0))
        // Sample 5: High -> 3rd consecutive sample above 75.0 -> Triggers!
        XCTAssertTrue(tracker.recordSample(cpuPercent: 92.0))
    }

    func testFrontmostAppIsNeverSuppressed() {
        var engine = AutoSuppressionEngine(
            config: AutoSuppressConfig(
                enabled: true,
                cpuThreshold: 70.0,
                sustainedSamples: 2,
                onlyOnBattery: false
            )
        )

        let heavyFrontmostPID: Int32 = 1234
        let heavyBackgroundPID: Int32 = 5678

        engine.updateFrontmostApp(pid: heavyFrontmostPID)

        // Process samples
        let procs = [
            TrackedProcess(pid: heavyFrontmostPID, name: "Xcode", cpuUsage: 95.0),
            TrackedProcess(pid: heavyBackgroundPID, name: "RendererHelper", cpuUsage: 90.0)
        ]

        // Pass 1
        let actions1 = engine.evaluate(processes: procs, isOnBattery: true)
        XCTAssertTrue(actions1.isEmpty, "Should not trigger on first sample")

        // Pass 2 -> Sustained trigger
        let actions2 = engine.evaluate(processes: procs, isOnBattery: true)

        // heavyFrontmostPID must be excluded; heavyBackgroundPID must be suppressed
        XCTAssertFalse(actions2.contains(where: { $0.pid == heavyFrontmostPID }), "Frontmost active app must NOT be suppressed")
        XCTAssertTrue(actions2.contains(where: { $0.pid == heavyBackgroundPID }), "Heavy background app should be auto-suppressed")
    }

    func testInstantRecoveryWhenAppBecomesFrontmost() {
        var engine = AutoSuppressionEngine(
            config: AutoSuppressConfig(
                enabled: true,
                cpuThreshold: 70.0,
                sustainedSamples: 1,
                onlyOnBattery: false
            )
        )

        let targetPID: Int32 = 5678
        engine.updateFrontmostApp(pid: 9999) // User is working in another app

        let procs = [TrackedProcess(pid: targetPID, name: "RendererHelper", cpuUsage: 85.0)]
        let suppressActions = engine.evaluate(processes: procs, isOnBattery: true)
        XCTAssertTrue(suppressActions.contains(where: { $0.pid == targetPID }))
        XCTAssertTrue(engine.isAutoSuppressed(pid: targetPID))

        // User switches focus to this app -> Instant unsuppress event
        let unsuppressActions = engine.updateFrontmostApp(pid: targetPID)
        XCTAssertTrue(unsuppressActions.contains(where: { $0.pid == targetPID }), "Must unsuppress immediately upon becoming frontmost")
        XCTAssertFalse(engine.isAutoSuppressed(pid: targetPID))
    }
}
