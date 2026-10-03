@preconcurrency import CoreBluetooth
import Combine
import Foundation

@MainActor
final class BLEScanner: NSObject, ObservableObject {
    @Published private(set) var devices: [BLEDevice] = []
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var authorization: CBManagerAuthorization = .notDetermined
    @Published private(set) var isScanning = false
    @Published var autoInterrogate = true
    @Published var selectedDeviceID: UUID?
    @Published private(set) var statusMessage = "Инициализация Bluetooth..."

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var queue: [UUID] = []
    private var activePeripheralID: UUID?
    private var interrogationTimestamps: [UUID: Date] = [:]
    private var shouldScanWhenPoweredOn = true
    private var finishTimer: Timer?
    private var rssiTimer: Timer?

    private let reinterrogationCooldown: TimeInterval = 45
    private let interrogationDwell: TimeInterval = 5

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        authorization = CBCentralManager.authorization
    }

    var selectedDevice: BLEDevice? {
        if let selectedDeviceID, let device = devices.first(where: { $0.id == selectedDeviceID }) {
            return device
        }
        return devices.first
    }

    var activeDevice: BLEDevice? {
        guard let activePeripheralID else { return nil }
        return devices.first(where: { $0.id == activePeripheralID })
    }

    func toggleScanning() {
        isScanning ? stopScanning() : startScanning()
    }

    func startScanning() {
        shouldScanWhenPoweredOn = true
        guard central.state == .poweredOn else {
            statusMessage = stateTitle(central.state)
            return
        }

        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
        statusMessage = "Сканирую BLE advertising в реальном времени"
    }

    func stopScanning() {
        shouldScanWhenPoweredOn = false
        central.stopScan()
        isScanning = false
        queue.removeAll()
        cancelActiveConnection()
        statusMessage = "Сканирование остановлено"
    }

    func clearDevices() {
        queue.removeAll()
        cancelActiveConnection()
        devices.removeAll()
        peripherals.removeAll()
        selectedDeviceID = nil
        statusMessage = "Список очищен"
    }

    func select(_ device: BLEDevice) {
        selectedDeviceID = device.id
    }

    func interrogate(_ device: BLEDevice) {
        enqueue(device.id, force: true)
    }

    func calibrateSelectedAtOneMeter() {
        guard let selectedDeviceID else { return }
        updateDevice(selectedDeviceID) { device in
            let calibrated = Int(device.smoothedRSSI.rounded())
            device.calibratedRSSIAtOneMeter = calibrated
            device.upsertImportant(BLEImportantField(
                title: "1 m reference",
                value: "\(calibrated) dBm",
                source: "Calibration",
                priority: 0
            ))
            device.addEvent("Калибровка", "RSSI на 1 м: \(calibrated) dBm")
        }
    }

    private func handleStateUpdate(_ central: CBCentralManager) {
        bluetoothState = central.state
        authorization = CBCentralManager.authorization

        switch central.state {
        case .poweredOn:
            statusMessage = "Bluetooth готов"
            if shouldScanWhenPoweredOn {
                startScanning()
            }
        case .poweredOff, .unauthorized, .unsupported, .resetting, .unknown:
            isScanning = false
            queue.removeAll()
            statusMessage = stateTitle(central.state)
        @unknown default:
            isScanning = false
            statusMessage = "Неизвестное состояние Bluetooth"
        }
    }

    private func handleDiscovery(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        let id = peripheral.identifier
        let now = Date()
        peripherals[id] = peripheral
        peripheral.delegate = self

        let freshAdvertisement = BLEDecoder.advertisementSnapshot(from: advertisementData)
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].peripheralName = peripheral.name
            devices[index].lastSeen = now
            devices[index].appendRSSI(rssi.intValue)
            devices[index].advertisement = merge(old: devices[index].advertisement, fresh: freshAdvertisement)
            for field in BLEDecoder.advertisementFields(from: devices[index].advertisement, rssi: rssi.intValue) {
                devices[index].upsertImportant(field)
            }
            updateDistanceField(for: index)
        } else {
            var device = BLEDevice(
                id: id,
                peripheralName: peripheral.name,
                rssi: rssi.intValue,
                rssiSamples: [rssi.intValue],
                firstSeen: now,
                lastSeen: now,
                advertisement: freshAdvertisement,
                connectionState: .discovered,
                services: [],
                importantFields: [],
                events: [],
                readCount: 0,
                notifyCount: 0,
                errorCount: 0,
                calibratedRSSIAtOneMeter: nil,
                radarAngle: DistanceEstimator.stableAngle(for: id)
            )
            for field in BLEDecoder.advertisementFields(from: freshAdvertisement, rssi: rssi.intValue) {
                device.upsertImportant(field)
            }
            device.upsertImportant(distanceField(for: device))
            device.addEvent("Обнаружено", "RSSI \(rssi.intValue) dBm")
            devices.append(device)
            if selectedDeviceID == nil {
                selectedDeviceID = id
            }
        }

        devices.sort { lhs, rhs in
            if lhs.connectionState == .interrogating { return true }
            if rhs.connectionState == .interrogating { return false }
            return lhs.smoothedRSSI > rhs.smoothedRSSI
        }

        if autoInterrogate, freshAdvertisement.isConnectable ?? true {
            enqueue(id, force: false)
        }
    }

    private func enqueue(_ id: UUID, force: Bool) {
        guard central.state == .poweredOn, peripherals[id] != nil else { return }
        if activePeripheralID == id || queue.contains(id) { return }

        if !force, let last = interrogationTimestamps[id], Date().timeIntervalSince(last) < reinterrogationCooldown {
            return
        }

        if let device = devices.first(where: { $0.id == id }), !device.isConnectable, !force {
            return
        }

        queue.append(id)
        updateDevice(id) { device in
            if device.connectionState == .discovered || device.connectionState == .failed {
                device.connectionState = .queued
            }
        }
        connectNextIfIdle()
    }

    private func connectNextIfIdle() {
        guard activePeripheralID == nil, central.state == .poweredOn, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let peripheral = peripherals[id] else {
            connectNextIfIdle()
            return
        }

        activePeripheralID = id
        peripheral.delegate = self
        updateDevice(id) { device in
            device.connectionState = .connecting
            device.addEvent("Подключение", "CoreBluetooth connect")
        }
        statusMessage = "Подключаюсь к \(deviceName(for: id))"

        if peripheral.state == .connected {
            handleConnected(peripheral)
        } else {
            central.connect(peripheral, options: nil)
        }
    }

    private func cancelActiveConnection() {
        finishTimer?.invalidate()
        finishTimer = nil
        rssiTimer?.invalidate()
        rssiTimer = nil

        guard let activePeripheralID, let peripheral = peripherals[activePeripheralID] else {
            activePeripheralID = nil
            return
        }

        if peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        self.activePeripheralID = nil
    }

    private func handleConnected(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        activePeripheralID = id
        peripheral.delegate = self
        updateDevice(id) { device in
            device.connectionState = .interrogating
            device.addEvent("Подключено", "Discover all services")
        }
        statusMessage = "Читаю сервисы \(deviceName(for: id))"
        peripheral.discoverServices(nil)
        startRSSIPolling(peripheral)
        scheduleFinish(for: peripheral)
    }

    private func finishInterrogation(for peripheral: CBPeripheral) {
        guard activePeripheralID == peripheral.identifier else { return }
        interrogationTimestamps[peripheral.identifier] = Date()
        finishTimer?.invalidate()
        finishTimer = nil
        rssiTimer?.invalidate()
        rssiTimer = nil

        updateDevice(peripheral.identifier) { device in
            device.connectionState = .disconnecting
            device.addEvent("Финиш", "Отключаюсь после чтения")
        }

        if peripheral.state == .disconnected {
            handleDisconnected(peripheral, error: nil)
        } else {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func handleDisconnected(_ peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        updateDevice(id) { device in
            device.connectionState = error == nil ? .discovered : .failed
            if let error {
                device.errorCount += 1
                device.addEvent("Отключено с ошибкой", error.localizedDescription)
            } else {
                device.addEvent("Отключено", "Готов к следующему устройству")
            }
        }
        if activePeripheralID == id {
            activePeripheralID = nil
        }
        statusMessage = isScanning ? "Сканирую и обрабатываю очередь" : "Готово"
        connectNextIfIdle()
    }

    private func scheduleFinish(for peripheral: CBPeripheral) {
        finishTimer?.invalidate()
        finishTimer = Timer.scheduledTimer(withTimeInterval: interrogationDwell, repeats: false) { [weak self, weak peripheral] _ in
            guard let self, let peripheral else { return }
            Task { @MainActor in
                self.finishInterrogation(for: peripheral)
            }
        }
    }

    private func startRSSIPolling(_ peripheral: CBPeripheral) {
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak peripheral] _ in
            peripheral?.readRSSI()
        }
        peripheral.readRSSI()
    }

    private func updateDevice(_ id: UUID, _ update: (inout BLEDevice) -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        update(&devices[index])
        updateDistanceField(for: index)
    }

    private func updateDistanceField(for index: Int) {
        guard devices.indices.contains(index) else { return }
        devices[index].upsertImportant(distanceField(for: devices[index]))
    }

    private func distanceField(for device: BLEDevice) -> BLEImportantField {
        let distance = device.distance
        let detail = "\(distance.title), confidence \(distance.confidenceTitle), \(distance.reference)"
        return BLEImportantField(title: "Estimated distance", value: detail, source: "Radar", priority: 0)
    }

    private func merge(old: BLEAdvertisementSnapshot, fresh: BLEAdvertisementSnapshot) -> BLEAdvertisementSnapshot {
        BLEAdvertisementSnapshot(
            localName: fresh.localName ?? old.localName,
            manufacturerCompanyID: fresh.manufacturerCompanyID ?? old.manufacturerCompanyID,
            manufacturerName: fresh.manufacturerName ?? old.manufacturerName,
            manufacturerDataHex: fresh.manufacturerDataHex ?? old.manufacturerDataHex,
            serviceUUIDs: fresh.serviceUUIDs.isEmpty ? old.serviceUUIDs : fresh.serviceUUIDs,
            solicitedServiceUUIDs: fresh.solicitedServiceUUIDs.isEmpty ? old.solicitedServiceUUIDs : fresh.solicitedServiceUUIDs,
            overflowServiceUUIDs: fresh.overflowServiceUUIDs.isEmpty ? old.overflowServiceUUIDs : fresh.overflowServiceUUIDs,
            serviceData: fresh.serviceData.isEmpty ? old.serviceData : fresh.serviceData,
            txPower: fresh.txPower ?? old.txPower,
            isConnectable: fresh.isConnectable ?? old.isConnectable,
            beacon: fresh.beacon ?? old.beacon,
            rawKeys: fresh.rawKeys.isEmpty ? old.rawKeys : fresh.rawKeys
        )
    }

    private func deviceName(for id: UUID) -> String {
        devices.first(where: { $0.id == id })?.displayName ?? id.uuidString.prefix(8).description
    }

    private func stateTitle(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: "Bluetooth state unknown"
        case .resetting: "Bluetooth resetting"
        case .unsupported: "BLE не поддерживается на этом устройстве"
        case .unauthorized: "Нет разрешения на Bluetooth"
        case .poweredOff: "Bluetooth выключен"
        case .poweredOn: "Bluetooth готов"
        @unknown default: "Unknown Bluetooth state"
        }
    }
}

