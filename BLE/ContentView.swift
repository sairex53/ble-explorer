import CoreBluetooth
import SwiftUI

struct ContentView: View {
    @StateObject private var scanner = BLEScanner()

    var body: some View {
        TabView {
            RadarScreen(scanner: scanner)
                .tabItem {
                    Label("Радар", systemImage: "scope")
                }

            DeviceListScreen(scanner: scanner)
                .tabItem {
                    Label("Устройства", systemImage: "list.bullet")
                }

            DeviceIntelScreen(scanner: scanner)
                .tabItem {
                    Label("Важное", systemImage: "info.circle")
                }
        }
    }
}

private struct RadarScreen: View {
    @ObservedObject var scanner: BLEScanner

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScannerHeader(scanner: scanner)

                    RadarCanvas(devices: scanner.devices, selectedID: scanner.selectedDevice?.id)
                        .frame(height: 360)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Позиция на радаре считается по RSSI-дистанции. У обычного BLE нет точного bearing на iPhone, поэтому угол на экране — стабильная раскладка, а не компас.", systemImage: "location.magnifyingglass")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if let active = scanner.activeDevice {
                            Label("Сейчас читаю: \(active.displayName)", systemImage: "bolt.horizontal.circle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }

                    NearbyStrip(scanner: scanner)
                }
                .padding()
            }
            .navigationTitle("BLE Radar")
        }
    }
}

private struct DeviceListScreen: View {
    @ObservedObject var scanner: BLEScanner

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(scanner.devices) { device in
                        Button {
                            scanner.select(device)
                        } label: {
                            DeviceRow(device: device, selected: scanner.selectedDevice?.id == device.id)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("GATT") {
                                scanner.interrogate(device)
                            }
                            .tint(.green)
                        }
                    }
                } header: {
                    Text("\(scanner.devices.count) devices")
                } footer: {
                    Text("Auto GATT читает только advertising/GATT-данные, которые устройство отдает CoreBluetooth. Если характеристика требует pairing, iOS покажет системный запрос.")
                }
            }
            .overlay {
                if scanner.devices.isEmpty {
                    ContentUnavailableView(
                        "Пока пусто",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text(scanner.statusMessage)
                    )
                }
            }
            .navigationTitle("Устройства")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(scanner.isScanning ? "Stop" : "Scan") {
                        scanner.toggleScanning()
                    }
                    Button("Clear") {
                        scanner.clearDevices()
                    }
                    .disabled(scanner.devices.isEmpty)
                }
            }
        }
    }
}

private struct DeviceIntelScreen: View {
    @ObservedObject var scanner: BLEScanner

    var body: some View {
        NavigationStack {
            Group {
                if let device = scanner.selectedDevice {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            DeviceHero(device: device, scanner: scanner)

                            SectionTitle("Самое важное")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                                ForEach(device.importantFields) { field in
                                    InfoTile(field: field)
                                }
                            }

                            AdvertisementPanel(device: device)
                            GATTPanel(device: device)
                            EventPanel(device: device)
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "Выбери устройство",
                        systemImage: "info.circle",
                        description: Text("Сначала дождись BLE advertising на вкладке радара или списка.")
                    )
                }
            }
            .navigationTitle("Важное")
        }
    }
}

