import Foundation

enum BLEConnectionState: String {
    case discovered
    case queued
    case connecting
    case connected
    case interrogating
    case disconnecting
    case failed

    var title: String {
        switch self {
        case .discovered: "Обнаружено"
        case .queued: "В очереди"
        case .connecting: "Подключение"
        case .connected: "Подключено"
        case .interrogating: "Чтение GATT"
        case .disconnecting: "Отключение"
        case .failed: "Ошибка"
        }
    }
}

struct BLEImportantField: Identifiable, Hashable {
    var title: String
    var value: String
    var source: String
    var priority: Int

    var id: String { "\(source)|\(title)" }
}

struct BLEEvent: Identifiable, Hashable {
    let id = UUID()
    var date: Date
    var title: String
    var detail: String
}

struct BLEBeaconSnapshot: Equatable {
    var type: String
    var uuid: String
    var major: UInt16
    var minor: UInt16
    var measuredPower: Int

    var summary: String {
        "\(type) \(uuid) major \(major), minor \(minor), ref \(measuredPower) dBm"
    }
}

struct BLEServiceDataSnapshot: Identifiable, Equatable {
    var uuid: String
    var name: String
    var hex: String
    var decoded: String?

    var id: String { uuid }
}

struct BLEAdvertisementSnapshot: Equatable {
    var localName: String?
    var manufacturerCompanyID: UInt16?
    var manufacturerName: String?
    var manufacturerDataHex: String?
    var serviceUUIDs: [String]
    var solicitedServiceUUIDs: [String]
    var overflowServiceUUIDs: [String]
    var serviceData: [BLEServiceDataSnapshot]
    var txPower: Int?
    var isConnectable: Bool?
    var beacon: BLEBeaconSnapshot?
    var rawKeys: [String]

    static let empty = BLEAdvertisementSnapshot(
        localName: nil,
        manufacturerCompanyID: nil,
        manufacturerName: nil,
        manufacturerDataHex: nil,
        serviceUUIDs: [],
        solicitedServiceUUIDs: [],
        overflowServiceUUIDs: [],
        serviceData: [],
        txPower: nil,
        isConnectable: nil,
        beacon: nil,
        rawKeys: []
    )
}

struct BLEDescriptorSnapshot: Identifiable, Hashable {
    let id = UUID()
    var uuid: String
    var name: String
    var value: String?
}

struct BLECharacteristicSnapshot: Identifiable, Hashable {
    let id = UUID()
    var uuid: String
    var name: String
    var properties: [String]
    var rawValueHex: String?
    var decodedValue: String?
    var lastUpdated: Date?
    var isNotifying: Bool
    var descriptors: [BLEDescriptorSnapshot]

    mutating func upsertDescriptor(_ descriptor: BLEDescriptorSnapshot) {
        if let index = descriptors.firstIndex(where: { $0.uuid == descriptor.uuid }) {
            descriptors[index] = descriptor
        } else {
            descriptors.append(descriptor)
        }
    }
}

struct BLEServiceSnapshot: Identifiable, Hashable {
    let id = UUID()
    var uuid: String
    var name: String
    var isPrimary: Bool
    var characteristics: [BLECharacteristicSnapshot]

    mutating func upsertCharacteristic(_ characteristic: BLECharacteristicSnapshot) {
        if let index = characteristics.firstIndex(where: { $0.uuid == characteristic.uuid }) {
            characteristics[index] = characteristic
        } else {
            characteristics.append(characteristic)
        }
    }

    mutating func updateCharacteristic(uuid: String, _ update: (inout BLECharacteristicSnapshot) -> Void) {
        guard let index = characteristics.firstIndex(where: { $0.uuid == uuid }) else { return }
        update(&characteristics[index])
    }
}

struct BLEDistanceEstimate: Equatable {
    var meters: Double
    var confidence: Double
    var reference: String
    var volatility: Double

    var title: String {
        if meters < 1 {
            return String(format: "%.0f см", meters * 100)
        }
        if meters < 10 {
            return String(format: "%.1f м", meters)
        }
        return String(format: "%.0f м", meters)
    }

    var confidenceTitle: String {
        switch confidence {
        case 0.75...: "высокая"
        case 0.45..<0.75: "средняя"
        default: "низкая"
        }
    }
}

struct BLEDevice: Identifiable, Equatable {
    let id: UUID
    var peripheralName: String?
    var rssi: Int
    var rssiSamples: [Int]
    var firstSeen: Date
    var lastSeen: Date
    var advertisement: BLEAdvertisementSnapshot
    var connectionState: BLEConnectionState
    var services: [BLEServiceSnapshot]
    var importantFields: [BLEImportantField]
    var events: [BLEEvent]
    var readCount: Int
    var notifyCount: Int
    var errorCount: Int
    var calibratedRSSIAtOneMeter: Int?
    var radarAngle: Double

