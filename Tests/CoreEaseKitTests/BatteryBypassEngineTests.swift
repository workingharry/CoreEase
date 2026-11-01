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

        let mode = engine.evaluateMode(diagnostics: diag)
        XCTAssertEqual(mode, .hardwareInhibited(target: 80))
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

        let mode = engine.evaluateMode(diagnostics: diag)
        XCTAssertEqual(mode, .hardwareResume(floor: 75))
        XCTAssertFalse(mockSMC.isChargingInhibited())
    }

    func testBypassGracefullyFallsBackToNativePassthroughWhenSMCBlocked() {
        let expectedError = SMCError.keyNotFound
        let mockSMC = MockSMCChargingController(inhibited: false, simulatedError: expectedError)
        let config = PowerBypassConfig(enabled: true, targetLimitPercent: 80, autoResumeChargeBelow: 75)
        let engine = BatteryBypassEngine(config: config, controller: mockSMC)

        let diagNotCharging = BatteryDiagnostics(
            currentCapacityPercent: 85,
            isExternalConnected: true,
            isCharging: false
        )

        let mode = engine.evaluateMode(diagnostics: diagNotCharging)
        XCTAssertEqual(mode, .nativePassthroughActive)

        let diagCharging = BatteryDiagnostics(
            currentCapacityPercent: 78,
            isExternalConnected: true,
            isCharging: true
        )
        let modeCharging = engine.evaluateMode(diagnostics: diagCharging)
        XCTAssertEqual(modeCharging, .nativePassthroughCharging(target: 80))
    }

    func testBypassReturnsBatteryPowerWhenDisconnected() {
        let mockSMC = MockSMCChargingController(inhibited: false)
        let config = PowerBypassConfig(enabled: true, targetLimitPercent: 80, autoResumeChargeBelow: 75)
        let engine = BatteryBypassEngine(config: config, controller: mockSMC)

        let diag = BatteryDiagnostics(
            currentCapacityPercent: 90,
            isExternalConnected: false,
            isCharging: false
        )

        let mode = engine.evaluateMode(diagnostics: diag)
        XCTAssertEqual(mode, .batteryPower)
    }

    func testSMCErrorDescriptions() {
        let privErr = SMCError.notPrivileged("test")
        XCTAssertEqual(privErr.errorDescription, "Requires root privileges (test)")

        let devErr = SMCError.deviceNotFound
        XCTAssertEqual(devErr.errorDescription, "AppleSMC device not found")

        let keyErr = SMCError.keyNotFound
        XCTAssertEqual(keyErr.errorDescription, "SMC key CH0B not found")
    }
}