private struct ScannerHeader: View {
    @ObservedObject var scanner: BLEScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scanner.statusMessage)
                        .font(.headline)
                    Text("Bluetooth: \(scanner.bluetoothState.title), permission: \(scanner.authorization.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    scanner.toggleScanning()
                } label: {
                    Label(scanner.isScanning ? "Stop" : "Scan", systemImage: scanner.isScanning ? "pause.circle.fill" : "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 12) {
                Toggle("Auto GATT", isOn: $scanner.autoInterrogate)
                    .toggleStyle(.switch)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                StatPill(title: "Devices", value: "\(scanner.devices.count)")
                StatPill(title: "Queue", value: scanner.activeDevice == nil ? "idle" : "busy")
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RadarCanvas: View {
    var devices: [BLEDevice]
    var selectedID: UUID?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                drawRadar(context: &context, size: size, date: timeline.date)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("BLE radar")
    }

    private func drawRadar(context: inout GraphicsContext, size: CGSize, date: Date) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = side * 0.43
        let maxDistance = maxRadarDistance

        drawBackground(context: &context, size: size)
        drawRings(context: &context, center: center, radius: radius, maxDistance: maxDistance)
        drawSweep(context: &context, center: center, radius: radius, date: date)
        drawCenter(context: &context, center: center)
        drawDevices(context: &context, center: center, radius: radius, maxDistance: maxDistance)
    }

    private var maxRadarDistance: Double {
        let observed = devices.map { $0.distance.meters }.max() ?? 8
        return max(8, min(40, observed * 1.25))
    }

    private func drawBackground(context: inout GraphicsContext, size: CGSize) {
        var background = Path()
        background.addRoundedRect(in: CGRect(origin: .zero, size: size), cornerSize: CGSize(width: 8, height: 8))
        context.fill(background, with: .color(.black))
    }

    private func drawRings(context: inout GraphicsContext, center: CGPoint, radius: CGFloat, maxDistance: Double) {
        for step in 1...4 {
            let ringRadius = radius * CGFloat(step) / 4
            var ring = Path()
            ring.addEllipse(in: CGRect(
                x: center.x - ringRadius,
                y: center.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            ))
            context.stroke(ring, with: .color(.green.opacity(0.22)), lineWidth: 1)

            let meters = Int(maxDistance * Double(step) / 4)
            let label = Text("\(meters)m")
                .font(.caption2)
                .foregroundStyle(.green.opacity(0.65))
            context.draw(label, at: CGPoint(x: center.x + ringRadius + 14, y: center.y), anchor: .center)
        }

        var crosshair = Path()
        crosshair.move(to: CGPoint(x: center.x - radius, y: center.y))
        crosshair.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - radius))
        crosshair.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        context.stroke(crosshair, with: .color(.green.opacity(0.18)), lineWidth: 1)
    }

    private func drawSweep(context: inout GraphicsContext, center: CGPoint, radius: CGFloat, date: Date) {
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
        let sweep = progress * .pi * 2
        var sweepPath = Path()
        sweepPath.move(to: center)
        let sweepAngle = CGFloat(sweep)
        sweepPath.addLine(to: CGPoint(
            x: center.x + cos(sweepAngle) * radius,
            y: center.y + sin(sweepAngle) * radius
        ))
        context.stroke(sweepPath, with: .color(.green.opacity(0.65)), lineWidth: 2)
    }

    private func drawCenter(context: inout GraphicsContext, center: CGPoint) {
        var centerDot = Path()
        centerDot.addEllipse(in: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
        context.fill(centerDot, with: .color(.white))
    }

    private func drawDevices(context: inout GraphicsContext, center: CGPoint, radius: CGFloat, maxDistance: Double) {
        for device in devices.prefix(60) {
            let normalized = min(1, log10(device.distance.meters + 1) / log10(maxDistance + 1))
            let pointRadius = CGFloat(normalized) * radius
            let angle = CGFloat(device.radarAngle)
            let point = CGPoint(
                x: center.x + cos(angle) * pointRadius,
                y: center.y + sin(angle) * pointRadius
            )
            drawDevice(device, point: point, context: &context)
        }
    }

    private func drawDevice(_ device: BLEDevice, point: CGPoint, context: inout GraphicsContext) {
        let isSelected = device.id == selectedID
        let color = device.radarColor(selected: isSelected)
        let dotSize: CGFloat = isSelected ? 15 : 10
        let confidenceRadius = dotSize + CGFloat(16 * device.distance.confidence)

        var pulse = Path()
        pulse.addEllipse(in: CGRect(
            x: point.x - confidenceRadius,
            y: point.y - confidenceRadius,
            width: confidenceRadius * 2,
            height: confidenceRadius * 2
        ))
        context.stroke(pulse, with: .color(color.opacity(isSelected ? 0.45 : 0.22)), lineWidth: isSelected ? 2 : 1)

        var dot = Path()
        dot.addEllipse(in: CGRect(x: point.x - dotSize / 2, y: point.y - dotSize / 2, width: dotSize, height: dotSize))
        context.fill(dot, with: .color(color))

        let opacity = isSelected ? 1.0 : 0.82
        let label = Text("\(device.displayName)\n\(device.distance.title)")
            .font(.caption2)
            .foregroundStyle(.white.opacity(opacity))
        context.draw(label, at: CGPoint(x: point.x + 10, y: point.y - 8), anchor: .leading)
    }
}

