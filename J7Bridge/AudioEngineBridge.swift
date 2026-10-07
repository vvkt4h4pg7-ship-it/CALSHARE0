import Foundation
import AVFoundation

@_silgen_name("Encoder_Interface_init")
private func amrEncoderInit(_ dtx: Int32) -> UnsafeMutableRawPointer?

@_silgen_name("Encoder_Interface_exit")
private func amrEncoderExit(_ state: UnsafeMutableRawPointer?)

@_silgen_name("Encoder_Interface_Encode")
private func amrEncoderEncode(
    _ state: UnsafeMutableRawPointer?,
    _ mode: Int32,
    _ speech: UnsafePointer<Int16>?,
    _ out: UnsafeMutablePointer<UInt8>?,
    _ forceSpeech: Int32
) -> Int32

@_silgen_name("Decoder_Interface_init")
private func amrDecoderInit() -> UnsafeMutableRawPointer?

@_silgen_name("Decoder_Interface_exit")
private func amrDecoderExit(_ state: UnsafeMutableRawPointer?)

@_silgen_name("Decoder_Interface_Decode")
private func amrDecoderDecode(
    _ state: UnsafeMutableRawPointer?,
    _ input: UnsafePointer<UInt8>?,
    _ output: UnsafeMutablePointer<Int16>?,
    _ bfi: Int32
)

final class AudioEngineBridge: NSObject {
    private let audioQueue = DispatchQueue(label: "com.callshare.audio", qos: .userInteractive)

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let audioSession = AVAudioSession.sharedInstance()

    private let pcm8kFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 8_000,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var running = false
    private var prepared = false
    private var muted = false
    private var speakerDefault = true
    private var txEnabled = false

    private var encoder: UnsafeMutableRawPointer?
    private var decoder: UnsafeMutableRawPointer?

    private var pcmAccumulator: [Int16] = []
    private var rxPrebuffer: [Data] = []
    private let maxRXPrebuffer = 6

    private var txFrames = 0
    private var rxFrames = 0

    var onAMRPacket: ((Data) -> Void)?
    var onStatus: ((String) -> Void)?

