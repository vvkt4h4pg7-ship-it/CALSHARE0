import Foundation
import CoreBluetooth

enum K7Protocol {
    static let service = CBUUID(string: "0783B03E-8535-B5A0-7140-A304D2495CB7")
    static let rx = CBUUID(string: "0783B03E-8535-B5A0-7140-A304D2495CB8")
    static let flow = CBUUID(string: "0783B03E-8535-B5A0-7140-A304D2495CB9")
    static let tx = CBUUID(string: "0783B03E-8535-B5A0-7140-A304D2495CBA")

    static let controlChannel: UInt8 = 0x12
    static let audioChannel: UInt8 = 0x03

    // Host -> K7 commands
    static let cmdDevCheck: UInt8 = 0x01
    static let cmdMakeCall: UInt8 = 0x02
    static let cmdDTMF: UInt8 = 0x03
    static let cmdHangup: UInt8 = 0x04
    static let cmdAnswer: UInt8 = 0x05
    static let cmdReadBattery: UInt8 = 0x09
    static let cmdVoiceOpen: UInt8 = 0x0F
    static let cmdVoiceClose: UInt8 = 0x10
    static let cmdFirmwareVersion: UInt8 = 0x12
    static let cmdIMEIInfo: UInt8 = 0x71

    // K7 -> host events
    static let evtDevCheck: UInt8 = 0x01
    static let evtDTMF: UInt8 = 0x02
    static let evtMakeCall: UInt8 = 0x03
    static let evtHangup: UInt8 = 0x04
    static let evtAnswer: UInt8 = 0x05
    static let evtReadBattery: UInt8 = 0x09
    static let evtReceiveCall: UInt8 = 0x0A
    static let evtReceiveCallEnd: UInt8 = 0x0B
    static let evtFirmwareVersion: UInt8 = 0x16
    static let evtVoiceOpen: UInt8 = 0x0F
    static let evtVoiceClose: UInt8 = 0x10
    static let evtIMEIInfo: UInt8 = 0x71

    static func makeCallPayload(number: String, simId: UInt8) -> Data {
        var payload = Data([cmdMakeCall, simId])
        payload.append(contentsOf: number.data(using: .utf16LittleEndian) ?? Data())
        return payload
    }

    static func dtmfPayload(_ value: UInt8) -> Data {
        Data([cmdDTMF, value])
    }

    static func controlFrame(_ payload: Data) -> Data {
        precondition(!payload.isEmpty, "K7 control payload must not be empty")
        let lengthField = UInt8((payload.count - 1) & 0xFF)
        let checksum = UInt8((~(Int(controlChannel) + Int(lengthField))) & 0xFF)

        var frame = Data([0xC0])
        appendEscaped(&frame, controlChannel)
        appendEscaped(&frame, lengthField)
        appendEscaped(&frame, checksum)
        payload.forEach { appendEscaped(&frame, $0) }
        frame.append(0xC0)
        return frame
    }

    static func audioFrame(_ amr: Data) -> Data {
        let length = amr.count
        precondition(length > 0 && length <= 0xFFF, "Invalid AMR payload size")

        let h0 = UInt8(((length & 0x0F) << 4) | Int(audioChannel))
        let h1 = UInt8((length >> 4) & 0xFF)
        let checksum = UInt8((-Int(h0) - Int(h1)) & 0xFF)

        var frame = Data([0xC0])
        appendEscaped(&frame, h0)
        appendEscaped(&frame, h1)
        appendEscaped(&frame, checksum)
        amr.forEach { appendEscaped(&frame, $0) }
        frame.append(0xC0)
        return frame
    }

    static func parseFrame(_ raw: Data) -> (channel: UInt8, payload: Data)? {
        guard raw.count >= 5, raw.first == 0xC0, raw.last == 0xC0 else { return nil }

        let inner = Data(raw.dropFirst().dropLast())
        let bytes = unescape(Array(inner))
        guard bytes.count >= 3 else { return nil }

        if bytes[0] == controlChannel {
            let payloadLength = Int(bytes[1]) + 1
            let expectedChecksum = UInt8((~(Int(bytes[0]) + Int(bytes[1]))) & 0xFF)
            guard bytes[2] == expectedChecksum else { return nil }
            guard payloadLength == bytes.count - 3 else { return nil }
            return (2, Data(bytes.dropFirst(3)))
        }

        let h0 = bytes[0]
        let h1 = bytes[1]
        let checksum = bytes[2]
        let payloadLength = Int(h0 >> 4) | (Int(h1) << 4)
        guard (Int(h0) + Int(h1) + Int(checksum)) & 0xFF == 0 else { return nil }
        guard (h0 & 0x0F) == audioChannel else { return nil }
        guard payloadLength == bytes.count - 3 else { return nil }
        return (audioChannel, Data(bytes.dropFirst(3)))
    }

    static func decodeIncomingNumber(_ payload: Data) -> String {
        guard payload.count > 2 else { return "" }
        return String(data: Data(payload.dropFirst(2)), encoding: .utf16LittleEndian)?
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func decodeASCII(_ payload: Data, offset: Int) -> String {
        guard payload.count > offset else { return "" }
        return String(data: Data(payload.dropFirst(offset)), encoding: .ascii)?
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    final class StreamParser {
        private var buffer: [UInt8] = []
        private let maxBytes = 8192

        func reset() {
            buffer.removeAll(keepingCapacity: true)
        }

        func feed(_ data: Data) -> [(channel: UInt8, payload: Data)] {
            guard !data.isEmpty else { return [] }

            buffer.append(contentsOf: data)
            if buffer.count > maxBytes {
                buffer = Array(buffer.suffix(512))
            }

            var frames: [(channel: UInt8, payload: Data)] = []

            while let start = buffer.firstIndex(of: 0xC0) {
                if start > 0 { buffer.removeFirst(start) }
                guard buffer.count >= 2 else { break }

                guard let end = buffer.dropFirst().firstIndex(of: 0xC0) else { break }

                let frame = Data(buffer[0...end])
                buffer.removeFirst(end + 1)

                if let parsed = K7Protocol.parseFrame(frame) {
                    frames.append(parsed)
                }
            }

            return frames
        }
    }

    private static func appendEscaped(_ output: inout Data, _ value: UInt8) {
        switch value {
        case 0xC0:
            output.append(contentsOf: [0xDB, 0xDC])
        case 0xDB:
            output.append(contentsOf: [0xDB, 0xDD])
        default:
            output.append(value)
        }
    }

    private static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)

        var index = 0
        while index < bytes.count {
            if bytes[index] == 0xDB, index + 1 < bytes.count {
                switch bytes[index + 1] {
                case 0xDC: result.append(0xC0); index += 2; continue
                case 0xDD: result.append(0xDB); index += 2; continue
                default: break
                }
            }
            result.append(bytes[index])
            index += 1
        }
        return result
    }
}
