import CoreBluetooth
import Foundation

struct BLEDecodedValue {
    var summary: String
    var importantTitle: String?
    var importantValue: String?
    var priority: Int
}

enum BLEDecoder {
    static func advertisementSnapshot(from advertisementData: [String: Any]) -> BLEAdvertisementSnapshot {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let manufacturerCompanyID = manufacturerData?.uint16LE(at: 0)
        let manufacturerName = manufacturerCompanyID.flatMap { companyNames[$0] }
        let serviceUUIDs = uuidTitles(advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
        let solicitedServiceUUIDs = uuidTitles(advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? [])
        let overflowServiceUUIDs = uuidTitles(advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:])
            .map { uuid, data in
                BLEServiceDataSnapshot(
                    uuid: uuid.uuidString,
                    name: serviceName(uuid),
                    hex: data.hexString,
                    decoded: decodeShortPayload(data)
                )
            }
            .sorted { $0.name < $1.name }
        let txPower = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        let rawKeys = advertisementData.keys.sorted()

        return BLEAdvertisementSnapshot(
            localName: localName,
            manufacturerCompanyID: manufacturerCompanyID,
            manufacturerName: manufacturerName,
            manufacturerDataHex: manufacturerData?.hexString,
            serviceUUIDs: serviceUUIDs,
            solicitedServiceUUIDs: solicitedServiceUUIDs,
            overflowServiceUUIDs: overflowServiceUUIDs,
            serviceData: serviceData,
            txPower: txPower,
            isConnectable: isConnectable,
            beacon: decodeBeacon(from: manufacturerData, companyID: manufacturerCompanyID),
            rawKeys: rawKeys
        )
    }

    static func advertisementFields(from advertisement: BLEAdvertisementSnapshot, rssi: Int) -> [BLEImportantField] {
        var fields: [BLEImportantField] = [
            BLEImportantField(title: "RSSI", value: "\(rssi) dBm", source: "Advertisement", priority: 0)
        ]

        if let name = advertisement.localName, !name.isEmpty {
            fields.append(BLEImportantField(title: "Local name", value: name, source: "Advertisement", priority: 1))
        }

        if let companyID = advertisement.manufacturerCompanyID {
            let idText = String(format: "0x%04X", companyID)
            let company = advertisement.manufacturerName.map { "\($0) (\(idText))" } ?? idText
            fields.append(BLEImportantField(title: "Manufacturer", value: company, source: "Advertisement", priority: 2))
        }

        if let beacon = advertisement.beacon {
            fields.append(BLEImportantField(title: "Beacon", value: beacon.summary, source: "Advertisement", priority: 3))
        }

        if !advertisement.serviceUUIDs.isEmpty {
            fields.append(BLEImportantField(
                title: "Advertised services",
                value: advertisement.serviceUUIDs.joined(separator: ", "),
                source: "Advertisement",
                priority: 4
            ))
        }

        if let connectable = advertisement.isConnectable {
            fields.append(BLEImportantField(
                title: "Connectable",
                value: connectable ? "yes" : "no",
                source: "Advertisement",
                priority: 5
            ))
        }

        return fields
    }

    static func serviceName(_ uuid: CBUUID) -> String {
        standardServices[uuid.uuidString.uppercased()] ?? "Service \(uuid.uuidString)"
    }

    static func characteristicName(_ uuid: CBUUID) -> String {
        standardCharacteristics[uuid.uuidString.uppercased()] ?? "Characteristic \(uuid.uuidString)"
    }

    static func descriptorName(_ uuid: CBUUID) -> String {
        standardDescriptors[uuid.uuidString.uppercased()] ?? "Descriptor \(uuid.uuidString)"
    }

    static func uuidTitle(_ uuid: CBUUID) -> String {
        let name = standardServices[uuid.uuidString.uppercased()]
            ?? standardCharacteristics[uuid.uuidString.uppercased()]
        guard let name else { return uuid.uuidString }
        return "\(name) (\(uuid.uuidString))"
    }

