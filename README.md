# BLE Explorer

A SwiftUI iOS app for exploring nearby Bluetooth Low Energy devices, their advertised data and public GATT services.

## Features

- Nearby device list and signal-strength updates.
- Device details, services and characteristics.
- Decoders for supported Bluetooth data formats.
- Optional automatic interrogation of discovered peripherals.

## Build and run

Requires a full Xcode installation with an iOS SDK, and a physical iPhone or iPad for Bluetooth testing. The app target currently has an iOS 18.6 deployment target; project-level configurations contain an iOS 26.2 setting, so use a compatible SDK or adjust those project defaults.

1. Open `BLE.xcodeproj` in Xcode.
2. Select the **BLE** target and your device.
3. Under **Signing & Capabilities**, choose your own development team.
4. Replace `org.example.BLEExplorer` with a bundle identifier available to your account.
5. Build and run, then allow Bluetooth access.

The repository contains no developer-team identifier or personal signing assets.

## Source layout

- `BLEScanner.swift`: CoreBluetooth scanning, connections and interrogation.
- `BLEModels.swift`: device and GATT data models.
- `BLEDecoders.swift`: decoding helpers.
- `ContentView.swift`: SwiftUI interface.
- `AppInfo.plist`: Bluetooth permissions and application metadata.

## Behavior and limitations

Automatic interrogation is enabled by default and may connect to discovered devices to inspect their services. Use the app with your own devices or devices you have permission to inspect. Availability of characteristic data depends on the peripheral and its access controls. Simulator-only testing does not validate real Bluetooth behavior.

This is an experimental exploration tool. Device testing and Xcode signing must be completed on the machine used to build it.

## License

[MIT](LICENSE) © 2026 sairex53.
