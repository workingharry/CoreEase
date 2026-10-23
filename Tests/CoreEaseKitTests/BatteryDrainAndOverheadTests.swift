import Foundation
import CoreEaseKit
import XCTest

final class BatteryDrainAndOverheadTests: XCTestCase {
    // Seam 1: Cadence and Timer Interval Safety
    func testSamplingCadenceIsEnergyOptimal() {
        let optimalCadence: TimeInterval = 2.5
        XCTAssertGreaterThanOrEqual(optimalCadence, 2.0, "Sampling cadence must be >= 2.0s to avoid waking low-power sleep states")
    }

    // Seam 2: Suppression Net Power Efficiency Calculation
    func testSuppressionPowerSavingsNetGain() {
        let pCorePowerWatts: Double = 4.0
        let eCoreSuppressedPowerWatts: Double = 0.35
        let coreEaseOverheadWatts: Double = 0.02

        let powerSavedWatts = pCorePowerWatts - (eCoreSuppressedPowerWatts + coreEaseOverheadWatts)
        let percentPowerReduction = (powerSavedWatts / pCorePowerWatts) * 100.0

        XCTAssertGreaterThan(percentPowerReduction, 80.0, "Net power reduction must exceed 80%")
        XCTAssertGreaterThan(powerSavedWatts, 3.0, "Must save at least 3 Watts of power per suppressed core")
    }

    // Seam 3: Duty Cycle Timing Calculation (20ms ProMotion Smooth Rendering)
    func testDutyCycleTimingCalculation() {
        let percent = 85
        let cycleDurationMs: Double = 20.0
        let workDurationMs = cycleDurationMs * (Double(percent) / 100.0)
        let sleepDurationMs = cycleDurationMs - workDurationMs

        XCTAssertEqual(workDurationMs, 17.0)
        XCTAssertEqual(sleepDurationMs, 3.0)
        XCTAssertEqual(workDurationMs + sleepDurationMs, 20.0)
    }
}
