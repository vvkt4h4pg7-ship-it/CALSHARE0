# CALLSHARE iOS R0 architecture invariant

The R0 design intentionally separates these conditions:

1. `CallKit audio active`
2. `K7 voice-open ACK received`
3. `BLE audio TX enabled`
4. `AudioEngine running`

Required relationship:

```text
CallKit ACTIVE
     +
K7 VOICE_OPEN ACK
     |
     v
Audio TX ENABLED
     |
     v
AudioEngine MIC -> AMR -> BLE
```

`CallKit ACTIVE` alone never opens the BLE audio TX gate.

`VOICE_OPEN 0x0F` is sent early after Answer to minimize call setup latency. The retry path is bounded to three retries and carries no audio traffic.

The BLE transport uses a dedicated serial queue. SwiftUI logging is delivered asynchronously to the main actor so UI publication cannot run on the BLE/audio callback path.

Receive audio has a six-frame prebuffer. Transmit audio has an eight-frame bounded queue and no audio is queued while the handshake gate is closed.