extension BLEScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleStateUpdate(central)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        handleDiscovery(peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        handleConnected(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        updateDevice(peripheral.identifier) { device in
            device.connectionState = .failed
            device.errorCount += 1
            device.addEvent("Ошибка подключения", error?.localizedDescription ?? "Unknown error")
        }
        if activePeripheralID == peripheral.identifier {
            activePeripheralID = nil
        }
        connectNextIfIdle()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDisconnected(peripheral, error: error)
    }
}

extension BLEScanner: CBPeripheralDelegate {
    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        updateDevice(peripheral.identifier) { device in
            device.peripheralName = peripheral.name
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        updateDevice(peripheral.identifier) { device in
            device.appendRSSI(RSSI.intValue)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            updateDevice(peripheral.identifier) { device in
                device.errorCount += 1
                device.addEvent("Services error", error.localizedDescription)
            }
            scheduleFinish(for: peripheral)
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            updateDevice(peripheral.identifier) { device in
                device.addEvent("Services", "No GATT services exposed")
            }
            scheduleFinish(for: peripheral)
            return
        }

        updateDevice(peripheral.identifier) { device in
            device.addEvent("Services", "\(services.count) services")
        }

        for service in services {
            let snapshot = BLEServiceSnapshot(
                uuid: service.uuid.uuidString,
                name: BLEDecoder.serviceName(service.uuid),
                isPrimary: service.isPrimary,
                characteristics: []
            )
            updateDevice(peripheral.identifier) { device in
                device.upsertService(snapshot)
            }
            peripheral.discoverCharacteristics(nil, for: service)
        }

        scheduleFinish(for: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            updateDevice(peripheral.identifier) { device in
                device.errorCount += 1
                device.addEvent("Characteristics error", "\(BLEDecoder.serviceName(service.uuid)): \(error.localizedDescription)")
            }
            return
        }

        guard let characteristics = service.characteristics else { return }

        updateDevice(peripheral.identifier) { device in
            device.updateService(uuid: service.uuid.uuidString) { serviceSnapshot in
                for characteristic in characteristics {
                    serviceSnapshot.upsertCharacteristic(BLECharacteristicSnapshot(
                        uuid: characteristic.uuid.uuidString,
                        name: BLEDecoder.characteristicName(characteristic.uuid),
                        properties: BLEDecoder.propertyTitles(characteristic.properties),
                        rawValueHex: nil,
                        decodedValue: nil,
                        lastUpdated: nil,
                        isNotifying: characteristic.isNotifying,
                        descriptors: []
                    ))
                }
            }
        }

        for characteristic in characteristics {
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            peripheral.discoverDescriptors(for: characteristic)
        }

        scheduleFinish(for: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            updateDevice(peripheral.identifier) { device in
                device.errorCount += 1
                device.addEvent("Read error", "\(BLEDecoder.characteristicName(characteristic.uuid)): \(error.localizedDescription)")
            }
            return
        }

        guard let value = characteristic.value else { return }
        let decoded = BLEDecoder.decodeCharacteristic(uuid: characteristic.uuid, value: value)
        let serviceUUID = characteristic.service?.uuid.uuidString

        updateDevice(peripheral.identifier) { device in
            if characteristic.isNotifying {
                device.notifyCount += 1
            } else {
                device.readCount += 1
            }

            if let serviceUUID {
                device.updateService(uuid: serviceUUID) { service in
                    service.updateCharacteristic(uuid: characteristic.uuid.uuidString) { snapshot in
                        snapshot.rawValueHex = value.hexString
                        snapshot.decodedValue = decoded.summary
                        snapshot.lastUpdated = Date()
                        snapshot.isNotifying = characteristic.isNotifying
                    }
                }
            }

            if let title = decoded.importantTitle, let importantValue = decoded.importantValue {
                device.upsertImportant(BLEImportantField(
                    title: title,
                    value: importantValue,
                    source: BLEDecoder.characteristicName(characteristic.uuid),
                    priority: decoded.priority
                ))
            }
            device.addEvent("Value", "\(BLEDecoder.characteristicName(characteristic.uuid)): \(decoded.summary)")
        }

        scheduleFinish(for: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            updateDevice(peripheral.identifier) { device in
                device.errorCount += 1
                device.addEvent("Descriptor error", error.localizedDescription)
            }
            return
        }

        guard let descriptors = characteristic.descriptors, let serviceUUID = characteristic.service?.uuid.uuidString else { return }

        updateDevice(peripheral.identifier) { device in
            device.updateService(uuid: serviceUUID) { service in
                service.updateCharacteristic(uuid: characteristic.uuid.uuidString) { snapshot in
                    for descriptor in descriptors {
                        snapshot.upsertDescriptor(BLEDescriptorSnapshot(
                            uuid: descriptor.uuid.uuidString,
                            name: BLEDecoder.descriptorName(descriptor.uuid),
                            value: BLEDecoder.decodeDescriptorValue(descriptor.value)
                        ))
                    }
                }
            }
        }

        for descriptor in descriptors {
            peripheral.readValue(for: descriptor)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard error == nil, let characteristic = descriptor.characteristic, let serviceUUID = characteristic.service?.uuid.uuidString else { return }

        updateDevice(peripheral.identifier) { device in
            device.updateService(uuid: serviceUUID) { service in
                service.updateCharacteristic(uuid: characteristic.uuid.uuidString) { snapshot in
                    snapshot.upsertDescriptor(BLEDescriptorSnapshot(
                        uuid: descriptor.uuid.uuidString,
                        name: BLEDecoder.descriptorName(descriptor.uuid),
                        value: BLEDecoder.decodeDescriptorValue(descriptor.value)
                    ))
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            updateDevice(peripheral.identifier) { device in
                device.errorCount += 1
                device.addEvent("Notify error", "\(BLEDecoder.characteristicName(characteristic.uuid)): \(error.localizedDescription)")
            }
            return
        }

        guard let serviceUUID = characteristic.service?.uuid.uuidString else { return }
        updateDevice(peripheral.identifier) { device in
            device.updateService(uuid: serviceUUID) { service in
                service.updateCharacteristic(uuid: characteristic.uuid.uuidString) { snapshot in
                    snapshot.isNotifying = characteristic.isNotifying
                }
            }
            if characteristic.isNotifying {
                device.addEvent("Notify", "\(BLEDecoder.characteristicName(characteristic.uuid)) subscribed")
            }
        }
    }
}
