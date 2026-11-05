// Fault fixture only: substitute in a private copy of the app, never a release.
import Foundation

print("IPRC_AUDIO_READY"); fflush(stdout)
if ProcessInfo.processInfo.environment["IPRC_TEST_STALL_AFTER_EOF"] == "1" {
    _ = FileHandle.standardInput.readDataToEndOfFile()
}
// The production controller must cancel this helper; it does not touch audio.
Thread.sleep(forTimeInterval: 60)