private struct NearbyStrip: View {
    @ObservedObject var scanner: BLEScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Ближайшие")
            ForEach(scanner.devices.prefix(6)) { device in
                Button {
                    scanner.select(device)
                } label: {
                    HStack(spacing: 10) {
                        SignalMeter(rssi: Int(device.smoothedRSSI.rounded()))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text("\(device.connectionState.title) · \(device.ageTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(device.distance.title)
                            .font(.headline.monospacedDigit())
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct DeviceRow: View {
    var device: BLEDevice
    var selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            SignalMeter(rssi: Int(device.smoothedRSSI.rounded()))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(device.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(device.distance.title)
                    .font(.headline.monospacedDigit())
                Text("\(Int(device.smoothedRSSI.rounded())) dBm")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(device.connectionState.title)
                    .font(.caption2)
                    .foregroundStyle(device.connectionState.tint)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let company = device.advertisement.manufacturerName
            ?? device.advertisement.manufacturerCompanyID.map { String(format: "Company 0x%04X", $0) }
            ?? "Unknown manufacturer"
        let service = device.advertisement.serviceUUIDs.first ?? device.services.first?.name ?? "No services yet"
        return "\(company) · \(service) · \(device.ageTitle)"
    }
}

private struct DeviceHero: View {
    var device: BLEDevice
    @ObservedObject var scanner: BLEScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.displayName)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(2)
                    Text(device.id.uuidString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(device.distance.title)
                        .font(.title.weight(.bold).monospacedDigit())
                    Text("\(Int(device.smoothedRSSI.rounded())) dBm · \(device.distance.confidenceTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label(device.connectionState.title, systemImage: "link")
                    .foregroundStyle(device.connectionState.tint)
                Spacer()
                Button("Read now") {
                    scanner.interrogate(device)
                }
                .buttonStyle(.bordered)
                Button("Calibrate 1m") {
                    scanner.calibrateSelectedAtOneMeter()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AdvertisementPanel: View {
    var device: BLEDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Advertising")
            KeyValueRow("Connectable", device.advertisement.isConnectable.map { $0 ? "yes" : "no" } ?? "unknown")
            KeyValueRow("TX power", device.advertisement.txPower.map { "\($0) dBm" } ?? "not exposed")
            KeyValueRow("Manufacturer data", device.advertisement.manufacturerDataHex ?? "not exposed")
            if let beacon = device.advertisement.beacon {
                KeyValueRow("Beacon", beacon.summary)
            }
            if !device.advertisement.serviceData.isEmpty {
                ForEach(device.advertisement.serviceData) { serviceData in
                    KeyValueRow("Service data \(serviceData.name)", serviceData.decoded ?? serviceData.hex)
                }
            }
        }
    }
}

private struct GATTPanel: View {
    var device: BLEDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("GATT dump")
            if device.services.isEmpty {
                Text("Сервисов пока нет: устройство может быть non-connectable, требовать pairing или еще не дошло до очереди Auto GATT.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(device.services) { service in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(service.characteristics) { characteristic in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(characteristic.name)
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        if characteristic.isNotifying {
                                            Text("notify")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    Text(characteristic.uuid)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(characteristic.properties.joined(separator: " · "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let decoded = characteristic.decodedValue {
                                        Text(decoded)
                                            .font(.body.monospaced())
                                            .textSelection(.enabled)
                                    }
                                    if let raw = characteristic.rawValueHex {
                                        Text(raw)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    ForEach(characteristic.descriptors) { descriptor in
                                        Text("\(descriptor.name): \(descriptor.value ?? "nil")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(10)
                                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(service.name)
                                    .font(.headline)
                                Text("\(service.uuid) · \(service.characteristics.count) chars")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

private struct EventPanel: View {
    var device: BLEDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Live log")
            ForEach(device.events) { event in
                HStack(alignment: .top, spacing: 8) {
                    Text(event.date, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.caption.weight(.semibold))
                        Text(event.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
            }
        }
    }
}

private struct InfoTile: View {
    var field: BLEImportantField

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(field.value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(4)
                .textSelection(.enabled)
            Text(field.source)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct KeyValueRow: View {
    var key: String
    var value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospaced())
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StatPill: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }
}

private struct SignalMeter: View {
    var rssi: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { index in
                Capsule()
                    .fill(index < level ? Color.green : Color.gray.opacity(0.25))
                    .frame(width: 4, height: CGFloat(7 + index * 4))
            }
        }
        .frame(width: 24)
        .accessibilityLabel("RSSI \(rssi) dBm")
    }

    private var level: Int {
        switch rssi {
        case -55...0: 4
        case -70..<(-55): 3
        case -85..<(-70): 2
        default: 1
        }
    }
}

private struct SectionTitle: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension BLEConnectionState {
    var tint: Color {
        switch self {
        case .connected, .interrogating: .green
        case .connecting, .queued, .disconnecting: .orange
        case .failed: .red
        case .discovered: .secondary
        }
    }
}

private extension BLEDevice {
    func radarColor(selected: Bool) -> Color {
        if selected { return .orange }
        switch connectionState {
        case .connected, .interrogating:
            return .cyan
        case .connecting, .queued, .disconnecting:
            return .yellow
        case .failed:
            return .red
        case .discovered:
            return distance.confidence > 0.6 ? .green : .mint
        }
    }
}

private extension CBManagerState {
    var title: String {
        switch self {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .poweredOff: "off"
        case .poweredOn: "on"
        @unknown default: "unknown"
        }
    }
}

private extension CBManagerAuthorization {
    var title: String {
        switch self {
        case .notDetermined: "not determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .allowedAlways: "allowed"
        @unknown default: "unknown"
        }
    }
}

#Preview {
    ContentView()
}
