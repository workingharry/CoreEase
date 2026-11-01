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
        enabled: Bool = false,
        targetLimitPercent: Int = 80,
        autoResumeChargeBelow: Int = 75
    ) {
        self.enabled = enabled
        self.targetLimitPercent = targetLimitPercent
        self.autoResumeChargeBelow = autoResumeChargeBelow
    }
}

public enum SMCError: Error, Equatable {
    case notPrivileged(String)
    case deviceNotFound
    case keyNotFound
}

public protocol SMCChargingControllerProtocol: AnyObject, Sendable {
    func isChargingInhibited() -> Bool
    func setChargingInhibited(_ inhibited: Bool) -> Result<Void, SMCError>
}

public final class MockSMCChargingController: SMCChargingControllerProtocol, @unchecked Sendable {
    public var inhibited: Bool = false

    public init(inhibited: Bool = false) {
        self.inhibited = inhibited
    }

    public func isChargingInhibited() -> Bool {
        return inhibited
    }

    public func setChargingInhibited(_ inhibited: Bool) -> Result<Void, SMCError> {
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

    public func evaluate(diagnostics: BatteryDiagnostics) -> Bool? {
        guard config.enabled else {
            if controller.isChargingInhibited() {
                _ = controller.setChargingInhibited(false)
                return false
            }
            return nil
        }

        guard diagnostics.isExternalConnected else {
            if controller.isChargingInhibited() {
                _ = controller.setChargingInhibited(false)
                return false
            }
            return nil
        }

        if diagnostics.currentCapacityPercent >= config.targetLimitPercent {
            if !controller.isChargingInhibited() {
                _ = controller.setChargingInhibited(true)
                return true
            }
        } else if diagnostics.currentCapacityPercent <= config.autoResumeChargeBelow {
            if controller.isChargingInhibited() {
                _ = controller.setChargingInhibited(false)
                return false
            }
        }

        return controller.isChargingInhibited()
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
