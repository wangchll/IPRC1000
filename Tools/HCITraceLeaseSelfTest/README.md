# Scoped trace configuration tests

These tests compile the actual transaction and wait-loop implementation. They
run without root or Bluetooth access. Configuration fixtures use private temporary
directories. The cache regression also writes one UUID-named, current-user test
preference domain through CFPreferences, then removes its own keys and file; it
never writes the Bluetooth preference domain. The process test kills only its own fixture
owner, then checks restoration before the independent guard's timeout.
The session fixture also runs beyond the finite fixture's deadline, then verifies
restoration on stop, EOF, and owner death without relying on any timeout.

Run from the repository root:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CLANG_MODULE_CACHE_PATH=/private/tmp/iprc1000-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/iprc1000-module-cache \
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -module-cache-path /private/tmp/iprc1000-module-cache -sanitize=address \
  Sources/IPRC1000Adapter/ScopedHCITrace.swift \
  Tools/HCITraceLeaseSelfTest/main.swift -o /private/tmp/iprc-trace-lease-selftest
/private/tmp/iprc-trace-lease-selftest
python3 Tools/HCITraceLeaseSelfTest/process-test.py /private/tmp/iprc-trace-lease-selftest
```

Passing these tests proves the covered preference/cache/file/pipe behaviors, not real HCI
reception or compatibility of private diagnostic settings across macOS versions.
