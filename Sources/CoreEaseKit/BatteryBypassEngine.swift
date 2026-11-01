import Foundation
import IOKit

public struct BatteryDiagnostics: Sendable, Equatable {
    public let cycleCount: Int
    public let maxCapacityPercent: Int
    public let currentCapacityPercent: Int
    public let isExternalConnected: Bool
    public let isCharging: Bool
    public let isFullyCharged: Bool
    public let chargerWatts: Int
    public let isBypassActive: Bool

    public init(
        cycleCount: Int = 0,
        maxCapacityPercent: Int = 100,
        currentCapacityPercent: Int = 100,
        isExternalConnected: Bool = false,
        isCharging: Bool = false,
        isFullyCharged: Bool = false,
        chargerWatts: Int = 0,
        isBypassActive: Bool = false
    ) {
        self.cycleCount = cycleCount
        self.maxCapacityPercent = maxCapacityPercent
        self.currentCapacityPercent = currentCapacityPercent
        self.isExternalConnected = isExternalConnected
        self.isCharging = isCharging
        self.isFullyCharged = isFullyCharged
        self.chargerWatts = chargerWatts
        self.isBypassActive = isBypassActive
    }
}

public struct PowerBypassConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var targetLimitPercent: Int
    public var autoResumeChargeBelow: Int

    public init(
        enabled: Bool = true,
        targetLimitPercent: Int = 80,
        autoResumeChargeBelow: Int = 75
    ) {
        self.enabled = enabled
        self.targetLimitPercent = targetLimitPercent
        self.autoResumeChargeBelow = autoResumeChargeBelow
    }
}

public enum SMCError: Error, Equatable, LocalizedError, Sendable {
    case notPrivileged(String)
    case deviceNotFound
    case keyNotFound

    public var errorDescription: String? {
        switch self {
        case .notPrivileged(let detail):
            return "Requires root privileges (\(detail))"
        case .deviceNotFound:
            return "AppleSMC device not found"
        case .keyNotFound:
            return "SMC key CH0B not found"
        }
    }
}

public enum DirectPowerMode: Sendable, Equatable {
    case hardwareInhibited(target: Int)
    case hardwareResume(floor: Int)
    case nativePassthroughActive
    case nativePassthroughCharging(target: Int)
    case batteryPower
    case disabled
}

public protocol SMCChargingControllerProtocol: AnyObject, Sendable {
    func isChargingInhibited() -> Bool
    func setChargingInhibited(_ inhibited: Bool) -> Result<Void, SMCError>
}

public final class MockSMCChargingController: SMCChargingControllerProtocol, @unchecked Sendable {
    public var inhibited: Bool = false
    public var simulatedError: SMCError?

    public init(inhibited: Bool = false, simulatedError: SMCError? = nil) {
        self.inhibited = inhibited
        self.simulatedError = simulatedError
    }

    public func isChargingInhibited() -> Bool {
        return inhibited
    }

    public func setChargingInhibited(_ inhibited: Bool) -> Result<Void, SMCError> {
        if let error = simulatedError {
            return .failure(error)
        }
        self.inhibited = inhibited
        return .success(())
    }
}

public final class BatteryBypassEngine: @unchecked Sendable {
    public var config: PowerBypassConfig
    public var controller: SMCChargingControllerProtocol

    public init(
        config: PowerBypassConfig = PowerBypassConfig(),
        controller: SMCChargingControllerProtocol = MockSMCChargingController()
    ) {
        self.config = config
        self.controller = controller
    }

    public func evaluateMode(diagnostics: BatteryDiagnostics) -> DirectPowerMode {
        guard config.enabled else {
            if controller.isChargingInhibited() {
                _ = controller.setChargingInhibited(false)
            }
            return .disabled
        }

        guard diagnostics.isExternalConnected else {
            if controller.isChargingInhibited() {
                _ = controller.setChargingInhibited(false)
            }
            return .batteryPower
        }

        if diagnostics.currentCapacityPercent >= config.targetLimitPercent {
            let res = controller.setChargingInhibited(true)
            switch res {
            case .success:
                return .hardwareInhibited(target: config.targetLimitPercent)
            case .failure:
                return diagnostics.isCharging
                    ? .nativePassthroughCharging(target: config.targetLimitPercent)
                    : .nativePassthroughActive
            }
        } else if diagnostics.currentCapacityPercent <= config.autoResumeChargeBelow {
            let res = controller.setChargingInhibited(false)
            switch res {
            case .success:
                return .hardwareResume(floor: config.autoResumeChargeBelow)
            case .failure:
                return diagnostics.isCharging
                    ? .nativePassthroughCharging(target: config.targetLimitPercent)
                    : .nativePassthroughActive
            }
        }

        if controller.isChargingInhibited() {
            return .hardwareInhibited(target: config.targetLimitPercent)
        }

        return diagnostics.isCharging
            ? .nativePassthroughCharging(target: config.targetLimitPercent)
            : .nativePassthroughActive
    }

    public func evaluate(diagnostics: BatteryDiagnostics) -> Bool? {
        let mode = evaluateMode(diagnostics: diagnostics)
        switch mode {
        case .hardwareInhibited:
            return true
        case .hardwareResume:
            return false
        case .nativePassthroughActive:
            return true
        case .nativePassthroughCharging, .disabled:
            return nil
        case .batteryPower:
            return false
        }
    }

    public func evaluateWithResult(diagnostics: BatteryDiagnostics) -> Result<Bool?, SMCError> {
        let mode = evaluateMode(diagnostics: diagnostics)
        switch mode {
        case .hardwareInhibited:
            return .success(true)
        case .hardwareResume:
            return .success(false)
        case .nativePassthroughActive:
            return .success(true)
        case .nativePassthroughCharging, .batteryPower, .disabled:
            return .success(nil)
        }
    }

    public static func readLiveDiagnostics() -> BatteryDiagnostics {
        var cycleCount = 0
        var maxCap = 100
        var curCap = 100
        var extConn = false
        var charging = false
        var fullyCharged = false
        var watts = 0

        let matchDict = IOServiceMatching("AppleSmartBattery")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)

        if kr == KERN_SUCCESS {
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
                    
                    if let cc = dict["CycleCount"] as? Int { cycleCount = cc }
                    if let mc = dict["MaxCapacity"] as? Int { maxCap = mc }
                    if let cur = dict["CurrentCapacity"] as? Int { curCap = cur }
                    if let ext = dict["ExternalConnected"] as? Bool { extConn = ext }
                    if let chg = dict["IsCharging"] as? Bool { charging = chg }
                    if let fc = dict["FullyCharged"] as? Bool { fullyCharged = fc }

                    if let ad = dict["AdapterDetails"] as? [String: Any],
                       let w = ad["Watts"] as? Int {
                        watts = w
                    }
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }

        let bypassActive = extConn && !charging
        return BatteryDiagnostics(
            cycleCount: cycleCount,
            maxCapacityPercent: maxCap,
            currentCapacityPercent: curCap,
            isExternalConnected: extConn,
            isCharging: charging,
            isFullyCharged: fullyCharged,
            chargerWatts: watts,
            isBypassActive: bypassActive
        )
    }
}
