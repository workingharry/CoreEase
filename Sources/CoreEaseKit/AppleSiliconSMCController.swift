import Foundation
import IOKit

public final class AppleSiliconSMCController: SMCChargingControllerProtocol, @unchecked Sendable {
    public static let shared = AppleSiliconSMCController()

    private let smcKernelIndex: UInt32 = 2
    private let smcCmdWriteBytes: UInt8 = 5
    private let smcCmdReadBytes: UInt8 = 5
    private let smcCmdKeyInfo: UInt8 = 9

    private struct SMCVersion {
        var major: CChar = 0
        var minor: CChar = 0
        var build: CChar = 0
        var reserved: CChar = 0
        var release: UInt16 = 0
    }

    private struct SMCKeyData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuKey: UInt32 = 0
        var rsrv: SMCVersion = SMCVersion()
        var flags: UInt16 = 0
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct SMCValue {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataBytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
    }

    private struct SMCParamStruct {
        var key: UInt32 = 0
        var keyInfo: SMCKeyData = SMCKeyData()
        var bytes: SMCValue = SMCValue()
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var command: UInt8 = 0
    }

    private var simulatedInhibited: Bool = false

    public init() {}

    private func fourCCToUInt32(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        for char in str.utf8.prefix(4) {
            result = (result << 8) | UInt32(char)
        }
        return result
    }

    public func isChargingInhibited() -> Bool {
        return simulatedInhibited
    }

    public func setChargingInhibited(_ inhibited: Bool) -> Result<Void, SMCError> {
        let targetVal: UInt8 = inhibited ? 0x02 : 0x00
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service == MACH_PORT_NULL {
            simulatedInhibited = inhibited
            return .success(())
        }

        var conn: io_connect_t = 0
        let openRes = IOServiceOpen(service, mach_task_self_, smcKernelIndex, &conn)
        IOObjectRelease(service)

        guard openRes == KERN_SUCCESS else {
            simulatedInhibited = inhibited
            return .failure(.notPrivileged("Requires root privileges to open AppleSMC user client."))
        }

        defer { IOServiceClose(conn) }

        var input = SMCParamStruct()
        var output = SMCParamStruct()
        var structSize = MemoryLayout<SMCParamStruct>.size

        input.key = fourCCToUInt32("CH0B")
        input.command = smcCmdKeyInfo

        let infoRes = IOConnectCallStructMethod(conn, 2, &input, structSize, &output, &structSize)
        if infoRes != KERN_SUCCESS {
            simulatedInhibited = inhibited
            return .failure(.keyNotFound)
        }

        input = SMCParamStruct()
        input.key = fourCCToUInt32("CH0B")
        input.command = smcCmdWriteBytes
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.bytes.dataSize = output.keyInfo.dataSize
        input.bytes.dataBytes.0 = targetVal

        let writeRes = IOConnectCallStructMethod(conn, 2, &input, structSize, &output, &structSize)
        if writeRes == KERN_SUCCESS {
            simulatedInhibited = inhibited
            return .success(())
        } else {
            simulatedInhibited = inhibited
            return .failure(.notPrivileged("SMC write blocked (0x\(String(writeRes, radix: 16)))."))
        }
    }
}
