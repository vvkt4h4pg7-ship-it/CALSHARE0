# CALLSHARE iOS R0 test plan

## Test A — BLE/GATT only

Expected log:

```text
[BLE] FOUND
[BLE] CONNECTED
[BLE] SERVICE READY
[BLE] TX 5CBA ...
[BLE] GATT_READY
```

## Test B — Incoming CallKit

J7 receives GSM call.

Expected:

```text
[CALL] INCOMING
[CALLKIT] REPORT INCOMING
[CALLKIT] INCOMING UI READY
```

Do not answer from the app UI. Answer from the native CallKit screen.

## Test C — Answer/handshake

Expected order:

```text
[CALLKIT] ANSWER ACTION
[VOICE] AUDIO PREPARE requested
[BLE] CTRL TX ANSWER 05
[BLE] CTRL TX VOICE_OPEN 0F
[CALL] ANSWER -> 05 sent; CallKit answer fulfilled
[CALLKIT] AUDIO SESSION ACTIVE
[BLE] CONTROL RX ... 0F
[VOICE] K7 ACK 0F -> AUDIO TX ENABLED
[AUDIO] ENGINE RUNNING
```

There must be no:

```text
AUDIO TX ... queue=25
AUDIO TX queue overflow
```

before the K7 `0x0F` event.

## Test D — J7 -> iPhone voice

After `K7 ACK 0F`:

```text
[BLE] AUDIO RX #1
[AUDIO] AMR RX #1
```

The decoded PCM must be non-zero during speech.

## Test E — iPhone -> J7 voice

After `K7 ACK 0F` and `AUDIO SESSION ACTIVE`:

```text
[AUDIO] AMR TX #1
[BLE] AUDIO TX #1
```

No TX audio should appear before the gate opens.

## Test F — End

Local or remote end must result in:

```text
[AUDIO] STOPPED
[BLE] AUDIO TX GATE -> CLOSED queue=0
```

and no further microphone/AMR TX packets after the call ends.
