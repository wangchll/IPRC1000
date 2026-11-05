import Darwin
import Foundation
import CoreFoundation

enum HCITraceConfiguration {
    enum Failure: Error { case malformed, alreadyActive, unsafeFile, locked, reloadFailed, startupFailed, managedPreferences, overriddenPreferences, preferenceSyncFailed }
    static let ownedKeys = ["StackDebugEnabled", "HCILiveTraces", "HCIFileTraces", "RawAudioTrace", "HIDTrace", "HCISkipAuth", "AutoDisableTime"]

    static func dictionary(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              value["HCITraces"] == nil || value["HCITraces"] is [String: Any] else { throw Failure.malformed }
        return value
    }
    static func encode(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    static func enabled(_ original: Data?, until: Date?) throws -> Data {
        var root = try dictionary(original)
        var traces = root["HCITraces"] as? [String: Any] ?? [:]
        for key in ["StackDebugEnabled", "HCILiveTraces", "HCIFileTraces", "HCISkipAuth"] {
            if let value = traces[key] {
                guard let number = value as? NSNumber else { throw Failure.malformed }
                if number.boolValue { throw Failure.alreadyActive }
            }
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = .current
        format.dateFormat = "HH:mm:ss MM-dd-yyyy"
        traces["StackDebugEnabled"] = true
        traces["HCILiveTraces"] = true
        traces["HCIFileTraces"] = false
        traces["RawAudioTrace"] = true
        traces["HIDTrace"] = true
        traces["HCISkipAuth"] = false
        traces["AutoDisableTime"] = until.map { format.string(from: $0) }
        root["HCITraces"] = traces
        return try encode(root)
    }
    static func restored(original: Data?, applied: Data, current: Data?) throws -> Data? {
        let before = try dictionary(original), installed = try dictionary(applied)
        var now = try dictionary(current)
        if NSDictionary(dictionary: now).isEqual(to: installed) { return original }
        let oldTraces = before["HCITraces"] as? [String: Any] ?? [:]
        let ourTraces = installed["HCITraces"] as? [String: Any] ?? [:]
        var traces = now["HCITraces"] as? [String: Any] ?? [:]
        for key in ownedKeys {
            guard let expected = ourTraces[key] as? NSObject,
                  let actual = traces[key] as? NSObject, actual.isEqual(expected) else { continue }
            traces[key] = oldTraces[key]
        }
        if traces.isEmpty && before["HCITraces"] == nil { now.removeValue(forKey: "HCITraces") }
        else { now["HCITraces"] = traces }
        return now.isEmpty && original == nil ? nil : try encode(now)
    }
}

protocol HCITracePreferenceStore {
    func validateForEnable() throws
    func read() throws -> Data?
    func write(_ data: Data?) throws
}

/// Publish through CFPreferences so bluetoothd sees the same values as the writer.
final class SystemHCITracePreferences: HCITracePreferenceStore {
    private let domain: CFString
    private let user: CFString
    private let key = "HCITraces" as CFString
    init(domain: String = "com.apple.MobileBluetooth.debug", user: CFString = kCFPreferencesAnyUser) {
        self.domain = domain as CFString; self.user = user
    }
    func validateForEnable() throws {
        guard !CFPreferencesAppValueIsForced(key, domain) else { throw HCITraceConfiguration.Failure.managedPreferences }
        let stored = CFPreferencesCopyValue(key, domain, user, kCFPreferencesAnyHost)
        let effective = CFPreferencesCopyAppValue(key, domain)
        guard equal(stored, effective) else { throw HCITraceConfiguration.Failure.overriddenPreferences }
    }
    private func equal(_ first: CFPropertyList?, _ second: CFPropertyList?) -> Bool {
        if let first, let second { return CFEqual(first, second) }
        return first == nil && second == nil
    }
    func read() throws -> Data? {
        guard let value = CFPreferencesCopyValue(key, domain, user, kCFPreferencesAnyHost) else { return nil }
        guard let traces = value as? [String: Any] else { throw HCITraceConfiguration.Failure.malformed }
        return try HCITraceConfiguration.encode(["HCITraces": traces])
    }
    func write(_ data: Data?) throws {
        let root = try HCITraceConfiguration.dictionary(data)
        let value = root["HCITraces"] as CFPropertyList?
        // This changes only the ordinary preference; it never overrides a managed value.
        CFPreferencesSetValue(key, value, domain, user, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, user, kCFPreferencesAnyHost),
              equal(value, CFPreferencesCopyValue(key, domain, user, kCFPreferencesAnyHost)) else {
            throw HCITraceConfiguration.Failure.preferenceSyncFailed
        }
    }
    func verifyEffective(_ data: Data?) throws {
        try validateForEnable()
        let expected = try HCITraceConfiguration.dictionary(data)["HCITraces"] as CFPropertyList?
        guard equal(expected, CFPreferencesCopyAppValue(key, domain)) else { throw HCITraceConfiguration.Failure.preferenceSyncFailed }
    }
}

/// Owns configuration only. It never opens HCI, HID, audio, or authorization services.
final class HCITraceTransaction {
    private struct Journal: Codable { let original: Data?; let applied: Data }
    private let preferences: HCITracePreferenceStore
    private let directory: URL
    private let owner: uid_t
    private let reload: () throws -> Void
    private var lock: Int32 = -1
    private var locked = false
    private var journal: URL { directory.appendingPathComponent("state.plist") }

    init(preferences: HCITracePreferenceStore, directory: URL, owner: uid_t, reload: @escaping () throws -> Void) {
        self.preferences = preferences; self.directory = directory; self.owner = owner; self.reload = reload
    }
    deinit { if lock >= 0 { close(lock) } }

    private func read(_ url: URL) throws -> (Data?, UInt16) {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return (nil, 0o600) }
            throw HCITraceConfiguration.Failure.unsafeFile
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
              info.st_mode & 0o022 == 0, info.st_nlink == 1, info.st_size <= 1_048_576 else {
            throw HCITraceConfiguration.Failure.unsafeFile
        }
        return (try Data(contentsOf: url), UInt16(info.st_mode & 0o777))
    }
    private func write(_ data: Data?, to url: URL, mode: UInt16) throws {
        _ = try read(url)
        if let data {
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, mode_t(mode)) == 0 else { throw HCITraceConfiguration.Failure.unsafeFile }
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    func acquire(until: Date?) throws {
        guard lock < 0 else { throw HCITraceConfiguration.Failure.locked }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw HCITraceConfiguration.Failure.unsafeFile }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == owner, info.st_mode & 0o077 == 0 else { throw HCITraceConfiguration.Failure.unsafeFile }
        lock = open(directory.appendingPathComponent("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0, fstat(lock, &info) == 0, info.st_uid == owner,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
            throw HCITraceConfiguration.Failure.unsafeFile
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw HCITraceConfiguration.Failure.locked }
        locked = true
        try restore() // Recover a prior interrupted transaction before starting another.
        try preferences.validateForEnable()
        let original = try preferences.read()
        let applied = try HCITraceConfiguration.enabled(original, until: until)
        let state = Journal(original: original, applied: applied)
        try write(try PropertyListEncoder().encode(state), to: journal, mode: 0o600)
        do {
            try preferences.write(applied)
            try reload()
        } catch {
            try restore()
            throw error
        }
    }
    func restore() throws {
        guard locked else { throw HCITraceConfiguration.Failure.locked }
        guard let data = try read(journal).0 else { return }
        let state = try PropertyListDecoder().decode(Journal.self, from: data)
        let current = try preferences.read()
        let result = try HCITraceConfiguration.restored(original: state.original, applied: state.applied, current: current)
        try preferences.write(result)
        try reload()
        try write(nil, to: journal, mode: 0o600)
    }
}

@MainActor
final class ScopedHCITraceLease {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var stopAt = 0.0
    var running: Bool { process.isRunning }
    // Close the XPC client before the independent guard disables its service.
    // The guard's 300-second deadline remains the fallback if this owner stalls.
    var expiring: Bool { ProcessInfo.processInfo.systemUptime >= stopAt }

    func start(session: Bool = false) throws {
        guard let executable = Bundle.main.executableURL else { throw HCITraceConfiguration.Failure.startupFailed }
        process.executableURL = executable
        process.arguments = ["--scoped-hci-trace-guard"] + (session ? ["--session"] : [])
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        stopAt = session ? .infinity : ProcessInfo.processInfo.systemUptime + 295
        try process.run()
        input.fileHandleForReading.closeFile(); output.fileHandleForWriting.closeFile()
        let end = ProcessInfo.processInfo.systemUptime + 5
        var line: [UInt8] = []
        while line.count < 256 && ProcessInfo.processInfo.systemUptime < end {
            var item = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            if poll(&item, 1, 100) <= 0 { continue }
            var byte: UInt8 = 0
            guard read(item.fd, &byte, 1) == 1 else { break }
            if byte == 10 {
                let ready = session ? "TRACE_READY authSkip=false fileTrace=false session=true" : "TRACE_READY authSkip=false fileTrace=false seconds=300"
                if String(decoding: line, as: UTF8.self) == ready { return }
                if String(decoding: line, as: UTF8.self) == "TRACE_BLOCKED managed-preferences" {
                    _ = stop()
                    throw HCITraceConfiguration.Failure.managedPreferences
                }
                break
            }
            line.append(byte)
        }
        _ = stop()
        throw HCITraceConfiguration.Failure.startupFailed
    }
    @discardableResult func stop() -> Bool {
        try? input.fileHandleForWriting.close()
        let end = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < end { usleep(20_000) }
        return !process.isRunning && process.terminationStatus == 0
    }
}

enum ScopedHCITraceGuard {
    static func waitForStop(input: Int32, seconds: TimeInterval) {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            var item = pollfd(fd: input, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = poll(&item, 1, 100)
            if result < 0 && errno != EINTR { break }
            if result > 0 {
                var byte: UInt8 = 0
                if read(input, &byte, 1) <= 0 || byte == 83 { break }
            }
        }
    }
    /// An app-owned lease, not an installed service. EOF survives an owner crash.
    static func run(session: Bool = false) -> Int32 {
        guard geteuid() == 0, setuid(0) == 0 else { return 77 }
        signal(SIGPIPE, SIG_IGN)
        let preferences = SystemHCITracePreferences()
        let transaction = HCITraceTransaction(
            preferences: preferences,
            directory: URL(fileURLWithPath: "/private/var/run/local.iprc1000.trace-lease"), owner: 0,
            reload: {
                let command = Process()
                command.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                command.arguments = ["-USR1", "bluetoothd"]
                command.standardOutput = FileHandle.nullDevice; command.standardError = FileHandle.nullDevice
                try command.run(); command.waitUntilExit()
                guard command.terminationStatus == 0 else { throw HCITraceConfiguration.Failure.reloadFailed }
            })
        do {
            try transaction.acquire(until: session ? nil : Date().addingTimeInterval(360))
            do { try preferences.verifyEffective(preferences.read()) }
            catch { try transaction.restore(); throw error }
            print(session ? "TRACE_READY authSkip=false fileTrace=false session=true" : "TRACE_READY authSkip=false fileTrace=false seconds=300"); fflush(stdout)
            waitForStop(input: STDIN_FILENO, seconds: session ? .infinity : 300)
            try transaction.restore()
            print("TRACE_RESTORED"); fflush(stdout)
            return 0
        } catch {
            if case HCITraceConfiguration.Failure.managedPreferences = error {
                print("TRACE_BLOCKED managed-preferences"); fflush(stdout)
            }
            fputs("TRACE_FAILED \(error)\n", stderr)
            return 1
        }
    }
}
