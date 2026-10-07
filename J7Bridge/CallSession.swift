import Foundation

@MainActor
final class CallSession {
    enum State: String {
        case idle = "IDLE"
        case ringing = "RINGING"
        case answering = "ANSWERING"
        case activeWaitingVoice = "ACTIVE / WAIT VOICE"
        case activeWaitingAudio = "ACTIVE / WAIT AUDIO"
        case audio = "AUDIO"
        case dialing = "DIALING"
        case ending = "ENDING"
    }

    private let ble: BLETransport
    private let callKit: CallKitCoordinator
    private let audio: AudioEngineBridge

    private(set) var state: State = .idle
    private(set) var number = ""
    private(set) var callerName = ""

    private var voiceAcked = false
    private var callKitAudioActive = false
    private var answerSent = false
    private var voiceOpenAttempts = 0
    private var voiceRetryTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var outgoingSIMID: UInt8 = 0

    var onLog: ((String) -> Void)?
    var onStateChanged: ((State) -> Void)?
    var onCallNumberChanged: ((String, String) -> Void)?

    init(ble: BLETransport, callKit: CallKitCoordinator, audio: AudioEngineBridge) {
        self.ble = ble
        self.callKit = callKit
        self.audio = audio
    }

    func incoming(number: String, callerName: String?) {
        guard state == .idle else {
            log("[CALL] INCOMING ignored state=\(state.rawValue)")
            return
        }

        sessionID = UUID()
        self.number = number
        self.callerName = callerName ?? ""
        voiceAcked = false
        callKitAudioActive = false
        answerSent = false
        voiceOpenAttempts = 0

        transition(.ringing)
        onCallNumberChanged?(number, self.callerName)
        log("[CALL] INCOMING session=\(sessionID.uuidString) number=\(number)")
        callKit.reportIncoming(number: number, callerName: callerName)
    }

    func prepareAudio() {
        audio.prepareForCallAudio()
        log("[VOICE] AUDIO PREPARE requested")
    }

    func answerRequested() {
        guard state == .ringing || state == .answering || state == .activeWaitingVoice else {
            log("[CALL] ANSWER ignored state=\(state.rawValue)")
            return
        }

        if !answerSent {
            answerSent = true
            transition(.answering)

            // Prepare local audio first, then request the remote GSM answer.
            audio.prepareForCallAudio()
            ble.sendAnswer()

            // Start the remote handshake immediately. Crucially, AUDIO TX
            // remains closed until the K7 0F event/ACK arrives.
            sendVoiceOpenAttempt(reason: "ANSWER_PREWARM")

            // Fulfill Answer now so CallKit can activate its audio session
            // without waiting for another BLE round-trip.
            callKit.fulfillPendingAnswer()
            log("[CALL] ANSWER -> 05 sent; CallKit answer fulfilled; waiting K7")
        }
    }

    func makeCall(number: String, simId: UInt8) {
        guard state == .idle else { return }

        sessionID = UUID()
        self.number = number
        callerName = ""
        voiceAcked = false
        callKitAudioActive = false
        answerSent = false
        voiceOpenAttempts = 0
        outgoingSIMID = simId

        transition(.dialing)
        onCallNumberChanged?(number, "")
        log("[CALL] OUTGOING session=\(sessionID.uuidString) number=\(number)")

        callKit.startOutgoing(number: number)
    }

    func outgoingCallActionStarted() {
        guard state == .dialing else { return }
        ble.sendMakeCall(number: number, simId: outgoingSIMID)
        log("[CALL] MAKE_CALL sent sim=\(outgoingSIMID)")
    }

