import SwiftUI
import CoreEaseKit
import Combine

@main
struct CoreEaseApp: App {
    @StateObject private var model = ProcessViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("CoreEase", systemImage: "cpu") {
            ContentView(model: model)
                .frame(width: 480, height: 560)
        }
        .menuBarExtraStyle(.window)

        Window("CoreEase Dashboard", id: "main-dashboard") {
            LaunchWindowView(model: model)
                .frame(minWidth: 640, minHeight: 580)
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

    private var timer: AnyCancellable?
    private let policyStore = ThrottlePolicyStore.shared

    init() {
        refresh()
        // Adaptive Cadence (engineered-flow Energy & Battery audit):
        // 2.5s cadence to preserve MacBook battery during background tracking
        timer = Timer.publish(every: 2.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                if self?.autoRefresh == true {
                    self?.refresh()
                }
            }

        // Listen for system sleep to halt and resume safely
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

    func refresh() {
        let fetched = ProcessMonitor.shared.getTopProcesses(limit: 50)
        let savedPolicies = policyStore.getAllPolicies()

        var currentMap: [Int32: TrackedProcess] = [:]
        for p in processes {
            currentMap[p.pid] = p
        }

        var merged: [TrackedProcess] = []
        for newP in fetched {
            var proc = newP

            // Check if user has a persistent policy for this application
            if let policy = savedPolicies[proc.name] {
                proc.isEfficiencyClamped = policy.isEco
                proc.throttleLimitPercent = policy.throttleLimitPercent

                // Reapply active throttle/clamp if not currently running
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

        switch sortMode {
        case .name:
            self.processes = merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid:
            self.processes = merged.sorted { $0.pid < $1.pid }
        case .cpu:
            self.processes = merged.sorted { $0.cpuUsage > $1.cpuUsage }
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

        // Persist policy
        var policy = policyStore.getPolicy(for: appName) ?? AppThrottlePolicy(appName: appName)
        policy.isEco = true
        policyStore.setPolicy(policy)
    }

    func resetToTurbo(pid: Int32, appName: String) {
        _ = CoreScheduler.shared.resetToDefaultCores(pid: pid)
        if let idx = processes.firstIndex(where: { $0.pid == pid }) {
            processes[idx].isEfficiencyClamped = false
        }

        // Update persistent policy
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

        // Persist policy permanently for this app name
        var policy = policyStore.getPolicy(for: appName) ?? AppThrottlePolicy(appName: appName)
        policy.throttleLimitPercent = percent
        policyStore.setPolicy(policy)
    }

    func removeLimit(pid: Int32, appName: String) {
        CPUThrottler.shared.stopThrottling(pid: pid)
        if let idx = processes.firstIndex(where: { $0.pid == pid }) {
            processes[idx].throttleLimitPercent = nil
        }

        // Update persistent policy
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
        .frame(minWidth: 600, minHeight: 600)
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

                Image(systemName: "cpu.fill")
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
                .help("Settings & System Services")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            if showSettings {
                VStack(alignment: .leading, spacing: 8) {
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
                            ProcessCard(proc: proc, model: model)
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            HStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("🌿 Eco: Apple Silicon Efficiency Cores")
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

    var isProtected: Bool {
        return proc.safetyTier == .protectedSystem
    }

    // Direct binding to model's tracked state to prevent state loss on popover recreate
    var isEco: Bool {
        return proc.isEfficiencyClamped
    }

    var isThrottled: Bool {
        return proc.throttleLimitPercent != nil
    }

    var limitPercent: Double {
        return Double(proc.throttleLimitPercent ?? 70)
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

                Spacer()

                Text(String(format: "%.1f%% CPU", proc.cpuUsage))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(proc.cpuUsage > 50 ? .orange : .primary)
            }

            HStack(spacing: 8) {
                // E-Core Clamp Toggle
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
