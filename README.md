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
- **Smart Notifications:** Sends elegant macOS system notifications when your battery is fully charged (100%) or drops below 20%.
- **Launch at Login:** Includes a built-in toggle using native `SMAppService` to automatically start when you turn on your Mac.

## How It Works

WattWhat directly queries the macOS `IOKit` framework and `AppleSmartBattery` registry to read raw hardware sensors like `Voltage` and `Amperage`. It calculates true instantaneous wattage (`Watts = Voltage * Amperage / 1,000,000`) every 3 seconds for extreme accuracy, bypassing the delay often seen in standard system monitors.

## Installation / Building from Source

### Quick Install via Terminal
You can quickly install the latest compiled version directly to your Applications folder with this one-line command:
```bash
curl -L https://github.com/kuarezma/WattWhat/releases/latest/download/WattWhat.zip -o /tmp/WattWhat.zip && unzip -o /tmp/WattWhat.zip -d /Applications && rm /tmp/WattWhat.zip
```

### Building from Source
Since WattWhat is a single Swift file, it is incredibly easy to compile and run.

1. Clone or download this repository.
2. Open your terminal and navigate to the folder.
3. Run the automated build script (written in Swift) to compile the app, generate a `.zip` archive, and create an installable `.dmg` file automatically:

```bash
./build.swift
```

Alternatively, to compile the app bundle manually:

```bash
swiftc WattWhat.swift -o "WattWhat.app/Contents/MacOS/WattWhat"
```

## Requirements

- macOS 13.0 or later (for native SMAppService Login Item support, though fallback exists for older versions)
- Apple Silicon (M1/M2/M3) or Intel Mac

## License

MIT License. Feel free to use, modify, and distribute as you wish!
