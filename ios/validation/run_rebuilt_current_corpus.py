# run_rebuilt_current_corpus.py
# Requirement: execute and export all six original Current listening cases through signed public synthesis, preserving actual WAVs for exact historical comparison or new human review.
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    args.artifacts.mkdir(parents=True, exist_ok=True)
    bundle = "com.actacomes.cosyvoice3.candidatebenchmark"
    device = "00008150-000A05CA1440401C"
    command = ["xcrun", "devicectl", "device", "process", "launch", "--device", device, "--terminate-existing",
               "--console", bundle, "--", "--no-playback", "--validation-listening-checkpoint",
               "--validation-flow-partition=2", "--validation-acoustic-cache=selected-family"]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    done = threading.Event()

    def forward():
        with (args.output / "console.log").open("w") as handle:
            for line in process.stdout:
                print(line, end="", flush=True)
                handle.write(line)
                handle.flush()
                if "[COSY-AUTO-DONE]" in line:
                    done.set()

    threading.Thread(target=forward, daemon=True).start()
    deadline = time.monotonic() + 600
    while not done.wait(20):
        print("[REBUILD-CORPUS] pending; no timed device readback", flush=True)
        if process.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError("six-case corpus incomplete; console preserved")

    def pull(name, destination):
        subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", device,
                        "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                        "--source", "Documents/" + name, "--destination", str(destination)], check=True)

    receipt = args.output / "listening-checkpoint-receipt.json"
    pull(receipt.name, receipt)
    value = json.loads(receipt.read_text())
    assert value["status"] == "PASS_DEVICE_CORPUS_PENDING_HUMAN" and len(value["samples"]) == 6
    artifacts = []
    for row in value["samples"]:
        destination = args.artifacts / row["WAV"]
        pull(row["WAV"], destination)
        assert hashlib.sha256(destination.read_bytes()).hexdigest() == row["WAV_SHA256"]
        artifacts.append({"id": row["id"], "path": str(destination.resolve()), "sha256": row["WAV_SHA256"]})
    (args.output / "host-collection.json").write_text(json.dumps({"command": command, "artifacts": artifacts,
                "humanListening": "PENDING_EXACT_APPROVED_CORPUS_COMPARISON_OR_NEW_HUMAN", "sourceCommit": value["sourceCommit"]}, indent=2) + "\n")
    print("[REBUILD-CORPUS] all six actual device WAVs exported", flush=True)


if __name__ == "__main__":
    main()
# Purpose: complete fixed-corpus revalidation, without automatic historical HUMAN_PASS transfer.
# Upstream: existing native runListeningCheckpoint and accepted corpus_v1.json; original texts/reference/seed/Flow6/SHARDS2.
# Environment: macOS Python3.11 + wired physical iPhone signed Release; generated2026-10-06 America/New_York.
# Changed lines: new host collector; no native algorithm, sampling, timing or tolerance changes.