    func setSpeakerDefault(_ enabled: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.speakerDefault = enabled
            if self.running {
                self.applyCategoryLocked()
            }
        }
    }

    func setMuted(_ muted: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.muted = muted
            self.publishStatus(muted ? "[AUDIO] MUTED" : "[AUDIO] UNMUTED")
        }
    }

    func setTXEnabled(_ enabled: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.txEnabled = enabled
            self.pcmAccumulator.removeAll(keepingCapacity: true)
            self.publishStatus("[AUDIO] TX_GATE \(enabled ? "OPEN" : "CLOSED")")
        }
    }

    func prepareForCallAudio() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.prepareLocked()
        }
    }

    func start() {
        audioQueue.async { [weak self] in
            guard let self, !self.running else { return }
            self.startLocked()
        }
    }

    func stop() {
        audioQueue.async { [weak self] in
            self?.stopLocked()
        }
    }

    func receiveAMR(_ packet: Data) {
        guard !packet.isEmpty else { return }
        audioQueue.async { [weak self] in
            self?.receiveAMRLocked(packet)
        }
    }

    // MARK: Lifecycle

    private func prepareLocked() {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: speakerDefault ? [.allowBluetooth, .defaultToSpeaker] : [.allowBluetooth]
            )
            try audioSession.setPreferredSampleRate(8_000)
            try audioSession.setPreferredIOBufferDuration(0.02)

            prepared = true
            publishStatus("[AUDIO] PREPARED category=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue)")
        } catch {
            prepared = false
            publishStatus("[AUDIO] PREPARE ERROR \(error.localizedDescription)")
        }
    }

    private func startLocked() {
        do {
            if !prepared {
                prepareLocked()
            }

            guard let encoderState = amrEncoderInit(0),
                  let decoderState = amrDecoderInit() else {
                throw NSError(
                    domain: "CALLSHARE.Audio",
                    code: 100,
                    userInfo: [NSLocalizedDescriptionKey: "AMR initialization failed"]
                )
            }

            encoder = encoderState
            decoder = decoderState

            let input = audioEngine.inputNode
            let hardwareFormat = input.inputFormat(forBus: 0)

            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
                throw NSError(
                    domain: "CALLSHARE.Audio",
                    code: 101,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid input hardware format"]
                )
            }

            converter = AVAudioConverter(from: hardwareFormat, to: pcm8kFormat)
            guard converter != nil else {
                throw NSError(
                    domain: "CALLSHARE.Audio",
                    code: 102,
                    userInfo: [NSLocalizedDescriptionKey: "8 kHz converter creation failed"]
                )
            }

            if !isPlayerConnected {
                audioEngine.attach(playerNode)
                audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: pcm8kFormat)
                isPlayerConnected = true
            }

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1600, format: hardwareFormat) { [weak self] buffer, _ in
                self?.capturePCM(buffer)
            }

            pcmAccumulator.removeAll(keepingCapacity: true)
            txFrames = 0
            rxFrames = 0

            audioEngine.prepare()
            try audioEngine.start()
            playerNode.play()

            running = true
            publishStatus("[AUDIO] ENGINE RUNNING route=\(routeDescription())")

            // Drain only a tiny prebuffer. No unbounded RX delay.
            let pending = rxPrebuffer
            rxPrebuffer.removeAll(keepingCapacity: true)
            pending.forEach { decodeAndPlayLocked($0) }
        } catch {
            running = false
            cleanupAudioGraphLocked()

            if let encoder {
                amrEncoderExit(encoder)
                self.encoder = nil
            }
            if let decoder {
                amrDecoderExit(decoder)
                self.decoder = nil
            }

            converter = nil
            publishStatus("[AUDIO] START ERROR \(error.localizedDescription)")
        }
    }

    private var isPlayerConnected = false

    private func stopLocked() {
        guard running || prepared else {
            txEnabled = false
            return
        }

        running = false
        txEnabled = false
        pcmAccumulator.removeAll(keepingCapacity: true)
        rxPrebuffer.removeAll(keepingCapacity: true)

        cleanupAudioGraphLocked()

        if let encoder {
            amrEncoderExit(encoder)
            self.encoder = nil
        }
        if let decoder {
            amrDecoderExit(decoder)
            self.decoder = nil
        }

        converter = nil
        prepared = false
        publishStatus("[AUDIO] STOPPED")
    }

    private func cleanupAudioGraphLocked() {
        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        playerNode.reset()
        audioEngine.stop()
    }

    // MARK: TX

    private func capturePCM(_ buffer: AVAudioPCMBuffer) {
        guard running, txEnabled, !muted, let converter else { return }

        let ratio = pcm8kFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 128)

        guard let converted = AVAudioPCMBuffer(
            pcmFormat: pcm8kFormat,
            frameCapacity: capacity
        ) else { return }

        var supplied = false
        var error: NSError?

        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil,
              let channel = converted.int16ChannelData?[0] else {
            return
        }

        pcmAccumulator.append(
            contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
        )

        while pcmAccumulator.count >= 160 {
            let frame = Array(pcmAccumulator.prefix(160))
            pcmAccumulator.removeFirst(160)

            var encoded = [UInt8](repeating: 0, count: 64)
            let length: Int32 = frame.withUnsafeBufferPointer { samples in
                encoded.withUnsafeMutableBufferPointer { out in
                    amrEncoderEncode(
                        encoder,
                        1, // AMR-NB mode 1; K7 accepts the ToC mode on RX.
                        samples.baseAddress,
                        out.baseAddress,
                        1
                    )
                }
            }

            guard length > 0 else { continue }

            let packet = Data(encoded.prefix(Int(length)))
            txFrames += 1

            if txFrames == 1 || txFrames % 25 == 0 {
                publishStatus("[AUDIO] AMR TX #\(txFrames) len=\(packet.count)")
            }

            let callback = onAMRPacket
            DispatchQueue.global(qos: .userInitiated).async {
                callback?(packet)
            }
        }
    }

    // MARK: RX

    private func receiveAMRLocked(_ packet: Data) {
        guard let first = packet.first else { return }
        let frameType = Int((first >> 3) & 0x0F)

        guard frameType <= 8 || frameType == 15 else {
            publishStatus("[AUDIO] AMR RX invalid FT=\(frameType) len=\(packet.count)")
            return
        }

        if !running {
            if rxPrebuffer.count < maxRXPrebuffer {
                rxPrebuffer.append(packet)
            } else {
                rxPrebuffer.removeFirst()
                rxPrebuffer.append(packet)
            }
            return
        }

        decodeAndPlayLocked(packet)
    }

    private func decodeAndPlayLocked(_ packet: Data) {
        guard running, let decoder else { return }

        var pcm = [Int16](repeating: 0, count: 160)
                // RAW AMR DEBUG — first 10 frames only
        if rxFrames < 10 {
            let hex = packet.map { String(format: "%02X", $0) }.joined(separator: " ")
            publishStatus("[AMR RAW] #\(rxFrames + 1) len=\(packet.count) HEX=\(hex)")
        }
        packet.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            pcm.withUnsafeMutableBufferPointer { out in
                amrDecoderDecode(decoder, base, out.baseAddress, 0)
            }
        }

        let minSample = pcm.min() ?? 0
        let maxSample = pcm.max() ?? 0
        let nonZero = pcm.reduce(into: 0) { count, sample in
            if sample != 0 { count += 1 }
        }

        rxFrames += 1
        if rxFrames == 1 || rxFrames % 25 == 0 {
            publishStatus("[AUDIO] AMR RX #\(rxFrames) PCM160 min=\(minSample) max=\(maxSample) nz=\(nonZero)")
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm8kFormat, frameCapacity: 160),
              let channel = buffer.int16ChannelData?[0] else { return }

        buffer.frameLength = 160
        pcm.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.assign(from: base, count: 160)
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func applyCategoryLocked() {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: speakerDefault ? [.allowBluetooth, .defaultToSpeaker] : [.allowBluetooth]
            )
        } catch {
            publishStatus("[AUDIO] CATEGORY ERROR \(error.localizedDescription)")
        }
    }

    private func routeDescription() -> String {
        let input = audioSession.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        let output = audioSession.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        return "IN[\(input)] OUT[\(output)]"
    }

    private func publishStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(message)
        }
    }

    deinit {
        if let encoder { amrEncoderExit(encoder) }
        if let decoder { amrDecoderExit(decoder) }
    }
}
