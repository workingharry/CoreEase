import SwiftUI
import CoreEaseKit
import Combine

@main
struct CoreEaseApp: App {
    @StateObject private var model = ProcessViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("CoreEase", systemImage: model.isAutoSuppressionActive ? "leaf.arrow.triangle.circlepath" : "cpu") {
            ContentView(model: model)
                .frame(width: 490, height: 580)
        }
        .menuBarExtraStyle(.window)

        Window("CoreEase Dashboard", id: "main-dashboard") {
            LaunchWindowView(model: model)
                .frame(minWidth: 640, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep running in menu bar
    }
}

public enum ProcessSortMode: String, CaseIterable, Identifiable {
    case name = "Name (Fixed)"
    case cpu = "Top CPU"
    case pid = "PID"

    public var id: String { self.rawValue }
}

@MainActor
final class ProcessViewModel: ObservableObject {
    @Published var processes: [TrackedProcess] = []
    @Published var searchText: String = ""
    @Published var autoRefresh: Bool = true
    @Published var showSystemServices: Bool = false
    @Published var sortMode: ProcessSortMode = .name

    // Battery & Auto-Suppression Configuration
    @Published var autoSuppressConfig = AutoSuppressConfig()
    @Published var isOnBattery: Bool = false
    @Published var autoSuppressedPIDs: Set<Int32> = []

    private var timer: AnyCancellable?
    private let policyStore = ThrottlePolicyStore.shared
    private var suppressionEngine = AutoSuppressionEngine()

    var isAutoSuppressionActive: Bool {
        return autoSuppressConfig.enabled && !autoSuppressedPIDs.isEmpty
    }

    init() {
        self.isOnBattery = PowerSourceMonitor.isOnBattery()
        self.suppressionEngine = AutoSuppressionEngine(config: autoSuppressConfig)

        refresh()

        // 2.5s Adaptive cadence for battery conservation
        timer = Timer.publish(every: 2.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                if self?.autoRefresh == true {
                    self?.refresh()
                }
            }

        // Frontmost active application change notification
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self else { return }
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                Task { @MainActor in
                    let restored = self.suppressionEngine.updateFrontmostApp(pid: app.processIdentifier)
                    for action in restored {
                        self.executeRestore(pid: action.pid)
                    }
                    self.autoSuppressedPIDs = Set(self.processes.filter { self.suppressionEngine.isAutoSuppressed(pid: $0.pid) }.map { $0.pid })
                }
            }
        }