    func handleControl(_ payload: Data) {
        guard let opcode = payload.first else { return }

        switch opcode {
        case K7Protocol.evtReceiveCall:
            let incomingNumber = K7Protocol.decodeIncomingNumber(payload)
            incoming(number: incomingNumber, callerName: nil)

        case K7Protocol.evtAnswer:
            log("[CALL] K7 ANSWER EVENT")
            answerSent = true

            let wasOutgoing = (state == .dialing)
            if state == .answering || state == .dialing {
                transition(.activeWaitingVoice)
            }

            if wasOutgoing {
                callKit.reportOutgoingConnected()
                sendVoiceOpenAttempt(reason: "OUTGOING_ACTIVE")
            } else if !voiceAcked {
                sendVoiceOpenAttempt(reason: "K7_ACTIVE")
            }

        case K7Protocol.evtVoiceOpen:
            guard state != .idle else { return }
            voiceAcked = true
            voiceOpenAttempts = 0
            voiceRetryTask?.cancel()
            voiceRetryTask = nil

            ble.setAudioTXEnabled(true)
            audio.setTXEnabled(true)

            log("[VOICE] K7 ACK 0F -> AUDIO TX ENABLED")

            if callKitAudioActive {
                startAudioIfReady()
            } else {
                transition(.activeWaitingAudio)
                log("[VOICE] WAIT CallKit AUDIO SESSION")
            }

        case K7Protocol.evtVoiceClose:
            log("[VOICE] K7 CLOSE EVENT")
            voiceAcked = false
            ble.setAudioTXEnabled(false)
            audio.setTXEnabled(false)
            audio.stop()

        case K7Protocol.evtReceiveCallEnd, K7Protocol.evtHangup:
            finishRemoteEnd()

        case K7Protocol.evtMakeCall:
            log("[CALL] K7 MAKE_CALL EVENT")

        case K7Protocol.evtReadBattery,
             K7Protocol.evtFirmwareVersion,
             K7Protocol.evtIMEIInfo,
             K7Protocol.evtDevCheck:
            onLog?("[K7] CONTROL opcode=\(String(format: "%02X", opcode)) payload=\(K7Protocol.hex(payload))")

        default:
            onLog?("[K7] UNHANDLED opcode=\(String(format: "%02X", opcode)) payload=\(K7Protocol.hex(payload))")
        }
    }

    func audioSessionActivated() {
        callKitAudioActive = true
        log("[VOICE] CALLKIT AUDIO ACTIVE")
        if voiceAcked {
            startAudioIfReady()
        } else {
            transition(.activeWaitingVoice)
            log("[VOICE] WAIT K7 VOICE_OPEN ACK")
        }
    }

    func transportLost() {
        guard state != .idle else { return }

        voiceRetryTask?.cancel()
        voiceRetryTask = nil
        ble.setAudioTXEnabled(false)
        audio.setTXEnabled(false)
        audio.stop()
        callKit.reportRemoteEnd(reason: .failed)
        resetToIdle()
        log("[CALL] BLE TRANSPORT LOST -> CALL FAILED")
    }

    func audioSessionDeactivated() {
        callKitAudioActive = false
        voiceRetryTask?.cancel()
        audio.stop()
        ble.setAudioTXEnabled(false)
        audio.setTXEnabled(false)
        log("[VOICE] CALLKIT AUDIO DEACTIVATED")
    }

    func endRequested() {
        guard state != .idle else { return }

        transition(.ending)
        voiceRetryTask?.cancel()
        voiceRetryTask = nil

        // Close the audio gate BEFORE sending hangup; there can be no tail of
        // stale microphone frames after a local hangup.
        ble.setAudioTXEnabled(false)
        audio.setTXEnabled(false)
        audio.stop()

        ble.sendVoiceClose()
        ble.sendHangup()

        callKit.clearCall()
        resetToIdle()
        log("[CALL] LOCAL END -> voice closed + hangup")
    }

    private func finishRemoteEnd() {
        guard state != .idle else { return }

        voiceRetryTask?.cancel()
        voiceRetryTask = nil

        ble.setAudioTXEnabled(false)
        audio.setTXEnabled(false)
        audio.stop()

        callKit.reportRemoteEnd()
        resetToIdle()
        log("[CALL] REMOTE END")
    }

    private func sendVoiceOpenAttempt(reason: String) {
        guard state != .idle else { return }

        voiceOpenAttempts += 1
        ble.sendVoiceOpen(reason: reason)
        log("[VOICE] OPEN attempt #\(voiceOpenAttempts) reason=\(reason)")

        guard voiceOpenAttempts < 4 else { return }

        let currentSession = sessionID
        let delayMs = [200, 400, 800][voiceOpenAttempts - 1]

        voiceRetryTask?.cancel()
        voiceRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled, let self else { return }
            guard self.sessionID == currentSession,
                  !self.voiceAcked,
                  self.state != .idle else { return }

            self.sendVoiceOpenAttempt(reason: "RETRY")
        }
    }

    private func startAudioIfReady() {
        guard state != .idle, voiceAcked, callKitAudioActive else { return }
        transition(.audio)
        audio.start()
        log("[VOICE] AUDIO START -> K7 ACK + CallKit ACTIVE")
    }

    private func transition(_ newState: State) {
        state = newState
        onStateChanged?(newState)
    }

    private func resetToIdle() {
        voiceAcked = false
        callKitAudioActive = false
        answerSent = false
        voiceOpenAttempts = 0
        number = ""
        callerName = ""
        transition(.idle)
        onCallNumberChanged?("", "")
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}
