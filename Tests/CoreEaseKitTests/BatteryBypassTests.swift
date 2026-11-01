import XCTest
@testable import CoreEaseKit

final class BatteryBypassTests: XCTestCase {
    
    private final class TestSMCController: SMCChargingControllerProtocol, @unchecked Sendable {
        var inhibited: Bool = false

        func isChargingInhibited() -> Bool {
            return inhibited
        }

        func setChargingInhibited(_ inhibited: Bool) -> Result<Void, SMCError> {
            self.inhibited = inhibited
            return .success(())
        }
    }

    func testBypassDoesNotTriggerWhenDisabled() {
        let mock = TestSMCController()
        let config = PowerBypassConfig(enabled: false, targetLimitPercent: 80, autoResumeChargeBelow: 75)
        let engine = BatteryBypassEngine(config: config, controller: mock)

        let diag = BatteryDiagnostics(
            cycleCount: 400,
            maxCapacityPercent: 90,
            currentCapacityPercent: 85,
            isExternalConnected: true,
            isCharging: true
        )

        let result = engine.evaluate(diagnostics: diag)
        XCTAssertNil(result)
        XCTAssertFalse(mock.isChargingInhibited())
    }

    func testBypassTriggersWhenTargetLimitReachedOnAC() {
        let mock = TestSMCController()
        let config = PowerBypassConfig(enabled: true, targetLimitPercent: 80, autoResumeChargeBelow: 75)
        let engine = BatteryBypassEngine(config: config, controller: mock)

        let diag = BatteryDiagnostics(
            cycleCount: 402,
            maxCapacityPercent: 85,
            currentCapacityPercent: 80,
            isExternalConnected: true,
            isCharging: true
        )

        let result = engine.evaluate(diagnostics: diag)
        XCTAssertEqual(result, true)
        XCTAssertTrue(mock.isChargingInhibited())
    }

    func testBypassHysteresisResumesChargingWhenDroppedBelowFloor() {
        let mock = TestSMCController()
        mock.inhibited = true
        let config = PowerBypassConfig(enabled: true, targetLimitPercent: 80, autoResumeChargeBelow: 75)
        let engine = BatteryBypassEngine(config: config, controller: mock)

        let diag = BatteryDiagnostics(
            cycleCount: 402,
            maxCapacityPercent: 85,
            currentCapacityPercent: 74,
            isExternalConnected: true,
            isCharging: false
        )

        let result = engine.evaluate(diagnostics: diag)
        XCTAssertEqual(result, false)
        XCTAssertFalse(mock.isChargingInhibited())
    }

    func testBypassRestoresNormalChargingWhenACDisconnected() {
        let mock = TestSMCController()
        mock.inhibited = true
        let config = PowerBypassConfig(enabled: true, targetLimitPercent: 80, autoResumeChargeBelow: 75)
        let engine = BatteryBypassEngine(config: config, controller: mock)

        let diag = BatteryDiagnostics(
            cycleCount: 402,
            maxCapacityPercent: 85,
            currentCapacityPercent: 80,
            isExternalConnected: false,
            isCharging: false
        )

        let result = engine.evaluate(diagnostics: diag)
        XCTAssertEqual(result, false)
        XCTAssertFalse(mock.isChargingInhibited())
    }

    func testLiveDiagnosticsReadCompletesSafely() {
        let diag = BatteryBypassEngine.readLiveDiagnostics()
        XCTAssertGreaterThanOrEqual(diag.cycleCount, 0)
        XCTAssertGreaterThanOrEqual(diag.maxCapacityPercent, 0)
        XCTAssertGreaterThanOrEqual(diag.currentCapacityPercent, 0)
    }
}
