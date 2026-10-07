# CALLSHARE iOS R0

Clean iPhone-side rewrite for the IKOS K7 GSM gateway.

## Architecture

- `BLETransport`: CoreBluetooth transport, dedicated serial BLE queue.
- `K7Protocol`: C0-delimited control/audio framing and incremental parser.
- `CallSession`: single call state machine and handshake gate.
- `CallKitCoordinator`: native CallKit lifecycle.
- `AudioEngineBridge`: AVAudioEngine + OpenCORE AMR-NB.
- `ContentView`: minimal operational UI and diagnostics.

## Verified K7 wire boundary

Service:
`0783B03E-8535-B5A0-7140-A304D2495CB7`

RX:
`0783B03E-8535-B5A0-7140-A304D2495CB8`

FLOW:
`0783B03E-8535-B5A0-7140-A304D2495CB9`

TX:
`0783B03E-8535-B5A0-7140-A304D2495CBA`

Control:
`0x12`

Call:
- Incoming `0x0A`
- Answer `0x05`
- Hangup `0x04`
- Voice open `0x0F`
- Voice close `0x10`

Audio:
- channel `3`
- AMR-NB
- 8 kHz mono
- 160 PCM samples / frame

## R0 handshake rule

```text
CallKit ANSWER
   -> send 0x05
   -> prepare audio
   -> send 0x0F immediately
   -> fulfill Answer action
   -> CallKit audio session activates
   -> wait for K7 0x0F event
   -> OPEN AUDIO TX GATE
   -> start audio engine
```

The microphone/AMR path may be prepared before the remote voice ACK, but no AMR frame is ever queued for BLE TX while the gate is closed.

## BLE priority rule

Control is always handled before releasing an audio burst. Audio uses bounded no-response bursts and CoreBluetooth backpressure. There is no unbounded audio queue.

## Build

The project expects `build/opencore-amrnb/libopencore-amrnb.a`.
GitHub Actions builds that library first with `Scripts/build_amr.sh`.

For a local Mac:

```bash
bash Scripts/build_amr.sh
xcodebuild -project CALLSHARE.xcodeproj -target CALLSHARE -sdk iphoneos -configuration Release
```

This repository intentionally does not claim end-to-end hardware voice success until the real J7 + iPhone test is run.