    private static func uuidTitles(_ uuids: [CBUUID]) -> [String] {
        var titles: [String] = []
        for uuid in uuids {
            titles.append(uuidTitle(uuid))
        }
        return titles.sorted()
    }

    static func decodeCharacteristic(uuid: CBUUID, value: Data) -> BLEDecodedValue {
        let key = uuid.uuidString.uppercased()

        switch key {
        case "2A00":
            return textValue(value, title: "Device name", priority: 0)
        case "2A01":
            let code = value.uint16LE(at: 0) ?? 0
            let summary = "\(appearanceName(code)) (\(code))"
            return BLEDecodedValue(summary: summary, importantTitle: "Appearance", importantValue: summary, priority: 6)
        case "2A04":
            return decodeConnectionParameters(value)
        case "2A05":
            let start = value.uint16LE(at: 0) ?? 0
            let end = value.uint16LE(at: 2) ?? 0
            return BLEDecodedValue(summary: "Changed handles \(start)...\(end)", importantTitle: nil, importantValue: nil, priority: 99)
        case "2A07":
            let power = value.int8(at: 0) ?? 0
            return BLEDecodedValue(summary: "\(power) dBm", importantTitle: "TX power", importantValue: "\(power) dBm", priority: 6)
        case "2A19":
            let battery = min(100, Int(value.byte(at: 0) ?? 0))
            return BLEDecodedValue(summary: "\(battery)%", importantTitle: "Battery", importantValue: "\(battery)%", priority: 1)
        case "2A23":
            return BLEDecodedValue(summary: value.hexString, importantTitle: "System ID", importantValue: value.hexString, priority: 8)
        case "2A24":
            return textValue(value, title: "Model", priority: 1)
        case "2A25":
            return textValue(value, title: "Serial", priority: 2)
        case "2A26":
            return textValue(value, title: "Firmware", priority: 3)
        case "2A27":
            return textValue(value, title: "Hardware", priority: 4)
        case "2A28":
            return textValue(value, title: "Software", priority: 4)
        case "2A29":
            return textValue(value, title: "Manufacturer", priority: 0)
        case "2A2B":
            return decodeCurrentTime(value)
        case "2A37":
            return decodeHeartRate(value)
        case "2A38":
            let location = bodySensorLocation(Int(value.byte(at: 0) ?? 0))
            return BLEDecodedValue(summary: location, importantTitle: "Body sensor", importantValue: location, priority: 7)
        case "2A50":
            return decodePnPID(value)
        case "2A6E":
            let raw = value.int16LE(at: 0) ?? 0
            let celsius = Double(raw) / 100.0
            let summary = String(format: "%.2f °C", celsius)
            return BLEDecodedValue(summary: summary, importantTitle: "Temperature", importantValue: summary, priority: 5)
        case "2A6F":
            let raw = value.uint16LE(at: 0) ?? 0
            let humidity = Double(raw) / 100.0
            let summary = String(format: "%.2f%%", humidity)
            return BLEDecodedValue(summary: summary, importantTitle: "Humidity", importantValue: summary, priority: 5)
        default:
            if let text = value.printableString {
                return BLEDecodedValue(summary: text, importantTitle: nil, importantValue: nil, priority: 99)
            }
            return BLEDecodedValue(summary: value.hexString, importantTitle: nil, importantValue: nil, priority: 99)
        }
    }

