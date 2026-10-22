import XCTest
@testable import CoreEaseKit

final class CoreEaseKitTests: XCTestCase {
    // Seam 1: Process Monitor Public Output
    func testProcessMonitorReturnsValidProcesses() {
        let procs = ProcessMonitor.shared.getTopProcesses(limit: 5)
        XCTAssertFalse(procs.isEmpty, "Should find running processes on macOS")
        if let first = procs.first {
            XCTAssertGreaterThan(first.pid, 0)
            XCTAssertFalse(first.name.isEmpty)
        }
    }

    // Seam 2: Core Scheduler E-Core Clamping & Reset
    func testCoreSchedulerEfficiencyClampAndReset() {
        let currentPid = ProcessInfo.processInfo.processIdentifier

        // Red -> Green: clamping to E-cores via Darwin taskpolicy
        let clamped = CoreScheduler.shared.clampToEfficiencyCores(pid: currentPid)
        XCTAssertTrue(clamped, "Should clamp current process to E-Cores")

        // Red -> Green: resetting back to default QoS
        let reset = CoreScheduler.shared.resetToDefaultCores(pid: currentPid)
        XCTAssertTrue(reset, "Should reset current process to default QoS")
    }

    // Seam 3: CPU Throttler State Lifecycle & StopAll Safety
    func testThrottlerLifecycleAndSafety() {
        let currentPid = ProcessInfo.processInfo.processIdentifier

        XCTAssertFalse(CPUThrottler.shared.isThrottling(pid: currentPid))
        CPUThrottler.shared.setLimit(pid: currentPid, percent: 50)
        XCTAssertTrue(CPUThrottler.shared.isThrottling(pid: currentPid))

        CPUThrottler.shared.stopThrottling(pid: currentPid)
        XCTAssertFalse(CPUThrottler.shared.isThrottling(pid: currentPid))

        // Multi-PID StopAll safety test
        CPUThrottler.shared.setLimit(pid: currentPid, percent: 30)
        XCTAssertTrue(CPUThrottler.shared.isThrottling(pid: currentPid))
        CPUThrottler.shared.stopAll()
        XCTAssertFalse(CPUThrottler.shared.isThrottling(pid: currentPid))
    }
}
