"""Exercise the real transaction/wait loop without root or system preferences."""
import pathlib
import select
import signal
import subprocess
import sys
import tempfile
import time


def ready(process):
    assert select.select([process.stdout], [], [], 5)[0], "fixture never ready"
    assert process.stdout.readline().strip() == b"GUARD_READY"


executable = str(pathlib.Path(sys.argv[1]).resolve(strict=True))
with tempfile.TemporaryDirectory(prefix="iprc-guard-process-") as folder:
    root = pathlib.Path(folder)
    for action in ("eof", "stop", "timeout"):
        with subprocess.Popen([executable, "--guard-fixture", folder], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE) as process:
            ready(process)
            assert (root / "preferences.plist").exists()
            if action == "eof":
                process.stdin.close()
            elif action == "stop":
                process.stdin.write(b"S")
                process.stdin.flush()
            assert process.wait(timeout=6) == 0
            assert not (root / "preferences.plist").exists()
    # The session lease stays enabled past the finite fixture's deadline, then
    # restores on either user stop or loss of its owner pipe.
    for action in ("eof", "stop"):
        with subprocess.Popen([executable, "--session-fixture", folder], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE) as process:
            ready(process)
            if action == "eof":
                time.sleep(3.2)
                assert process.poll() is None, "session lease expired like a finite test"
                assert (root / "preferences.plist").exists()
                process.stdin.close()
            else:
                process.stdin.write(b"S")
                process.stdin.flush()
            assert process.wait(timeout=3) == 0
            assert not (root / "preferences.plist").exists()
    # The killed owner holds the only writer of the guard's input pipe.
    owner_code = """
import subprocess,sys,time
guard=subprocess.Popen([sys.argv[1],'--session-fixture',sys.argv[2]],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
assert guard.stdout.readline().strip()==b'GUARD_READY'
print('GUARD_READY',flush=True)
time.sleep(30)
"""
    owner = subprocess.Popen([sys.executable, "-c", owner_code, executable, folder], stdout=subprocess.PIPE)
    try:
        ready(owner)
        owner.send_signal(signal.SIGKILL)
        owner.wait(timeout=2)
        deadline = time.monotonic() + 1.5  # Session has no expiry; only owner EOF can restore.
        while (root / "preferences.plist").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert not (root / "preferences.plist").exists(), "owner death did not restore configuration"
    finally:
        if owner.poll() is None:
            owner.kill()
            owner.wait()
print("TRACE PROCESS TEST PASS: finite expiry; session survives expiry; EOF, stop and SIGKILL of session owner restore configuration")
