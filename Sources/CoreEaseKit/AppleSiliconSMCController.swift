import Foundation
import IOKit

public struct SMCKeySpec: Sendable, Equatable {
    public let key: String
    public let disableBytes: [UInt8]
    public let enableBytes: [UInt8]

    public init(key: String, disableBytes: [UInt8], enableBytes: [UInt8]) {
        self.key = key
        self.disableBytes = disableBytes
        self.enableBytes = enableBytes
    }
}

public final class AppleSiliconSMCController: SMCChargingControllerProtocol, @unchecked Sendable {
    public static let shared = AppleSiliconSMCController()

    public static let fallbackStrategies: [[SMCKeySpec]] = [
        [
            SMCKeySpec(key: "CHTE", disableBytes: [0x01, 0x00, 0x00, 0x00], enableBytes: [0x00, 0x00, 0x00, 0x00])
        ],
        [
            SMCKeySpec(key: "CH0B", disableBytes: [0x02], enableBytes: [0x00]),
            SMCKeySpec(key: "CH0C", disableBytes: [0x02], enableBytes: [0x00])
        ]
    ]

    public static let helperBinaryPath = "/usr/local/bin/coreease-helper"
    public static let externalBatteryPath = "/usr/local/bin/battery"

    private let smcKernelIndex: UInt32 = 2
    private let smcCmdWriteBytes: UInt8 = 5
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

    public func isHelperInstalled() -> Bool {
        return FileManager.default.isExecutableFile(atPath: Self.helperBinaryPath) ||
               FileManager.default.isExecutableFile(atPath: Self.externalBatteryPath)
    }

    public func generateHelperInstallScript() -> String {
        return """
        #!/bin/bash
        set -e
        echo "Installing CoreEase Privileged SMC Helper..."
        cat << 'EOF' > /tmp/coreease-helper.sh
        #!/bin/bash
        ACTION=$1
        if [ "$ACTION" = "off" ]; then
            which battery >/dev/null 2>&1 && battery charging off && exit 0
            which smc >/dev/null 2>&1 && (smc -k CHTE -w 01000000 || (smc -k CH0B -w 02 && smc -k CH0C -w 02)) && exit 0
        elif [ "$ACTION" = "on" ]; then
            which battery >/dev/null 2>&1 && battery charging on && exit 0
            which smc >/dev/null 2>&1 && (smc -k CHTE -w 00000000 || (smc -k CH0B -w 00 && smc -k CH0C -w 00)) && exit 0
        fi
        exit 1
        EOF
        sudo mkdir -p /usr/local/bin
        sudo mv /tmp/coreease-helper.sh /usr/local/bin/coreease-helper
        sudo chmod 755 /usr/local/bin/coreease-helper
        sudo chown root:wheel /usr/local/bin/coreease-helper
        sudo mkdir -p /private/etc/sudoers.d
        echo "%admin ALL=(ALL) NOPASSWD: /usr/local/bin/coreease-helper" | sudo tee /private/etc/sudoers.d/coreease-helper > /dev/null
        sudo chmod 440 /private/etc/sudoers.d/coreease-helper
        echo "✅ CoreEase Helper installed successfully!"
        """
    }

    public func setChargingInhibited(_ inhibited: Bool) -> Result<Void, SMCError> {
        if isHelperInstalled() {
            let action = inhibited ? "off" : "on"
            let targetHelper = FileManager.default.isExecutableFile(atPath: Self.helperBinaryPath)
                ? Self.helperBinaryPath
                : Self.externalBatteryPath
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            task.arguments = ["-n", targetHelper, action]
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    simulatedInhibited = inhibited
                    return .success(())
                }
            } catch {}
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service == MACH_PORT_NULL {
            simulatedInhibited = inhibited
            return .success(())
        }

        var conn: io_connect_t = 0
        let openRes = IOServiceOpen(service, mach_task_self_, smcKernelIndex, &conn)
        IOObjectRelease(service)

        guard openRes == KERN_SUCCESS else {
            return .failure(.notPrivileged("Requires root privileges to open AppleSMC user client."))
        }

        defer { IOServiceClose(conn) }

        var lastError: SMCError = .keyNotFound

        for strategy in Self.fallbackStrategies {
            var strategySucceeded = true

            for spec in strategy {
                var input = SMCParamStruct()
                var output = SMCParamStruct()
                var structSize = MemoryLayout<SMCParamStruct>.size

                input.key = fourCCToUInt32(spec.key)
                input.command = smcCmdKeyInfo

                let infoRes = IOConnectCallStructMethod(conn, 2, &input, structSize, &output, &structSize)
                guard infoRes == KERN_SUCCESS else {
                    strategySucceeded = false
                    lastError = .keyNotFound
                    break
                }

                let payload = inhibited ? spec.disableBytes : spec.enableBytes
                input = SMCParamStruct()
                input.key = fourCCToUInt32(spec.key)
                input.command = smcCmdWriteBytes
                input.keyInfo.dataSize = output.keyInfo.dataSize
                input.bytes.dataSize = output.keyInfo.dataSize

                withUnsafeMutableBytes(of: &input.bytes.dataBytes) { rawPtr in
                    for (idx, b) in payload.prefix(rawPtr.count).enumerated() {
                        rawPtr[idx] = b
                    }
                }

                let writeRes = IOConnectCallStructMethod(conn, 2, &input, structSize, &output, &structSize)
                guard writeRes == KERN_SUCCESS else {
                    strategySucceeded = false
                    lastError = .notPrivileged("SMC write blocked (0x\(String(writeRes, radix: 16))).")
                    break
                }
            }

            if strategySucceeded {
                simulatedInhibited = inhibited
                return .success(())
            }
        }

        return .failure(lastError)
    }
}