        // Display sleep / wake observation
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.autoRefresh = false
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.autoRefresh = true
                self?.refresh()
            }
        }
    }

    func updateAutoSuppressConfig(_ newConfig: AutoSuppressConfig) {
        self.autoSuppressConfig = newConfig
        self.suppressionEngine.config = newConfig
        if !newConfig.enabled {
            let restored = suppressionEngine.restoreAll()
            for action in restored {
                executeRestore(pid: action.pid)
            }
            autoSuppressedPIDs.removeAll()
        }
    }

    func refresh() {
        self.isOnBattery = PowerSourceMonitor.isOnBattery()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        _ = suppressionEngine.updateFrontmostApp(pid: frontPID)

        let fetched = ProcessMonitor.shared.getTopProcesses(limit: 50)
        let savedPolicies = policyStore.getAllPolicies()

        var currentMap: [Int32: TrackedProcess] = [:]
        for p in processes {
            currentMap[p.pid] = p
        }

        var merged: [TrackedProcess] = []
        for newP in fetched {
            var proc = newP

            // Check persistent user manual policies
            if let policy = savedPolicies[proc.name] {
                proc.isEfficiencyClamped = policy.isEco
                proc.throttleLimitPercent = policy.throttleLimitPercent

                if let limit = policy.throttleLimitPercent, !CPUThrottler.shared.isThrottling(pid: proc.pid) {
                    CPUThrottler.shared.setLimit(pid: proc.pid, percent: limit)
                }
                if policy.isEco {
                    CoreScheduler.shared.clampToEfficiencyCores(pid: proc.pid)
                }
            } else if let existing = currentMap[proc.pid] {
                proc.isEfficiencyClamped = existing.isEfficiencyClamped
                proc.throttleLimitPercent = existing.throttleLimitPercent
            }

            merged.append(proc)
        }

        // Evaluate automated high-load suppression
        if autoSuppressConfig.enabled {
            let actions = suppressionEngine.evaluate(processes: merged, isOnBattery: self.isOnBattery)
            for action in actions {
                if action.action == .suppress {
                    executeSuppression(pid: action.pid)
                } else {
                    executeRestore(pid: action.pid)
                }
            }
            self.autoSuppressedPIDs = Set(merged.filter { suppressionEngine.isAutoSuppressed(pid: $0.pid) }.map { $0.pid })
        } else {
            self.autoSuppressedPIDs.removeAll()
        }

        switch sortMode {
        case .name:
            self.processes = merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid:
            self.processes = merged.sorted { $0.pid < $1.pid }
        case .cpu:
            self.processes = merged.sorted { $0.cpuUsage > $1.cpuUsage }
        }
    }

    private func executeSuppression(pid: Int32) {
        if autoSuppressConfig.autoEcoClamp {
            CoreScheduler.shared.clampToEfficiencyCores(pid: pid)
        }
        CPUThrottler.shared.setLimit(pid: pid, percent: autoSuppressConfig.autoThrottleLimit)
    }

    private func executeRestore(pid: Int32) {
        // If user has no manual policy, restore process to full default speed
        if let proc = processes.first(where: { $0.pid == pid }) {
            if policyStore.getPolicy(for: proc.name) == nil {
                CPUThrottler.shared.stopThrottling(pid: pid)
                CoreScheduler.shared.resetToDefaultCores(pid: pid)
            }
        } else {
            CPUThrottler.shared.stopThrottling(pid: pid)
            CoreScheduler.shared.resetToDefaultCores(pid: pid)
        }
    }

    var filteredProcesses: [TrackedProcess] {
        return processes.filter { proc in
            if !showSystemServices && proc.safetyTier != .safeApp {
                return false
            }
            if searchText.isEmpty {
                return true
            }
            return proc.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    func clampToEco(pid: Int32, appName: String) {
        _ = CoreScheduler.shared.clampToEfficiencyCores(pid: pid)
        if let idx = processes.firstIndex(where: { $0.pid == pid }) {
            processes[idx].isEfficiencyClamped = true
        }
        var policy = policyStore.getPolicy(for: appName) ?? AppThrottlePolicy(appName: appName)
        policy.isEco = true
        policyStore.setPolicy(policy)
    }

    func resetToTurbo(pid: Int32, appName: String) {
        _ = CoreScheduler.shared.resetToDefaultCores(pid: pid)
        if let idx = processes.firstIndex(where: { $0.pid == pid }) {
            processes[idx].isEfficiencyClamped = false
        }
        if var policy = policyStore.getPolicy(for: appName) {
            policy.isEco = false
            if policy.throttleLimitPercent == nil {
                policyStore.removePolicy(for: appName)
            } else {
                policyStore.setPolicy(policy)
            }
        }
    }

    func setLimit(pid: Int32, appName: String, percent: Int) {
        CPUThrottler.shared.setLimit(pid: pid, percent: percent)
        if let idx = processes.firstIndex(where: { $0.pid == pid }) {
            processes[idx].throttleLimitPercent = percent
        }
        var policy = policyStore.getPolicy(for: appName) ?? AppThrottlePolicy(appName: appName)
        policy.throttleLimitPercent = percent
        policyStore.setPolicy(policy)
    }

    func removeLimit(pid: Int32, appName: String) {
        CPUThrottler.shared.stopThrottling(pid: pid)
        if let idx = processes.firstIndex(where: { $0.pid == pid }) {
            processes[idx].throttleLimitPercent = nil
        }
        if var policy = policyStore.getPolicy(for: appName) {
            policy.throttleLimitPercent = nil
            if !policy.isEco {
                policyStore.removePolicy(for: appName)
            } else {
                policyStore.setPolicy(policy)
            }
        }
    }

    func quitApplication() {
        CPUThrottler.shared.stopAll()
        NSApplication.shared.terminate(nil)
    }
}

/// Standalone Full Launch Window View
struct LaunchWindowView: View {
    @ObservedObject var model: ProcessViewModel

    var body: some View {
        VStack(spacing: 0) {
            AppBrandHeader(model: model, isMainWindow: true)
            Divider()
            ContentView(model: model)
        }
        .frame(minWidth: 620, minHeight: 620)
    }
}

/// Distinctive Brand Header with typography & palette
struct AppBrandHeader: View {
    @ObservedObject var model: ProcessViewModel
    var isMainWindow: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.38, blue: 0.34), Color(red: 0.08, green: 0.22, blue: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )

                Image(systemName: model.isAutoSuppressionActive ? "leaf.arrow.triangle.circlepath" : "cpu.fill")
                    .foregroundColor(Color(red: 0.35, green: 0.90, blue: 0.72))
                    .font(.system(size: 18, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("CoreEase")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)

                    Text("Apple Silicon Edition")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())

                    if model.isOnBattery {
                        HStack(spacing: 3) {
                            Image(systemName: "battery.75")
                            Text("Battery Mode")
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }

                Text("Intelligent Core Scheduling & Dynamic CPU Throttling")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { model.quitApplication() }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                    Text("Quit CoreEase")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Terminate CoreEase and restore full system clocks")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct ContentView: View {
    @ObservedObject var model: ProcessViewModel
    @State private var showSettings: Bool = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            AppBrandHeader(model: model, isMainWindow: false)

            // Auto-Suppression Intelligent Banner
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: model.autoSuppressConfig.enabled ? "bolt.shield.fill" : "bolt.shield")
                        .foregroundColor(model.autoSuppressConfig.enabled ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-Battery Saver (Auto-Suppress)")
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.autoSuppressConfig.enabled
                             ? (model.isOnBattery
                                ? "Active: Auto-throttling background tasks >\(Int(model.autoSuppressConfig.cpuThreshold))% CPU to save battery"
                                : "Armed: Will activate automatically when running on Battery")
                             : "Disabled: Manual control mode")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { model.autoSuppressConfig.enabled },
                    set: { val in
                        var cfg = model.autoSuppressConfig
                        cfg.enabled = val
                        model.updateAutoSuppressConfig(cfg)
                    }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))

            // Toolbar Controls
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search running applications...", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(7)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(7)

                Button(action: { model.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(7)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(7)
                .help("Refresh task list")

                Button(action: {
                    openWindow(id: "main-dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(7)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(7)
                .help("Open in standalone Launch Dashboard window")

                Button(action: { showSettings.toggle() }) {
                    Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(7)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(7)
                .help("Settings & Automation Rules")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            // Expandable Settings Drawer
            if showSettings {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Auto-Suppression Rules")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)

                    HStack {
                        Toggle("Only on Battery Power", isOn: Binding(
                            get: { model.autoSuppressConfig.onlyOnBattery },
                            set: { val in
                                var cfg = model.autoSuppressConfig
                                cfg.onlyOnBattery = val
                                model.updateAutoSuppressConfig(cfg)
                            }
                        ))
                        .font(.caption)

                        Spacer()

                        Toggle("Pin to E-Cores (Eco)", isOn: Binding(
                            get: { model.autoSuppressConfig.autoEcoClamp },
                            set: { val in
                                var cfg = model.autoSuppressConfig
                                cfg.autoEcoClamp = val
                                model.updateAutoSuppressConfig(cfg)
                            }
                        ))
                        .font(.caption)
                    }

                    HStack {
                        Text("Trigger Threshold:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(
                            value: Binding(
                                get: { model.autoSuppressConfig.cpuThreshold },
                                set: { val in
                                    var cfg = model.autoSuppressConfig
                                    cfg.cpuThreshold = val
                                    model.updateAutoSuppressConfig(cfg)
                                }
                            ),
                            in: 50...90,
                            step: 5
                        )
                        Text(">\(Int(model.autoSuppressConfig.cpuThreshold))% CPU")
                            .font(.system(size: 10, design: .monospaced))
                    }

                    Divider()

                    HStack {
                        Text("Sort Order:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("", selection: $model.sortMode) {
                            ForEach(ProcessSortMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: model.sortMode) { _ in
                            model.refresh()
                        }
                    }

                    Toggle(isOn: $model.showSystemServices) {
                        Text("Show System & Protected Daemons (Advanced)")
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
                .cornerRadius(6)
                .padding([.horizontal, .bottom], 12)
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    if model.filteredProcesses.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 28))
                                .foregroundColor(.secondary)
                            Text("No matching applications found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 40)
                    } else {
                        ForEach(model.filteredProcesses) { proc in
                            ProcessCard(
                                proc: proc,
                                model: model,
                                isAutoSuppressed: model.autoSuppressedPIDs.contains(proc.pid)
                            )
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            HStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(model.isAutoSuppressionActive ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(model.isAutoSuppressionActive
                         ? "🛡️ Auto-suppressing \(model.autoSuppressedPIDs.count) heavy background app(s)"
                         : "🌿 Eco Mode: Apple Silicon Efficiency Cores")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Quit") {
                    model.quitApplication()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.red)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

struct ProcessCard: View {
    let proc: TrackedProcess
    @ObservedObject var model: ProcessViewModel
    var isAutoSuppressed: Bool = false

    var isProtected: Bool {
        return proc.safetyTier == .protectedSystem
    }

    var isEco: Bool {
        return proc.isEfficiencyClamped || isAutoSuppressed
    }

    var isThrottled: Bool {
        return proc.throttleLimitPercent != nil || isAutoSuppressed
    }

    var limitPercent: Double {
        if let limit = proc.throttleLimitPercent {
            return Double(limit)
        }
        return isAutoSuppressed ? Double(model.autoSuppressConfig.autoThrottleLimit) : 70.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: proc.safetyTier.badgeIcon)
                    .foregroundColor(proc.safetyTier == .protectedSystem ? .red : (proc.safetyTier == .cautionDaemon ? .orange : .green))
                    .help(proc.safetyTier.recommendation)
                    .imageScale(.medium)

                Text(proc.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                if isAutoSuppressed {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.shield.fill")
                        Text("Auto-Saved")
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.green.opacity(0.15))
                    .foregroundColor(.green)
                    .clipShape(Capsule())
                }

                Spacer()

                Text(String(format: "%.1f%% CPU", proc.cpuUsage))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(proc.cpuUsage > 50 ? .orange : .primary)
            }

            HStack(spacing: 8) {
                Button(action: {
                    if isEco {
                        model.resetToTurbo(pid: proc.pid, appName: proc.name)
                    } else {
                        model.clampToEco(pid: proc.pid, appName: proc.name)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isEco ? "leaf.fill" : "bolt.fill")
                        Text(isEco ? "E-Core Only" : "Default")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(isEco ? Color.green.opacity(0.18) : Color.blue.opacity(0.12))
                    .foregroundColor(isEco ? .green : .blue)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)

                Spacer()

                if isProtected {
                    Text("🛡️ System Protected")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.red)
                } else {
                    Toggle(isOn: Binding(
                        get: { isThrottled },
                        set: { active in
                            if active {
                                model.setLimit(pid: proc.pid, appName: proc.name, percent: Int(limitPercent))
                            } else {
                                model.removeLimit(pid: proc.pid, appName: proc.name)
                            }
                        }
                    )) {
                        Text(isThrottled ? "Limit: \(Int(limitPercent))%" : "Limit CPU")
                            .font(.system(size: 10))
                    }
                    .toggleStyle(.checkbox)
                }
            }

            if isThrottled && !isProtected {
                HStack(spacing: 6) {
                    Text("Cap:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Slider(
                        value: Binding(
                            get: { limitPercent },
                            set: { newVal in
                                model.setLimit(pid: proc.pid, appName: proc.name, percent: Int(newVal))
                            }
                        ),
                        in: 10...90,
                        step: 5
                    )
                    Text("\(Int(limitPercent))%")
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 32)
                }
            }
        }
        .padding(9)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(7)
    }
}