    static func decodeDescriptorValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let data as Data:
            return data.printableString ?? data.hexString
        case let number as NSNumber:
            return number.stringValue
        case let uuid as CBUUID:
            return uuid.uuidString
        case let array as [Any]:
            return array.map { "\($0)" }.joined(separator: ", ")
        case .none:
            return nil
        default:
            return value.map { "\($0)" }
        }
    }

    static func propertyTitles(_ properties: CBCharacteristicProperties) -> [String] {
        var titles: [String] = []
        if properties.contains(.broadcast) { titles.append("broadcast") }
        if properties.contains(.read) { titles.append("read") }
        if properties.contains(.writeWithoutResponse) { titles.append("writeNoRsp") }
        if properties.contains(.write) { titles.append("write") }
        if properties.contains(.notify) { titles.append("notify") }
        if properties.contains(.indicate) { titles.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { titles.append("signedWrite") }
        if properties.contains(.extendedProperties) { titles.append("extended") }
        if properties.contains(.notifyEncryptionRequired) { titles.append("notifyEncrypted") }
        if properties.contains(.indicateEncryptionRequired) { titles.append("indicateEncrypted") }
        return titles
    }

    private static func textValue(_ value: Data, title: String, priority: Int) -> BLEDecodedValue {
        let text = value.printableString ?? value.hexString
        return BLEDecodedValue(summary: text, importantTitle: title, importantValue: text, priority: priority)
    }

    private static func decodeConnectionParameters(_ value: Data) -> BLEDecodedValue {
        let minInterval = value.uint16LE(at: 0).map { Double($0) * 1.25 }
        let maxInterval = value.uint16LE(at: 2).map { Double($0) * 1.25 }
        let latency = value.uint16LE(at: 4)
        let timeout = value.uint16LE(at: 6).map { Double($0) * 10 }
        let parts = [
            minInterval.map { String(format: "min %.1f ms", $0) },
            maxInterval.map { String(format: "max %.1f ms", $0) },
            latency.map { "latency \($0)" },
            timeout.map { String(format: "timeout %.0f ms", $0) }
        ].compactMap { $0 }
        let summary = parts.joined(separator: ", ")
        return BLEDecodedValue(summary: summary, importantTitle: "Connection params", importantValue: summary, priority: 8)
    }

    private static func decodeCurrentTime(_ value: Data) -> BLEDecodedValue {
        guard
            let year = value.uint16LE(at: 0),
            let month = value.byte(at: 2),
            let day = value.byte(at: 3),
            let hour = value.byte(at: 4),
            let minute = value.byte(at: 5),
            let second = value.byte(at: 6)
        else {
            return BLEDecodedValue(summary: value.hexString, importantTitle: nil, importantValue: nil, priority: 99)
        }

        let summary = String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
        return BLEDecodedValue(summary: summary, importantTitle: "Device time", importantValue: summary, priority: 5)
    }

    private static func decodeHeartRate(_ value: Data) -> BLEDecodedValue {
        guard let flags = value.byte(at: 0) else {
            return BLEDecodedValue(summary: value.hexString, importantTitle: nil, importantValue: nil, priority: 99)
        }

        var index = 1
        let bpm: Int
        if flags & 0x01 == 0x01 {
            bpm = Int(value.uint16LE(at: index) ?? 0)
            index += 2
        } else {
            bpm = Int(value.byte(at: index) ?? 0)
            index += 1
        }

        var parts = ["\(bpm) bpm"]
        if flags & 0x08 == 0x08, let energy = value.uint16LE(at: index) {
            parts.append("energy \(energy) kJ")
            index += 2
        }

        if flags & 0x10 == 0x10 {
            var rr: [String] = []
            while let interval = value.uint16LE(at: index) {
                rr.append(String(format: "%.0f ms", Double(interval) / 1024.0 * 1000.0))
                index += 2
            }
            if !rr.isEmpty {
                parts.append("RR \(rr.joined(separator: ", "))")
            }
        }

        let summary = parts.joined(separator: ", ")
        return BLEDecodedValue(summary: summary, importantTitle: "Heart rate", importantValue: "\(bpm) bpm", priority: 5)
    }

    private static func decodePnPID(_ value: Data) -> BLEDecodedValue {
        let source = value.byte(at: 0).map { $0 == 1 ? "Bluetooth SIG" : $0 == 2 ? "USB IF" : "source \($0)" } ?? "unknown"
        let vendorID = value.uint16LE(at: 1) ?? 0
        let productID = value.uint16LE(at: 3) ?? 0
        let version = value.uint16LE(at: 5) ?? 0
        let summary = String(format: "%@ vendor 0x%04X, product 0x%04X, version 0x%04X", source, vendorID, productID, version)
        return BLEDecodedValue(summary: summary, importantTitle: "PnP ID", importantValue: summary, priority: 7)
    }

    private static func decodeShortPayload(_ data: Data) -> String? {
        if let text = data.printableString {
            return text
        }
        if data.count == 1, let byte = data.byte(at: 0) {
            return "\(byte)"
        }
        if data.count == 2, let value = data.uint16LE(at: 0) {
            return "\(value)"
        }
        return nil
    }

    private static func decodeBeacon(from manufacturerData: Data?, companyID: UInt16?) -> BLEBeaconSnapshot? {
        guard
            let manufacturerData,
            companyID == 0x004C,
            manufacturerData.count >= 25,
            manufacturerData.byte(at: 2) == 0x02,
            manufacturerData.byte(at: 3) == 0x15
        else {
            return nil
        }

        let bytes = Array(manufacturerData)
        func hex(_ range: Range<Int>) -> String {
            range.map { String(format: "%02X", bytes[$0]) }.joined()
        }

        let uuid = "\(hex(4..<8))-\(hex(8..<10))-\(hex(10..<12))-\(hex(12..<14))-\(hex(14..<20))"
        let major = (UInt16(bytes[20]) << 8) | UInt16(bytes[21])
        let minor = (UInt16(bytes[22]) << 8) | UInt16(bytes[23])
        let measuredPower = Int(Int8(bitPattern: bytes[24]))

        return BLEBeaconSnapshot(
            type: "iBeacon",
            uuid: uuid,
            major: major,
            minor: minor,
            measuredPower: measuredPower
        )
    }

    private static func appearanceName(_ code: UInt16) -> String {
        let category = Int(code >> 6)
        return appearanceCategories[category] ?? "Appearance category \(category)"
    }

    private static func bodySensorLocation(_ code: Int) -> String {
        switch code {
        case 0: "Other"
        case 1: "Chest"
        case 2: "Wrist"
        case 3: "Finger"
        case 4: "Hand"
        case 5: "Ear lobe"
        case 6: "Foot"
        default: "Unknown"
        }
    }

    private static let standardServices: [String: String] = [
        "1800": "Generic Access",
        "1801": "Generic Attribute",
        "1802": "Immediate Alert",
        "1803": "Link Loss",
        "1804": "Tx Power",
        "1805": "Current Time",
        "1806": "Reference Time Update",
        "1807": "Next DST Change",
        "1808": "Glucose",
        "1809": "Health Thermometer",
        "180A": "Device Information",
        "180D": "Heart Rate",
        "180E": "Phone Alert Status",
        "180F": "Battery",
        "1810": "Blood Pressure",
        "1811": "Alert Notification",
        "1812": "Human Interface Device",
        "1813": "Scan Parameters",
        "1814": "Running Speed and Cadence",
        "1815": "Automation IO",
        "1816": "Cycling Speed and Cadence",
        "1818": "Cycling Power",
        "1819": "Location and Navigation",
        "181A": "Environmental Sensing",
        "181B": "Body Composition",
        "181C": "User Data",
        "181D": "Weight Scale",
        "181E": "Bond Management",
        "181F": "Continuous Glucose Monitoring",
        "1820": "Internet Protocol Support",
        "1821": "Indoor Positioning",
        "1822": "Pulse Oximeter",
        "1823": "HTTP Proxy",
        "1824": "Transport Discovery",
        "1825": "Object Transfer",
        "1826": "Fitness Machine",
        "1827": "Mesh Provisioning",
        "1828": "Mesh Proxy",
        "1829": "Reconnection Configuration"
    ]

    private static let standardCharacteristics: [String: String] = [
        "2A00": "Device Name",
        "2A01": "Appearance",
        "2A04": "Peripheral Preferred Connection Parameters",
        "2A05": "Service Changed",
        "2A07": "Tx Power Level",
        "2A19": "Battery Level",
        "2A1C": "Temperature Measurement",
        "2A23": "System ID",
        "2A24": "Model Number String",
        "2A25": "Serial Number String",
        "2A26": "Firmware Revision String",
        "2A27": "Hardware Revision String",
        "2A28": "Software Revision String",
        "2A29": "Manufacturer Name String",
        "2A2A": "IEEE 11073 Certification Data List",
        "2A2B": "Current Time",
        "2A37": "Heart Rate Measurement",
        "2A38": "Body Sensor Location",
        "2A39": "Heart Rate Control Point",
        "2A50": "PnP ID",
        "2A56": "Digital",
        "2A5B": "Cycling Speed and Cadence Measurement",
        "2A63": "Cycling Power Measurement",
        "2A6E": "Temperature",
        "2A6F": "Humidity",
        "2A9D": "Weight Measurement",
        "2ACC": "Fitness Machine Feature",
        "2ACD": "Treadmill Data",
        "2ACE": "Cross Trainer Data",
        "2AD2": "Indoor Bike Data"
    ]

    private static let standardDescriptors: [String: String] = [
        "2900": "Characteristic Extended Properties",
        "2901": "Characteristic User Description",
        "2902": "Client Characteristic Configuration",
        "2903": "Server Characteristic Configuration",
        "2904": "Characteristic Presentation Format",
        "2905": "Characteristic Aggregate Format"
    ]

    private static let companyNames: [UInt16: String] = [
        0x0006: "Microsoft",
        0x000D: "Texas Instruments",
        0x000F: "Broadcom",
        0x004C: "Apple",
        0x0057: "Garmin",
        0x0059: "Nordic Semiconductor",
        0x0075: "Samsung",
        0x00E0: "Google",
        0x0131: "Sony",
        0x0499: "Ruuvi Innovations"
    ]

    private static let appearanceCategories: [Int: String] = [
        0: "Unknown",
        1: "Phone",
        2: "Computer",
        3: "Watch",
        4: "Clock",
        5: "Display",
        6: "Remote Control",
        7: "Eye-glasses",
        8: "Tag",
        9: "Keyring",
        10: "Media Player",
        11: "Barcode Scanner",
        12: "Thermometer",
        13: "Heart Rate Sensor",
        14: "Blood Pressure",
        15: "Human Interface Device",
        16: "Glucose Meter",
        17: "Running Walking Sensor",
        18: "Cycling",
        19: "Control Device",
        20: "Network Device",
        21: "Sensor",
        22: "Light Fixture",
        23: "Fan",
        24: "HVAC",
        25: "Air Conditioning",
        26: "Humidifier",
        27: "Heating",
        28: "Access Control",
        29: "Motorized Device",
        30: "Power Device",
        31: "Light Source",
        32: "Window Covering",
        33: "Audio Sink",
        34: "Audio Source",
        35: "Motorized Vehicle",
        36: "Domestic Appliance",
        37: "Wearable Audio",
        38: "Aircraft",
        39: "AV Equipment",
        40: "Display Equipment",
        41: "Hearing Aid",
        42: "Gaming",
        43: "Signage"
    ]
}

extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var printableString: String? {
        let encodings: [String.Encoding] = [.utf8, .isoLatin1, .ascii]
        for encoding in encodings {
            guard let value = String(data: self, encoding: encoding) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let printable = trimmed.unicodeScalars.filter { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
            }
            if printable.count == trimmed.unicodeScalars.count {
                return trimmed
            }
        }
        return nil
    }

    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[startIndex + offset]
    }

    func int8(at offset: Int) -> Int8? {
        byte(at: offset).map { Int8(bitPattern: $0) }
    }

    func uint16LE(at offset: Int) -> UInt16? {
        guard let low = byte(at: offset), let high = byte(at: offset + 1) else { return nil }
        return UInt16(low) | (UInt16(high) << 8)
    }

    func int16LE(at offset: Int) -> Int16? {
        uint16LE(at: offset).map { Int16(bitPattern: $0) }
    }
}
