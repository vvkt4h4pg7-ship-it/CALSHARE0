import Foundation
import CoreBluetooth

final class BLETransport: NSObject {
    private let bleQueue = DispatchQueue(label: "com.callshare.ble", qos: .userInitiated)
    private lazy var central = CBCentralManager(delegate: self, queue: bleQueue)

    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var flowCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?

    private var parser = K7Protocol.StreamParser()
    private var audioWriteType: CBCharacteristicWriteType = .withoutResponse

    // Audio never gets permission to enter this queue until the voice-open ACK arrives.
    private var audioTXEnabled = false
    private var audioQueue: [Data] = []
    private let maxAudioQueue = 8
    private var audioDrainScheduled = false

    // A control response is deliberately allowed to complete before another
    // burst of no-response audio is released.
    private var controlWritesOutstanding = 0

    private var audioTXCount = 0
    private var audioRXCount = 0
    private var controlRXCount = 0

    var autoReconnect = true

    var onLog: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onDeviceName: ((String) -> Void)?
    var onControl: ((Data) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onTransportLost: (() -> Void)?

    func start() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            _ = self.central
            guard self.central.state == .poweredOn else {
                self.log("[BLE] Bluetooth not ready state=\(self.central.state.rawValue)")
                return
            }
            self.scanLocked()
        }
    }

    func disconnect() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.audioTXEnabled = false
            self.audioQueue.removeAll(keepingCapacity: true)
            self.parser.reset()

            if let peripheral = self.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            } else {
                self.resetPeripheralLocked()
                self.publishStatus("Disconnected")
            }
        }
    }

    func setAudioTXEnabled(_ enabled: Bool) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.audioTXEnabled = enabled
            if enabled {
                self.log("[BLE] AUDIO TX GATE -> OPEN")
                self.scheduleAudioDrainLocked()
            } else {
                self.audioQueue.removeAll(keepingCapacity: true)
                self.log("[BLE] AUDIO TX GATE -> CLOSED queue=0")
            }
        }
    }

    // MARK: Control

    func sendAnswer() { sendControl(Data([K7Protocol.cmdAnswer]), label: "ANSWER 05") }
    func sendHangup() { sendControl(Data([K7Protocol.cmdHangup]), label: "HANGUP 04") }

    func sendVoiceOpen(reason: String) {
        sendControl(Data([K7Protocol.cmdVoiceOpen]), label: "VOICE_OPEN 0F \(reason)")
    }

    func sendVoiceClose() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.audioTXEnabled = false
            self.audioQueue.removeAll(keepingCapacity: true)
            self.sendControlLocked(Data([K7Protocol.cmdVoiceClose]), label: "VOICE_CLOSE 10")
        }
    }

    func sendMakeCall(number: String, simId: UInt8) {
        sendControl(K7Protocol.makeCallPayload(number: number, simId: simId), label: "MAKE_CALL")
    }

    func sendDTMF(_ value: UInt8) {
        sendControl(K7Protocol.dtmfPayload(value), label: "DTMF")
    }

    func requestDeviceInfo() {
        sendControl(Data([K7Protocol.cmdDevCheck]), label: "DEV_CHECK")
        sendControl(Data([K7Protocol.cmdReadBattery]), label: "BATTERY")
        sendControl(Data([K7Protocol.cmdFirmwareVersion]), label: "FIRMWARE")
        sendControl(Data([K7Protocol.cmdIMEIInfo]), label: "IMEI")
    }

    // MARK: Audio

    func sendAudio(_ amr: Data) {
        guard !amr.isEmpty else { return }

        bleQueue.async { [weak self] in
            guard let self else { return }
            guard self.audioTXEnabled else {
                // Suppressed instead of queued. This is the core handshake rule.
                return
            }
            guard self.peripheral?.state == .connected, self.txCharacteristic != nil else {
                return
            }

            let frame = K7Protocol.audioFrame(amr)

            if self.audioQueue.count >= self.maxAudioQueue {
                self.audioQueue.removeFirst()
                self.log("[BLE] AUDIO TX DROP oldest queue=\(self.audioQueue.count)")
            }
            self.audioQueue.append(frame)
            self.flushAudioLocked()
        }
    }

    // MARK: Internals

    private func scanLocked() {
        central.stopScan()
        publishStatus("Scanning")
        log("[BLE] SCAN service=\(K7Protocol.service.uuidString)")
        central.scanForPeripherals(
            withServices: [K7Protocol.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func sendControl(_ payload: Data, label: String) {
        bleQueue.async { [weak self] in
            self?.sendControlLocked(payload, label: label)
        }
    }

    private func sendControlLocked(_ payload: Data, label: String) {
        guard let peripheral, peripheral.state == .connected, let tx = txCharacteristic else {
            log("[BLE] CONTROL NOT SENT \(label) — GATT TX unavailable")
            return
        }

        let frame = K7Protocol.controlFrame(payload)
        controlWritesOutstanding += 1
        log("[BLE] CTRL TX \(label) \(K7Protocol.hex(frame))")
        peripheral.writeValue(frame, for: tx, type: .withResponse)
    }

    private func flushAudioLocked() {
        guard audioTXEnabled,
              controlWritesOutstanding == 0,
              let peripheral,
              peripheral.state == .connected,
              let tx = txCharacteristic else { return }

        if audioWriteType == .withResponse {
            // A K7 peer should expose write-without-response. This fallback is
            // intentionally one frame at a time and remains bounded.
            guard !audioQueue.isEmpty else { return }
            let frame = audioQueue.removeFirst()
            peripheral.writeValue(frame, for: tx, type: .withResponse)
            audioTXCount += 1
            if audioTXCount == 1 || audioTXCount % 25 == 0 {
                log("[BLE] AUDIO TX(response) #\(audioTXCount) queue=\(audioQueue.count)")
            }
            return
        }

        // Small bounded bursts prevent a long audio flush from starving
        // CONTROL writes on the same GATT characteristic.
        var sent = 0
        while !audioQueue.isEmpty &&
              sent < 3 &&
              peripheral.canSendWriteWithoutResponse {
            let frame = audioQueue.removeFirst()
            peripheral.writeValue(frame, for: tx, type: .withoutResponse)
            audioTXCount += 1
            sent += 1

            if audioTXCount == 1 || audioTXCount % 25 == 0 {
                log("[BLE] AUDIO TX #\(audioTXCount) queue=\(audioQueue.count)")
            }
        }

        if !audioQueue.isEmpty {
            scheduleAudioDrainLocked()
        }
    }

    private func scheduleAudioDrainLocked() {
        guard !audioDrainScheduled else { return }
        audioDrainScheduled = true

        bleQueue.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
            guard let self else { return }
            self.audioDrainScheduled = false
            self.flushAudioLocked()
        }
    }

    private func resetPeripheralLocked() {
        peripheral = nil
        rxCharacteristic = nil
        flowCharacteristic = nil
        txCharacteristic = nil
        audioWriteType = .withoutResponse
        audioTXEnabled = false
        audioQueue.removeAll(keepingCapacity: true)
        parser.reset()
        controlWritesOutstanding = 0
    }

    private func publishStatus(_ value: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(value)
        }
    }

    private func log(_ value: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(value)
        }
    }

    private func scheduleReconnectLocked() {
        guard autoReconnect, peripheral == nil else { return }
        bleQueue.asyncAfter(deadline: .now() + .milliseconds(800)) { [weak self] in
            self?.scanLocked()
        }
    }
}

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("[BLE] STATE \(central.state.rawValue)")
        if central.state == .poweredOn {
            scanLocked()
        } else {
            publishStatus("Bluetooth unavailable")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }

        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()

        onDeviceName?(peripheral.name ?? "IKOS K7")
        publishStatus("Connecting")
        log("[BLE] FOUND \(peripheral.name ?? "IKOS K7") RSSI=\(RSSI.intValue)")

        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        publishStatus("Connected")
        parser.reset()
        log("[BLE] CONNECTED")
        peripheral.discoverServices([K7Protocol.service])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log("[BLE] CONNECT FAIL \(error?.localizedDescription ?? "unknown")")
        resetPeripheralLocked()
        publishStatus("Disconnected")
        onTransportLost?()
        scheduleReconnectLocked()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("[BLE] DISCONNECTED \(error?.localizedDescription ?? "none")")
        resetPeripheralLocked()
        publishStatus("Disconnected")
        onTransportLost?()
        scheduleReconnectLocked()
    }
}

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral,
                     didDiscoverServices error: Error?) {
        guard error == nil else {
            log("[BLE] SERVICE ERROR \(error!.localizedDescription)")
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == K7Protocol.service }) else {
            log("[BLE] K7 SERVICE NOT FOUND")
            return
        }

        log("[BLE] SERVICE READY \(service.uuid.uuidString)")
        peripheral.discoverCharacteristics(
            [K7Protocol.rx, K7Protocol.flow, K7Protocol.tx],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didDiscoverCharacteristicsFor service: CBService,
                     error: Error?) {
        guard error == nil else {
            log("[BLE] CHAR ERROR \(error!.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case K7Protocol.rx:
                rxCharacteristic = characteristic
                log("[BLE] RX 5CB8 props=\(characteristic.properties)")
                peripheral.setNotifyValue(true, for: characteristic)

            case K7Protocol.flow:
                flowCharacteristic = characteristic
                log("[BLE] FLOW 5CB9 props=\(characteristic.properties)")
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }

            case K7Protocol.tx:
                txCharacteristic = characteristic
                if characteristic.properties.contains(.writeWithoutResponse) {
                    audioWriteType = .withoutResponse
                } else if characteristic.properties.contains(.write) {
                    audioWriteType = .withResponse
                }
                log("[BLE] TX 5CBA props=\(characteristic.properties) writeType=\(audioWriteType == .withoutResponse ? "NO_RESPONSE" : "RESPONSE") maxNoResp=\(peripheral.maximumWriteValueLength(for: .withoutResponse))")

            default:
                break
            }
        }

        if rxCharacteristic != nil && txCharacteristic != nil {
            publishStatus("GATT Ready")
            log("[BLE] GATT_READY")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didUpdateNotificationStateFor characteristic: CBCharacteristic,
                     error: Error?) {
        log("[BLE] NOTIFY \(characteristic.uuid.uuidString) enabled=\(characteristic.isNotifying) error=\(error?.localizedDescription ?? "none")")
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didWriteValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        guard characteristic.uuid == K7Protocol.tx else { return }
        controlWritesOutstanding = max(0, controlWritesOutstanding - 1)

        if let error {
            log("[BLE] CTRL WRITE ERROR \(error.localizedDescription)")
        } else {
            log("[BLE] CTRL WRITE OK outstanding=\(controlWritesOutstanding)")
        }

        flushAudioLocked()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushAudioLocked()
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didUpdateValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        guard error == nil, let data = characteristic.value else {
            log("[BLE] RX ERROR \(error?.localizedDescription ?? "no data")")
            return
        }

        if characteristic.uuid == K7Protocol.flow {
            log("[BLE] FLOW RX \(K7Protocol.hex(data))")
            return
        }

        guard characteristic.uuid == K7Protocol.rx else { return }

        for parsed in parser.feed(data) {
            if parsed.channel == K7Protocol.audioChannel {
                audioRXCount += 1
                if audioRXCount == 1 || audioRXCount % 25 == 0 {
                    log("[BLE] AUDIO RX #\(audioRXCount) len=\(parsed.payload.count)")
                }
                onAudio?(parsed.payload)
            } else if parsed.channel == 2 {
                controlRXCount += 1
                if controlRXCount <= 5 || controlRXCount % 25 == 0 {
                    log("[BLE] CONTROL RX #\(controlRXCount) \(K7Protocol.hex(parsed.payload))")
                }
                onControl?(parsed.payload)
            }
        }
    }
}
