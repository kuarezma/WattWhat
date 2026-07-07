# WattWhat ⚡️

A minimalist and smart macOS menu bar application built with pure Swift that monitors your MacBook's real-time battery usage, charging wattage, and temperature.

## Features

- **Live Power Monitoring:** Displays the exact instantaneous wattage your MacBook is consuming (when on battery) or receiving (when charging).
- **Dynamic Icons:** The menu bar icon changes color to visually indicate your battery status:
  - 🟢 **Green Bolt:** Charging
  - 🟡 **Yellow Bolt:** On Battery
- **Smart Averages:** Calculates your true average charging speed or power consumption from the moment the power state changes.
- **Time Remaining:** Shows exactly how much time is left until your battery is fully charged or completely empty, in a clean `(1s 20d)` format.
- **Battery Temperature:** Monitors the `AppleSmartBattery` sensor to show real-time temperature in °C.
- **Per-App Energy:** Ranks the three applications with the highest kernel-attributed process energy over the latest 3-second sample. Helper and child processes are grouped under their parent application.
- **True Battery Health:** Automatically reads and displays the exact official battery health percentage from `system_profiler` to match macOS System Settings perfectly.
- **Smart Notifications:** Sends elegant macOS system notifications when your battery is fully charged (100%) or drops below 20%.
- **Launch at Login:** Includes a built-in toggle using native `SMAppService` to automatically start when you turn on your Mac.

## How It Works

WattWhat directly queries the macOS `IOKit` framework and `AppleSmartBattery` registry to read raw hardware sensors like `Voltage` and `Amperage`. It calculates true instantaneous wattage (`Watts = Voltage * Amperage / 1,000,000`) every 3 seconds for extreme accuracy, bypassing the delay often seen in standard system monitors.

Per-app values are measured independently from the battery total. WattWhat samples macOS process resource counters (`ri_energy_nj`) and converts the energy delta into watts. These values represent energy attributed by macOS to application processes; they do not divide total battery wattage by CPU percentage.

### Installation Methods

There are several ways to install WattWhat depending on your preference. All available on the [Releases](https://github.com/kuarezma/WattWhat/releases) page:

1. **(Recommended) Auto-Install Script:** Download the `Yukle_WattWhat.command` file from the latest release, double-click to run it. It will securely download, install to `/Applications`, bypass macOS "app is damaged" (quarantine) warnings, and launch the app automatically.
2. **PKG Installer:** Download `WattWhat.pkg` and follow the standard macOS installation wizard.
3. **DMG Disk Image:** Download `WattWhat.dmg`, open it, and drag the app into your Applications folder.
4. **ZIP Archive:** Download `WattWhat.zip`, extract it, and move it to Applications.

*Note: If you use the DMG or ZIP and get an "app is damaged and cannot be opened" error, this is a standard macOS security feature for unsigned apps. To fix it quickly, open Terminal and run `xattr -cr /Applications/WattWhat.app`.*

### Building from Source
Since WattWhat is a single Swift file, it is incredibly easy to compile and run.

1. Clone or download this repository.
2. Open your terminal and navigate to the folder.
3. Run the automated build script (written in Swift) to compile the app and generate all distribution files (`.zip`, `.dmg`, `.pkg`, and `Yukle_WattWhat.command`) automatically:

```bash
./build.swift
```

Run the core unit tests with:

```bash
swift test
```

Alternatively, to compile the app bundle manually:

```bash
swiftc WattWhat.swift Sources/WattWhatCore/ProcessEnergy.swift -o "WattWhat.app/Contents/MacOS/WattWhat"
```

## Requirements

- macOS 13.0 or later (for native SMAppService Login Item support, though fallback exists for older versions)
- Apple Silicon (M1/M2/M3) or Intel Mac

## License

MIT License. Feel free to use, modify, and distribute as you wish!

## Changelog

- **2026-07-07:** Replaced CPU-proportional estimated app wattage with measured process-energy deltas, application-level process grouping, and unit tests.
