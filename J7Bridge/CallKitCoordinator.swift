import Foundation
import CallKit
import AVFoundation

final class CallKitCoordinator: NSObject {
    private let provider: CXProvider
    private let callKitQueue = DispatchQueue(label: "com.callshare.callkit", qos: .userInitiated)

    private(set) var currentUUID: UUID?
    private var pendingAnswerAction: CXAnswerCallAction?
    private var pendingStartAction: CXStartCallAction?

    var onStart: ((String) -> Void)?
    var onAnswer: (() -> Void)?
    var onEnd: (() -> Void)?
    var onMute: ((Bool) -> Void)?
    var onDTMF: ((String) -> Void)?
    var onPrepareAudio: (() -> Void)?
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?
    var onLog: ((String) -> Void)?

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "CALLSHARE")
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)

        super.init()
        provider.setDelegate(self, queue: callKitQueue)
    }

    func reportIncoming(number: String, callerName: String?) {
        guard currentUUID == nil else {
            log("[CALLKIT] incoming ignored: call already exists")
            return
        }

        let uuid = UUID()
        currentUUID = uuid

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsDTMF = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        log("[CALLKIT] REPORT INCOMING uuid=\(uuid.uuidString)")
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                self?.log("[CALLKIT] REPORT ERROR \(error.localizedDescription)")
                self?.currentUUID = nil
            } else {
                self?.log("[CALLKIT] INCOMING UI READY")
            }
        }
    }

    func startOutgoing(number: String) {
        let uuid = UUID()
        currentUUID = uuid

        let handle = CXHandle(type: .phoneNumber, value: number)
        let action = CXStartCallAction(call: uuid, handle: handle)
        pendingStartAction = action

        let transaction = CXTransaction(action: action)
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
        CXCallController().request(transaction) { [weak self] error in
            if let error {
                self?.log("[CALLKIT] OUTGOING REQUEST ERROR \(error.localizedDescription)")
                self?.currentUUID = nil
            } else {
                self?.log("[CALLKIT] OUTGOING REQUEST SENT")
            }
        }
    }

    func reportOutgoingConnecting() {
        guard let uuid = currentUUID else { return }
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
        log("[CALLKIT] OUTGOING CONNECTING")
    }

    func reportOutgoingConnected() {
        guard let uuid = currentUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        log("[CALLKIT] OUTGOING CONNECTED")
    }

    func endCurrentCall() {
        guard let uuid = currentUUID else { return }
        requestEnd(uuid: uuid)
    }

    func fulfillPendingAnswer() {
        pendingAnswerAction?.fulfill()
        pendingAnswerAction = nil
    }

    func clearCall() {
        pendingAnswerAction = nil
        pendingStartAction = nil
        currentUUID = nil
    }

    func reportRemoteEnd(reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = currentUUID else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        clearCall()
    }

    private func requestEnd(uuid: UUID) {
        let transaction = CXTransaction(action: CXEndCallAction(call: uuid))
        CXCallController().request(transaction) { [weak self] error in
            if let error {
                self?.log("[CALLKIT] END REQUEST ERROR \(error.localizedDescription)")
            } else {
                self?.log("[CALLKIT] END REQUEST SENT")
            }
        }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(message)
        }
    }
}

extension CallKitCoordinator: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        pendingAnswerAction = nil
        pendingStartAction = nil
        currentUUID = nil
        log("[CALLKIT] PROVIDER RESET")
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        pendingStartAction = action
        let number = action.handle.value
        log("[CALLKIT] START ACTION \(number)")
        onStart?(number)
        action.fulfill()
        pendingStartAction = nil
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        pendingAnswerAction = action
        log("[CALLKIT] ANSWER ACTION")

        // Prepare BEFORE CallKit activates the session. We do not setActive(true).
        onPrepareAudio?()
        onAnswer?()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        log("[CALLKIT] END ACTION")
        onEnd?()
        action.fulfill()
        pendingAnswerAction = nil
    }

    func provider(_ provider: CXProvider,
                  perform action: CXSetMutedCallAction) {
        onMute?(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider,
                  perform action: CXPlayDTMFCallAction) {
        onDTMF?(action.digits)
        action.fulfill()
    }

    func provider(_ provider: CXProvider,
                  perform action: CXSetHeldCallAction) {
        action.fail()
    }

    func provider(_ provider: CXProvider,
                  perform action: CXSetGroupCallAction) {
        action.fail()
    }

    func provider(_ provider: CXProvider,
                  didActivate audioSession: AVAudioSession) {
        log("[CALLKIT] AUDIO SESSION ACTIVE sr=\(audioSession.sampleRate) io=\(audioSession.ioBufferDuration)")
        onAudioActivated?()
    }

    func provider(_ provider: CXProvider,
                  didDeactivate audioSession: AVAudioSession) {
        log("[CALLKIT] AUDIO SESSION DEACTIVATED")
        onAudioDeactivated?()
    }

    func provider(_ provider: CXProvider,
                  timedOutPerforming action: CXAction) {
        log("[CALLKIT] ACTION TIMEOUT type=\(type(of: action))")
    }
}
