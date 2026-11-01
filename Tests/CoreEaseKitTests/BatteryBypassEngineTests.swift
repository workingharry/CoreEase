import XCTest
@testable import CoreEaseKit

final class BatteryBypassEngineTests: XCTestCase {
    func testBypassPausesChargingWhenAtOrAboveTarget() {
        let mockSMC = MockSMCChargingController(inhibited: false)
        let config = PowerBypassConfig(enabled: true, targetLimitPercent: 80, autoResumeChargeBelow: 75)
        let engine = BatteryBypassEngine(config: config, controller: mockSMC)

        let diag = BatteryDiagnostics(
            currentCapacityPercent: 82,
            isExternalConnected: true,
            isCharging: true
        )

        let result = engine.evaluateWithResult(diagnostics: diag)
        XCTAssertEqual(result, .success(true))
        XCTAssertTrue(mockSMC.isChargingInhibited())
    }

    func testBypassResumesChargingWhenAtOrBelowAutoResumeThreshold() {
        let mockSMC = MockSMCChargingController(inhibited: true)
        let config = PowerBypassConfig(enabled: true, targetLimitPercent: 80, autoResumeChargeBelow: 75)
        let engine = BatteryBypassEngine(config: config, controller: mockSMC)

        let diag = BatteryDiagnostics(
            currentCapacityPercent: 74,
            isExternalConnected: true,
            isCharging: false
        )

        let result = engine.evaluateWithResult(diagnostics: diag)
        XCTAssertEqual(result, .success(false))
        XCTAssertFalse(mockSMC.isChargingInhibited())
    }

    func testBypassPropagatesNotPrivilegedErrorWhenPauseFails() {
        let expectedError = SMCError.notPrivileged("Requires root privileges to open AppleSMC user client.")
        let mockSMC = MockSMCChargingController(inhibited: false, simulatedError: expectedError)
        let config = PowerBypassConfig(enabled: true, targetLimitPercent: 80, autoResumeChargeBelow: 75)
        let engine = BatteryBypassEngine(config: config, controller: mockSMC)

        let diag = BatteryDiagnostics(
            currentCapacityPercent: 85,
            isExternalConnected: true,
            isCharging: true
        )

        let result = engine.evaluateWithResult(diagnostics: diag)
        XCTAssertEqual(result, .failure(expectedError))
        XCTAssertFalse(mockSMC.isChargingInhibited())
        XCTAssertTrue(expectedError.errorDescription?.contains("⚠️ Direct AC requires root privileges") == true)
    }

    func testBypassPropagatesErrorWhenDisablingInhibitionFails() {
        let expectedError = SMCError.notPrivileged("SMC write blocked (0xe00002c1).")
        let mockSMC = MockSMCChargingController(inhibited: true, simulatedError: expectedError)
        let config = PowerBypassConfig(enabled: false, targetLimitPercent: 80, autoResumeChargeBelow: 75)
        let engine = BatteryBypassEngine(config: config, controller: mockSMC)

        let diag = BatteryDiagnostics(
            currentCapacityPercent: 80,
            isExternalConnected: true,
            isCharging: false
        )

        let result = engine.evaluateWithResult(diagnostics: diag)
        XCTAssertEqual(result, .failure(expectedError))
        XCTAssertTrue(mockSMC.isChargingInhibited())
    }

    func testBypassReturnsNilOnBatteryPowerWhenNotInhibited() {
        let mockSMC = MockSMCChargingController(inhibited: false)
        let config = PowerBypassConfig(enabled: true, targetLimitPercent: 80, autoResumeChargeBelow: 75)
        let engine = BatteryBypassEngine(config: config, controller: mockSMC)

        let diag = BatteryDiagnostics(
            currentCapacityPercent: 90,
            isExternalConnected: false,
            isCharging: false
        )

        let result = engine.evaluateWithResult(diagnostics: diag)
        XCTAssertEqual(result, .success(nil))
        XCTAssertFalse(mockSMC.isChargingInhibited())
    }

    func testSMCErrorDescriptions() {
        let privErr = SMCError.notPrivileged("test reason")
        XCTAssertEqual(privErr.errorDescription, "⚠️ Direct AC requires root privileges (test reason)")

        let devErr = SMCError.deviceNotFound
        XCTAssertEqual(devErr.errorDescription, "⚠️ Direct AC unavailable: AppleSMC device not found")

        let keyErr = SMCError.keyNotFound
        XCTAssertEqual(keyErr.errorDescription, "⚠️ Direct AC unsupported: SMC key CH0B not found")
    }
}
