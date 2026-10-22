# CoreEase (Apple Silicon Edition)

**Intelligent CPU Core Scheduling & Throttling Utility for macOS.**

CoreEase is a lightweight, native macOS Menu Bar application and CLI tool built for Apple Silicon (M1/M2/M3/M4) MacBooks to keep your system cool, silent, and responsive.

---

## Features

- **🌿 1-Click Efficiency Core (E-Core) Clamping**:
  - Leverages Darwin's QoS background policies (`taskpolicy -b`) to pin heavy processes (compilers, AI models, background electron apps) strictly to Apple Silicon Efficiency Cores.
  - Eliminates fan noise and thermal throttling without needing to quit the application.
- **⚡ Dynamic CPU Usage Throttling**:
  - Smooth micro-sliced POSIX duty-cycle modulation (`SIGSTOP` / `SIGCONT`) capping CPU consumers to any chosen ceiling. Defaults to a snappy **70%**.
- **🛡️ Intelligent System Safety Shield**:
  - Hides sensitive system daemons by default.
  - Protects vital macOS system components (`WindowServer`, `launchd`, `loginwindow`) from accidental throttling to avoid beachballs or display freezing.
- **🪟 Launch Dashboard & Menu Bar Extra**:
  - Runs in your macOS status bar with fixed-position process rows that never jitter or reorder when CPU usage spikes.
  - Includes a full standalone Launch Dashboard window.
- **Quit & Restore**:
  - Single-click quit button that terminates all limits, cleans up all threads, and restores full system clocks.

---

## Installation & Running

### Option 1: Pre-built App (Release)
Download `CoreEase.zip` from [Releases](https://github.com/workingharry/CoreEase/releases), unzip, and move `CoreEase.app` into `/Applications`.

### Option 2: Build from Source
```bash
git clone https://github.com/workingharry/CoreEase.git
cd CoreEase
swift build -c release
```

To run the Menu Bar App:
```bash
open CoreEase.app
```

To run the CLI tool:
```bash
swift run coreease-cli list
swift run coreease-cli eco <PID>
swift run coreease-cli limit <PID> 70
```

---

## License
MIT License.
