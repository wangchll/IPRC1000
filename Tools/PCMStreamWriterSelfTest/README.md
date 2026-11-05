# PCM pipe backpressure regression

Compiles the production writer and exercises real local pipes. No microphone,
Bluetooth, IME, or system settings are accessed.

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swiftc -swift-version 6 -warnings-as-errors \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -module-cache-path /private/tmp/iprc1000-module-cache -sanitize=address \
  Sources/IPRC1000Adapter/PCMStreamWriter.swift \
  Tools/PCMStreamWriterSelfTest/main.swift -o /private/tmp/iprc-pcm-writer-selftest
/private/tmp/iprc-pcm-writer-selftest
```

Checks exact drain order, bounded backlog with a non-reading helper, cancellation
ahead of blocked writes, the two-second stall deadline, EPIPE without SIGPIPE,
and append/finish admission ordering across threads.
