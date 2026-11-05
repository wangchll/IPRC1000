# Native Bluetooth capture tests

The production backend in `Sources/CRemoteSupport/NativeCapture.m` connects to
`com.apple.bluetooth.BTPacketLogger` with normal system Authorization Services.
It does not execute PacketLogger or load PacketDecoder.framework. Real target F7
and WeChat cursor input have been verified on the local Apple Silicon Mac without
an installed logging profile, using an explicitly enabled diagnostic lease.

The underlying stream is host-wide HCI. The filter accepts only the configured
remote's address, learned Classic handle, negotiated PSM 0x13 Interrupt CID,
incoming direction, and valid F7 payload. It reassembles ACL fragments in a fixed
buffer, clears state on disconnect/channel changes, and never scans PCM for F7.
No audio, raw packets, or authorization tokens are persisted.

## Offline regression

Run from the repository root:

```sh
clang -O1 -g -fsanitize=address,undefined -I Sources/CRemoteSupport \
  Sources/CRemoteSupport/NativePacketFilter.c \
  Tools/NativeBluetoothCaptureProbe/selftest.c \
  -o /private/tmp/iprc-native-filter-selftest
/private/tmp/iprc-native-filter-selftest
clang -Wall -Wextra -Werror -fobjc-arc -fblocks -O1 -g \
  -fsanitize=address,undefined \
  Tools/NativeBluetoothCaptureProbe/backend-selftest.m \
  Sources/CRemoteSupport/NativePacketFilter.c \
  -framework Foundation -framework Security \
  -o /private/tmp/iprc-native-backend-selftest
/private/tmp/iprc-native-backend-selftest
```

The backend test compiles production code with mock authorization and transport.
It checks handshake ordering, target routing, 64-frame overflow, disconnect,
profile-required denial, asynchronous cancellation, and late callbacks. It does
not access Bluetooth or grant permissions. The filter test checks lengths,
byte orders, channel negotiation, every split point, interleaved directions and
handles, overflow, and reconnect state.

## Standalone investigation tool

`main.c` is a separate developer probe. Its default mode counts system envelopes;
`--authorize` requests normal system authentication. `--target` requires an
explicit 12-digit paired-device address. `--interactive` retains authorization
only in memory and opens bounded windows on stdin commands. These are active
capture operations, not installation requirements or safe unattended self-tests.

The service is private and may vary between macOS versions. Observing a live
connection and channel negotiation is required; a zero count is not proof that
the remote transmitted no audio. Historical attempts and later corrections are
kept in dated developer documents, not in the user installation guide.
