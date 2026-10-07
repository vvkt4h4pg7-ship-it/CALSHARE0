import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var bleStatus = "Starting"
    @Published var deviceName = "-"
    @Published var callStatus = CallSession.State.idle.rawValue
    @Published var voiceStatus = "CLOSED"
    @Published var number = ""
    @Published var callerName = ""
    @Published var dialString = ""
    @Published var logs: [String] = []

    @Published var simSlot = 0
    @Published var speakerDefault = true

    let ble: BLETransport
    let callKit: CallKitCoordinator
    let audio: AudioEngineBridge
    let session: CallSession

    private var started = false

    init() {
        ble = BLETransport()
        callKit = CallKitCoordinator()
        audio = AudioEngineBridge()
        session = CallSession(ble: ble, callKit: callKit, audio: audio)

        ble.onLog = { [weak self] message in
            Task { @MainActor in self?.appendLog(message) }
        }
        ble.onStatus = { [weak self] status in
            Task { @MainActor in self?.bleStatus = status }
        }
        ble.onDeviceName = { [weak self] name in
            Task { @MainActor in self?.deviceName = name }
        }
        ble.onControl = { [weak self] payload in
            Task { @MainActor in self?.session.handleControl(payload) }
        }
        ble.onAudio = { [weak self] packet in
            self?.audio.receiveAMR(packet)
        }

        ble.onTransportLost = { [weak self] in
            Task { @MainActor in self?.session.transportLost() }
        }

        audio.onStatus = { [weak self] status in
            Task { @MainActor in
                self?.voiceStatus = status
                self?.appendLog(status)
            }
        }
        audio.onAMRPacket = { [weak self] packet in
            self?.ble.sendAudio(packet)
        }

        session.onLog = { [weak self] message in
            self?.appendLog(message)
        }
        session.onStateChanged = { [weak self] state in
            self?.callStatus = state.rawValue
        }
        session.onCallNumberChanged = { [weak self] number, name in
            self?.number = number
            self?.callerName = name
        }

        callKit.onLog = { [weak self] message in
            Task { @MainActor in self?.appendLog(message) }
        }
            callKit.onPrepareAudio = { [weak self] in
            Task { @MainActor in self?.session.prepareAudio() }
        }
        callKit.onAnswer = { [weak self] in
            Task { @MainActor in self?.session.answerRequested() }
        }
        callKit.onStart = { [weak self] _ in
            Task { @MainActor in self?.session.outgoingCallActionStarted() }
        }
        callKit.onEnd = { [weak self] in
            Task { @MainActor in self?.session.endRequested() }
        }
        callKit.onAudioActivated = { [weak self] in
            Task { @MainActor in self?.session.audioSessionActivated() }
        }
        callKit.onAudioDeactivated = { [weak self] in
            Task { @MainActor in self?.session.audioSessionDeactivated() }
        }
        callKit.onMute = { [weak self] muted in
            self?.audio.setMuted(muted)
        }
        callKit.onDTMF = { [weak self] digits in
            self?.sendDTMF(digits)
        }

        audio.setSpeakerDefault(speakerDefault)
    }

    func start() {
        guard !started else { return }
        started = true
        appendLog("[APP] CALLSHARE R0 START")
        appendLog("[APP] BLE control/audio transport separated")
        ble.start()
    }

    func makeCall() {
        let cleaned = dialString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        session.makeCall(number: cleaned, simId: UInt8(simSlot))
    }

    func endCall() {
        callKit.endCurrentCall()
    }

    func tap(_ digit: String) {
        if session.state == .audio {
            sendDTMF(digit)
        } else {
            dialString.append(digit)
        }
    }

    func backspace() {
        guard session.state == .idle else { return }
        guard !dialString.isEmpty else { return }
        dialString.removeLast()
    }

    func disconnectBLE() {
        ble.disconnect()
    }

    func restartBLE() {
        ble.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.ble.start()
        }
    }

    func clearLog() {
        logs.removeAll()
    }

    func sendDTMF(_ digits: String) {
        for scalar in digits {
            guard "0123456789*#".contains(scalar) else { continue }
            ble.sendDTMF(UInt8(String(scalar).utf8.first!))
        }
    }

    private func appendLog(_ message: String) {
        let formatter = ISO8601DateFormatter()
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        if logs.count > 600 {
            logs.removeFirst(logs.count - 600)
        }
    }
}

