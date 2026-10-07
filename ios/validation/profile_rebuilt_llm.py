# profile_rebuilt_llm.py
# Requirement: capture fresh official Instruments evidence for one rebuilt profile and its actual public synthesis receipt; never reuse old traces or treat profiling timings as unprofiled performance.
import argparse
import ctypes
import time
import uuid
import hashlib
import json
from pathlib import Path
import signal
import subprocess
import sys
import threading


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", choices=["baseline", "q8", "q4_hybrid"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--template", choices=["Core AI", "Time Profiler"], default="Core AI")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    trace = args.output / "new-models.trace"
    notification = "com.actacomes.cosy-rebuild-trace." + str(uuid.uuid4())
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    token, changed = ctypes.c_int(), ctypes.c_int()
    assert system.notify_register_check(notification.encode(), ctypes.byref(token)) == 0
    assert system.notify_check(token, ctypes.byref(changed)) == 0
    command = ["xcrun", "xctrace", "record", "--template", args.template, "--instrument", "Core ML",
               "--instrument", "Points of Interest", "--instrument", "Neural Engine", "--device", "00008150-000A05CA1440401C",
               "--time-limit", "180s", "--output", str(trace), "--all-processes", "--notify-tracing-started", notification]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    ready = threading.Event()

    def forward():
        with (args.output / "trace-console.log").open("w") as handle:
            for line in process.stdout:
                print(line, end="", flush=True)
                handle.write(line)
                handle.flush()


    thread = threading.Thread(target=forward, daemon=True)
    thread.start()
    deadline = time.monotonic() + 45
    while process.poll() is None and time.monotonic() < deadline:
        assert system.notify_check(token, ctypes.byref(changed)) == 0
        if changed.value:
            ready.set()
            break
        time.sleep(0.2)
    system.notify_cancel(token)
    if not ready.is_set():
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
        raise RuntimeError("official trace not ready; preserve console, no inferred ANE PASS")
    collector = Path(__file__).with_name("run_llm_quantization_screen.py")
    request = [sys.executable, str(collector), "--variant", args.variant, "--output", str(args.output / "request"),
               "--artifacts", str(args.artifacts), "--profile-trace", "--sdk-profile-only"]
    result = subprocess.run(request, check=False, cwd=collector.resolve().parents[2])
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
    save_deadline = time.monotonic() + 180
    while True:
        try:
            code = process.wait(timeout=30)
            break
        except subprocess.TimeoutExpired:
            print("[NEW-TRACE] stop/save pending; original trace preserved", flush=True)
            if time.monotonic() >= save_deadline:
                raise RuntimeError("trace stop/save timeout; recover raw ATRC independently, no false trace PASS")
    thread.join(timeout=2)
    binding = {"recordCommand": command, "requestCommand": request, "traceReturnCode": code,
               "requestReturnCode": result.returncode, "tracePath": str(trace),
               "collectorSHA256": hashlib.sha256(collector.read_bytes()).hexdigest(),
               "sourceScriptSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               "scope": "new asset physical profiling, excluded from performance comparison",
               "historicalTraceUsed": False}
    (args.output / "trace-binding.json").write_text(json.dumps(binding, indent=2) + "\n")
    if code == 0:
        subprocess.run(["xcrun", "xctrace", "export", "--input", str(trace), "--toc", "--output",
                        str(args.output / "trace-toc.xml")], check=True)
    if result.returncode or code:
        raise RuntimeError("profile request or trace failed; evidence retained")


if __name__ == "__main__":
    main()
# Purpose: fresh PID/model-hash-bound topology capture; no whole-device energy or 100 percent ANE claim.
# Upstream: accepted q4_hybrid/profile_runner.source.txt official Core AI/Core ML/Points of Interest methodology.
# Environment: local macOS Python3.11/Instruments + wired physical iPhone; generated2026-10-06 America/New_York.
# Changed lines: new parameterized bounded collector; old evidence paths and traces preserved.

# Readiness correction2026-10-06: current xctrace officially exposes --notify-tracing-started; Darwin notification confirms actual start instead of guessing from stdout.
# Initial failed trace/console retained; request/trace data must still pass model-hash/PID attribution afterward.

# Recovery2026-10-06: optional official Time Profiler template retains Core ML/Points of Interest instruments while avoiding Core AI stop/save failure; 30s bounded save polls preserve progress.

# Portability2026-10-06: collector Git binding runs at its own repository root, independent of caller directory.

# TimeProfiler2026-10-06: explicitly add official Neural Engine instrument; Core ML alone does not collect hardware intervals.
