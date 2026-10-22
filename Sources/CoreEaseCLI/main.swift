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

        default:
            printUsage()
        }
    }
}
