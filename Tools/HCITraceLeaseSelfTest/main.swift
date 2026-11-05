import Darwin
import Foundation
import CoreFoundation

final class FixturePreferences: HCITracePreferenceStore {
    let url: URL
    init(_ url: URL) { self.url = url }
    func validateForEnable() throws {}
    func read() throws -> Data? { FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil }
    func write(_ data: Data?) throws {
        if let data { try data.write(to: url, options: .atomic); assert(chmod(url.path, 0o600) == 0) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--cache-reader" {
    let preferences = SystemHCITracePreferences(domain: CommandLine.arguments[2], user: kCFPreferencesCurrentUser)
    let initial = try preferences.read(); assert(initial == nil)
    print("CACHE_READY"); fflush(stdout)
    var byte: UInt8 = 0
    assert(read(STDIN_FILENO, &byte, 1) == 1)
    let end = ProcessInfo.processInfo.systemUptime + 2
    var updated = false
    while ProcessInfo.processInfo.systemUptime < end {
        let data = try preferences.read()
        let value = try HCITraceConfiguration.dictionary(data)["HCITraces"] as? [String: Any] ?? [:]
        if value["HCILiveTraces"] as? Bool == true {
            assert(value["HCIFileTraces"] as? Bool == false && value["HCISkipAuth"] as? Bool == false)
            try preferences.verifyEffective(data); updated = true; break
        }
        usleep(20_000)
    }
    assert(updated)
    print("CACHE_UPDATED"); fflush(stdout)
    exit(0)
}

if CommandLine.arguments.count == 3, ["--guard-fixture", "--session-fixture"].contains(CommandLine.arguments[1]) {
    let session = CommandLine.arguments[1] == "--session-fixture"
    let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    let transaction = HCITraceTransaction(preferences: FixturePreferences(directory.appendingPathComponent("preferences.plist")),
        directory: directory.appendingPathComponent("state"), owner: geteuid(), reload: {})
    try transaction.acquire(until: session ? nil : Date().addingTimeInterval(60))
    print("GUARD_READY"); fflush(stdout)
    ScopedHCITraceGuard.waitForStop(input: STDIN_FILENO, seconds: session ? .infinity : 3)
    try transaction.restore()
    print("GUARD_RESTORED"); fflush(stdout)
    exit(0)
}

func expectFailure(_ body: () throws -> Void) {
    do { try body(); fatalError("expected refusal") } catch { }
}
func traces(_ data: Data?) throws -> [String: Any] {
    try HCITraceConfiguration.dictionary(data)["HCITraces"] as? [String: Any] ?? [:]
}
let deadline = Date().addingTimeInterval(360)
let original = try PropertyListSerialization.data(fromPropertyList: [
    "Unrelated": "keep", "HCITraces": ["MaxTraces": 7, "RawAudioTrace": false]
], format: .xml, options: 0)
let applied = try HCITraceConfiguration.enabled(original, until: deadline)
let values = try traces(applied)
assert(values["HCILiveTraces"] as? Bool == true)
assert(values["HCIFileTraces"] as? Bool == false)
assert(values["HCISkipAuth"] as? Bool == false)
assert(values["MaxTraces"] as? Int == 7)
assert(values["AutoDisableTime"] is String)
let sessionValues = try traces(HCITraceConfiguration.enabled(original, until: nil))
assert(sessionValues["AutoDisableTime"] == nil)
assert(sessionValues["HCILiveTraces"] as? Bool == true && sessionValues["HCIFileTraces"] as? Bool == false && sessionValues["HCISkipAuth"] as? Bool == false)
let exact = try HCITraceConfiguration.restored(original: original, applied: applied, current: applied)
assert(exact == original)
var changed = try HCITraceConfiguration.dictionary(applied)
changed["External"] = "preserve"
var changedTraces = try traces(applied)
changedTraces["ExternalTraceKey"] = 12
changed["HCITraces"] = changedTraces
let merged = try HCITraceConfiguration.dictionary(HCITraceConfiguration.restored(
    original: original, applied: applied, current: HCITraceConfiguration.encode(changed)))
assert(merged["External"] as? String == "preserve")
let mergedTraces = merged["HCITraces"] as! [String: Any]
assert(mergedTraces["ExternalTraceKey"] as? Int == 12 && mergedTraces["MaxTraces"] as? Int == 7)
assert(mergedTraces["HCILiveTraces"] == nil && mergedTraces["RawAudioTrace"] as? Bool == false)
for key in ["StackDebugEnabled", "HCILiveTraces", "HCIFileTraces", "HCISkipAuth"] {
    let busy = try HCITraceConfiguration.encode(["HCITraces": [key: true]])
    expectFailure { _ = try HCITraceConfiguration.enabled(busy, until: deadline) }
}
expectFailure { _ = try HCITraceConfiguration.enabled(Data("bad plist".utf8), until: deadline) }
expectFailure { _ = try HCITraceConfiguration.enabled(HCITraceConfiguration.encode(["HCITraces": ["HCILiveTraces": "true"]]), until: deadline) }
expectFailure { _ = try HCITraceConfiguration.enabled(HCITraceConfiguration.encode(["HCITraces": "wrong"]), until: deadline) }

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("iprc-trace-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: temporary) }
let preferences = temporary.appendingPathComponent("preferences.plist")
let state = temporary.appendingPathComponent("state")
var reloads = 0
func transaction(_ reload: (() throws -> Void)? = nil) -> HCITraceTransaction {
    HCITraceTransaction(preferences: FixturePreferences(preferences), directory: state, owner: geteuid(), reload: reload ?? { reloads += 1 })
}
do {
    let lease = transaction()
    try lease.acquire(until: deadline)
    assert(FileManager.default.fileExists(atPath: preferences.path))
    let second = transaction()
    expectFailure { try second.acquire(until: deadline) }
    expectFailure { try second.restore() }
    try lease.restore()
    assert(!FileManager.default.fileExists(atPath: preferences.path) && reloads == 2)
}
try original.write(to: preferences)
assert(chmod(preferences.path, 0o600) == 0)
do {
    let lease = transaction()
    try lease.acquire(until: deadline)
    // Simulate loss of the owner without cleanup; the persisted journal remains.
}
do {
    let replacement = transaction()
    try replacement.acquire(until: deadline)
    try replacement.restore()
    let restored = try Data(contentsOf: preferences)
    assert(restored == original)
    var info = stat(); assert(lstat(preferences.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
}
enum TestFailure: Error { case reload }
var attempts = 0
do {
    let lease = transaction {
        attempts += 1
        if attempts == 1 { throw TestFailure.reload }
    }
    expectFailure { try lease.acquire(until: deadline) }
    let restored = try Data(contentsOf: preferences)
    assert(attempts == 2 && restored == original)
    assert(!FileManager.default.fileExists(atPath: state.appendingPathComponent("state.plist").path))
}
final class ManagedFixture: HCITracePreferenceStore {
    var writes = 0
    func validateForEnable() throws { throw HCITraceConfiguration.Failure.managedPreferences }
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws { writes += 1 }
}
do {
    let managed = ManagedFixture()
    let lease = HCITraceTransaction(preferences: managed, directory: temporary.appendingPathComponent("managed-state"), owner: geteuid(), reload: {})
    expectFailure { try lease.acquire(until: deadline) }
    assert(managed.writes == 0)
}
// Use the actual preferences daemon with an unrelated, unique test domain.
let domain = "local.iprc1000.trace-cache-test." + UUID().uuidString
let systemPreferences = SystemHCITracePreferences(domain: domain, user: kCFPreferencesCurrentUser)
defer {
    try? systemPreferences.write(nil)
    CFPreferencesSetValue("unrelated" as CFString, nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(domain).plist"))
}
CFPreferencesSetValue("unrelated" as CFString, 42 as CFNumber, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
assert(CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
let reader = Process(), input = Pipe(), output = Pipe()
reader.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
reader.arguments = ["--cache-reader", domain]; reader.standardInput = input; reader.standardOutput = output
try reader.run()
defer { if reader.isRunning { reader.terminate(); reader.waitUntilExit() } }
assert(output.fileHandleForReading.readData(ofLength: 12) == Data("CACHE_READY\n".utf8))
do {
    let lease = HCITraceTransaction(preferences: systemPreferences, directory: temporary.appendingPathComponent("cf-state"), owner: geteuid(), reload: {})
    try lease.acquire(until: deadline)
    try systemPreferences.verifyEffective(systemPreferences.read())
    input.fileHandleForWriting.write(Data([80]))
    input.fileHandleForWriting.closeFile()
    reader.waitUntilExit(); assert(reader.terminationStatus == 0)
    assert(output.fileHandleForReading.readDataToEndOfFile() == Data("CACHE_UPDATED\n".utf8))
    try lease.restore()
    let restored = try systemPreferences.read(); assert(restored == nil)
    let unrelated = CFPreferencesCopyValue("unrelated" as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber
    assert(unrelated?.intValue == 42)
}
let untouched = temporary.appendingPathComponent("untouched")
try Data("unchanged".utf8).write(to: untouched)
let journal = state.appendingPathComponent("state.plist")
try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: untouched)
do { let lease = transaction(); expectFailure { try lease.acquire(until: deadline) } }
let untouchedData = try Data(contentsOf: untouched)
assert(untouchedData == Data("unchanged".utf8))
try FileManager.default.removeItem(at: journal)
assert(chmod(state.path, 0o777) == 0)
do { let lease = transaction(); expectFailure { try lease.acquire(until: deadline) } }
print("TRACE LEASE SELF-TEST PASS: CFPreferences cross-process cache, managed refusal, auth retained, no file capture, restore, exclusion, recovery and unsafe journal refusal")
