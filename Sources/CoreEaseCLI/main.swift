import Foundation
import CoreEaseKit

@main
struct CoreEaseCLI {
    static func printUsage() {
        print("""
        CoreEase CLI - macOS CPU Limiter & Core Scheduler
        Usage:
          coreease-cli list                      List top CPU-consuming apps
          coreease-cli eco <pid>                 Clamp process to Efficiency Cores (E-Cores)
          coreease-cli turbo <pid>               Restore process to default cores (P-Cores allowed)
          coreease-cli limit <pid> <percent>     Throttle process to maximum CPU percentage (e.g. 25)
          coreease-cli unlimit <pid>             Remove throttle limit on process
          coreease-cli bypass [status|on|off|install-helper]
                                                 Direct AC power bypass & battery cycle saver
        """)
    }

    static func main() {
        let args = CommandLine.arguments

        guard args.count > 1 else {
            printUsage()
            return
        }

        let command = args[1].lowercased()

        switch command {
        case "list":
            let list = ProcessMonitor.shared.getTopProcesses(limit: 15)
            print(" PID    | CPU %  | PROCESS NAME")
            print("---------------------------------")
            for proc in list {
                let pidStr = String(format: "%-6d", proc.pid)
                let cpuStr = String(format: "%5.1f%%", proc.cpuUsage)
                print(" \(pidStr) | \(cpuStr) | \(proc.name)")
            }

        case "eco":
            guard args.count > 2, let pid = Int32(args[2]) else {
                print("Error: Missing or invalid PID.")
                return
            }
            let success = CoreScheduler.shared.clampToEfficiencyCores(pid: pid)
            if success {
                print("🌿 Success: PID \(pid) is now clamped to Apple Silicon Efficiency Cores (E-Cores).")
            } else {
                print("❌ Failed to clamp PID \(pid). Ensure you have permission or the PID exists.")
            }

        case "turbo":
            guard args.count > 2, let pid = Int32(args[2]) else {
                print("Error: Missing or invalid PID.")
                return
            }
            let success = CoreScheduler.shared.resetToDefaultCores(pid: pid)
            if success {
                print("⚡ Success: PID \(pid) reset to Default scheduling (P-Cores allowed).")
            } else {
                print("❌ Failed to reset PID \(pid).")
            }

        case "limit":
            guard args.count > 3, let pid = Int32(args[2]), let percent = Int(args[3]) else {
                print("Error: Usage: coreease-cli limit <pid> <percent>")
                return
            }
            CPUThrottler.shared.setLimit(pid: pid, percent: percent)
            print("⏳ Throttling PID \(pid) to max \(percent)% CPU. Press Ctrl+C to stop.")
            RunLoop.main.run()

        case "unlimit":
            guard args.count > 2, let pid = Int32(args[2]) else {
                print("Error: Missing or invalid PID.")
                return
            }
            CPUThrottler.shared.stopThrottling(pid: pid)
            print("✅ Removed throttling from PID \(pid).")

        case "bypass":
            let sub = args.count > 2 ? args[2].lowercased() : "status"
            switch sub {
            case "status":
                let diag = BatteryBypassEngine.readLiveDiagnostics()
                let helperInstalled = AppleSiliconSMCController.shared.isHelperInstalled()
                print("⚡ CoreEase Power Bypass Status:")
                print("  • AC Adapter Connected: \(diag.isExternalConnected ? "YES" : "NO")")
                print("  • Battery Level:        \(diag.currentCapacityPercent)%")
                print("  • Battery Health:       \(diag.maxCapacityPercent)%")
                print("  • Cycle Count:          \(diag.cycleCount)")
                print("  • Direct AC Bypass:     \(diag.isExternalConnected && (diag.isBypassActive || diag.currentCapacityPercent >= 80) ? "ACTIVE (0 Cycles Used)" : "INACTIVE")")
                print("  • SMC Root Helper:      \(helperInstalled ? "INSTALLED (/usr/local/bin/coreease-helper)" : "NOT INSTALLED")")
            case "on":
                let res = AppleSiliconSMCController.shared.setChargingInhibited(true)
                switch res {
                case .success:
                    print("✅ Charging inhibited: MacBook running on direct external AC power.")
                case .failure(let err):
                    print("❌ Failed to inhibit charging: \(err.localizedDescription)")
                    if !AppleSiliconSMCController.shared.isHelperInstalled() {
                        print("💡 Tip: Run 'coreease-cli bypass install-helper' to configure root privileges.")
                    }
                }
            case "off":
                let res = AppleSiliconSMCController.shared.setChargingInhibited(false)
                switch res {
                case .success:
                    print("✅ Normal charging restored.")
                case .failure(let err):
                    print("❌ Failed to restore charging: \(err.localizedDescription)")
                }
            case "install-helper":
                let script = AppleSiliconSMCController.shared.generateHelperInstallScript()
                let tempPath = "/tmp/install_coreease_helper.sh"
                try? script.write(toFile: tempPath, atomically: true, encoding: .utf8)
                print("🔒 Running installer with administrator privileges...")
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", "do shell script \"bash \(tempPath)\" with administrator privileges"]
                try? proc.run()
                proc.waitUntilExit()
                if AppleSiliconSMCController.shared.isHelperInstalled() {
                    print("✅ CoreEase SMC Helper installed successfully.")
                } else {
                    print("❌ Helper installation failed or cancelled.")
                }
            default:
                print("Usage: coreease-cli bypass [status|on|off|install-helper]")
            }

        default:
            printUsage()
        }
    }
}