    var displayName: String {
        if let localName = advertisement.localName, !localName.isEmpty {
            return localName
        }
        if let peripheralName, !peripheralName.isEmpty {
            return peripheralName
        }
        return "Unknown \(id.uuidString.prefix(8))"
    }

    var smoothedRSSI: Double {
        let window = Array(rssiSamples.suffix(9))
        guard !window.isEmpty else { return Double(rssi) }
        let sorted = window.sorted()
        let median = Double(sorted[sorted.count / 2])
        let average = Double(window.reduce(0, +)) / Double(window.count)
        return (median * 0.65) + (average * 0.35)
    }

    var distance: BLEDistanceEstimate {
        DistanceEstimator.estimate(for: self)
    }

    var isConnectable: Bool {
        advertisement.isConnectable ?? true
    }

    var ageTitle: String {
        let seconds = max(0, Date().timeIntervalSince(lastSeen))
        if seconds < 1 { return "только что" }
        if seconds < 60 { return "\(Int(seconds)) c назад" }
        return "\(Int(seconds / 60)) мин назад"
    }

    mutating func appendRSSI(_ newRSSI: Int) {
        rssi = newRSSI
        rssiSamples.append(newRSSI)
        if rssiSamples.count > 40 {
            rssiSamples.removeFirst(rssiSamples.count - 40)
        }
    }

    mutating func upsertService(_ service: BLEServiceSnapshot) {
        if let index = services.firstIndex(where: { $0.uuid == service.uuid }) {
            services[index] = service
        } else {
            services.append(service)
            services.sort { $0.name < $1.name }
        }
    }

    mutating func updateService(uuid: String, _ update: (inout BLEServiceSnapshot) -> Void) {
        guard let index = services.firstIndex(where: { $0.uuid == uuid }) else { return }
        update(&services[index])
    }

    mutating func upsertImportant(_ field: BLEImportantField) {
        if let index = importantFields.firstIndex(where: { $0.id == field.id }) {
            importantFields[index] = field
        } else {
            importantFields.append(field)
        }
        importantFields.sort {
            if $0.priority == $1.priority {
                return $0.title < $1.title
            }
            return $0.priority < $1.priority
        }
    }

    mutating func addEvent(_ title: String, _ detail: String) {
        events.insert(BLEEvent(date: Date(), title: title, detail: detail), at: 0)
        if events.count > 25 {
            events.removeLast(events.count - 25)
        }
    }
}

enum DistanceEstimator {
    static func estimate(for device: BLEDevice) -> BLEDistanceEstimate {
        let referenceRSSI: Double
        let referenceTitle: String

        if let calibrated = device.calibratedRSSIAtOneMeter {
            referenceRSSI = Double(calibrated)
            referenceTitle = "калибровка 1 м"
        } else if let beaconPower = device.advertisement.beacon?.measuredPower {
            referenceRSSI = Double(beaconPower)
            referenceTitle = "iBeacon measured power"
        } else {
            referenceRSSI = -59
            referenceTitle = "RSSI модель по умолчанию"
        }

        let pathLossExponent = 2.25
        let ratio = (referenceRSSI - device.smoothedRSSI) / (10 * pathLossExponent)
        let meters = min(80, max(0.05, pow(10, ratio)))

        let volatility = standardDeviation(Array(device.rssiSamples.suffix(12)).map(Double.init))
        var confidence = 0.32
        confidence += min(Double(device.rssiSamples.count), 20) * 0.015
        if device.calibratedRSSIAtOneMeter != nil { confidence += 0.28 }
        if device.advertisement.beacon != nil { confidence += 0.18 }
        if volatility < 4 { confidence += 0.12 }
        confidence -= min(volatility, 18) * 0.018
        confidence = min(0.98, max(0.08, confidence))

        return BLEDistanceEstimate(
            meters: meters,
            confidence: confidence,
            reference: referenceTitle,
            volatility: volatility
        )
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let average = values.reduce(0, +) / Double(values.count)
        let variance = values
            .map { pow($0 - average, 2) }
            .reduce(0, +) / Double(values.count - 1)
        return sqrt(variance)
    }

    static func stableAngle(for id: UUID) -> Double {
        let scalarSum = id.uuidString.unicodeScalars.reduce(UInt32(0)) { partial, scalar in
            partial &+ scalar.value
        }
        return (Double(scalarSum % 360) / 360.0) * .pi * 2
    }
}
