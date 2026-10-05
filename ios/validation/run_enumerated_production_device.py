#!/usr/bin/env python3
#@title run_enumerated_production_device.py
# Requirement: validate and stage the locally built schema-3 N1...450 exact-enumerated production asset root to a physical iPhone outside the app bundle, then run public default/reference smoke and Candidate cold/warm benchmark against the exact Git/runtime-manifest identity.
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
VALIDATOR = ROOT / "assets/validate_assets.py"
PROJECT = ROOT / "validation/DeviceSmoke/CosyVoice3DeviceSmoke.xcodeproj"
SCHEME = "CosyVoice3DeviceSmoke"


def run(command, *, capture=False):
    values = [str(value) for value in command]
    print("[COSY-ENUMERATED-DEVICE] RUN " + " ".join(values), flush=True)
    if capture:
        return subprocess.check_output(values, text=True).strip()
    return subprocess.run(values, check=True)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def json_write(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def device_copy_domain(device: str, bundle: str) -> list[str]:
    return [
        "--device", device,
        "--domain-type", "appDataContainer",
        "--domain-identifier", bundle,
    ]


def copy_to(device: str, bundle: str, source: Path, destination: str) -> None:
    run([
        "xcrun", "devicectl", "device", "copy", "to",
        *device_copy_domain(device, bundle),
        "--source", source.resolve(),
        "--destination", destination,
    ])


def copy_from(device: str, bundle: str, source: str, destination: Path) -> None:
    if destination.exists():
        destination.unlink()
    run([
        "xcrun", "devicectl", "device", "copy", "from",
        *device_copy_domain(device, bundle),
        "--source", source,
        "--destination", destination,
    ])


def launch_with_console(device: str, bundle: str, output: Path, extra_args: list[str]) -> subprocess.Popen:
    command = [
        "xcrun", "devicectl", "device", "process", "launch",
        "--device", device,
        "--terminate-existing",
        "--console",
        bundle,
    ]
    if extra_args:
        command += ["--", *extra_args]
    print("[COSY-ENUMERATED-DEVICE] RUN " + " ".join(command), flush=True)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def forward():
        assert process.stdout is not None
        with output.open("w") as handle:
            for line in process.stdout:
                print(line, end="", flush=True)
                handle.write(line)
                handle.flush()

    threading.Thread(target=forward, daemon=True).start()
    return process


def wait_receipt(
    *,
    device: str,
    bundle: str,
    filename: str,
    output: Path,
    process: subprocess.Popen,
    started: float,
    timeout: int,
) -> dict:
    destination = output / filename
    last_phase = None
    while time.time() - started < timeout:
        time.sleep(10)
        try:
            copy_from(device, bundle, "Documents/" + filename, destination)
            receipt = json.loads(destination.read_text())
            if float(receipt.get("recordedAtUnix", 0)) < started - 2:
                print("[COSY-ENUMERATED-DEVICE] stale receipt ignored", flush=True)
                continue
            phase = receipt.get("phase", receipt.get("status"))
            if phase != last_phase:
                print(f"[COSY-ENUMERATED-DEVICE] receipt phase={phase}", flush=True)
                last_phase = phase
            status = str(receipt.get("status", ""))
            if status == "RUNNING":
                continue
            if not status.startswith("PASS_"):
                raise RuntimeError(f"device receipt failed: {receipt}")
            return receipt
        except subprocess.CalledProcessError as error:
            print(f"[COSY-ENUMERATED-DEVICE] receipt unavailable: {error}", flush=True)
        if process.poll() is not None:
            raise RuntimeError(f"device process ended before final {filename}; inspect console log")
    raise RuntimeError(f"timeout waiting for {filename}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asset-root", type=Path, required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--reference-wav", type=Path, required=True)
    parser.add_argument("--reference-transcript", type=Path, required=True)
    parser.add_argument("--host-receipt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--bundle", default="com.actacomes.cosyvoice3.enumerated")
    parser.add_argument("--reuse-staging", action="store_true")
    parser.add_argument("--skip-variable-smoke", action="store_true")
    parser.add_argument("--skip-candidate-benchmark", action="store_true")
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()

    asset_root = args.asset_root.expanduser().resolve()
    reference_wav = args.reference_wav.expanduser().resolve()
    reference_transcript = args.reference_transcript.expanduser().resolve()
    host_receipt = args.host_receipt.expanduser().resolve()
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)

    run(["python3", VALIDATOR, "--root", asset_root, "--require-reference"])
    manifest_path = asset_root / "cosyvoice3_enumerated.json"
    manifest = json.loads(manifest_path.read_text())
    contract = manifest.get("enumeratedAcoustic") or {}
    if manifest.get("schemaVersion") != 3 or manifest.get("profile") != "ios18-enumerated-n1-n450":
        raise RuntimeError("asset root is not the production enumerated profile")
    if (
        int(contract.get("speechTokenMinimum", 0)),
        int(contract.get("speechTokenMaximum", 0)),
        int(contract.get("logicalPrefixMaximumForFullSpeechWindow", -1)),
    ) != (1, 450, 62):
        raise RuntimeError("enumerated production N/ctx contract mismatch")
    host = json.loads(host_receipt.read_text())
    if host.get("schemaVersion") != 2 or host.get("status") != "PASS_HOST_PARITY":
        raise RuntimeError("host reference receipt is not schema-2 PASS_HOST_PARITY")
    if not reference_wav.is_file() or not reference_transcript.is_file():
        raise RuntimeError("reference WAV/transcript missing")

    source = run(["git", "-C", REPO, "rev-parse", "HEAD"], capture=True)
    manifest_sha = sha256(manifest_path)
    host_sha = sha256(host_receipt)
    staging = {
        "schemaVersion": 1,
        "status": "LOCAL_ENUMERATED_VALIDATION_STAGING",
        "sourceCommit": source,
        "runtimeManifestName": manifest_path.name,
        "runtimeManifestSha256": manifest_sha,
        "profile": manifest["profile"],
        "speechTokenBounds": [1, 450],
        "logicalPrefixMaximumForFullSpeechWindow": 62,
        "hostReceiptSha256": host_sha,
        "recordedAtUnix": int(time.time()),
    }
    staging_path = output / "staging-complete.json"
    json_write(staging_path, staging)
    variable_marker = {
        "schemaVersion": 1,
        "benchmark": "variable-public-api-default-and-reference-v1",
        "sourceCommit": source,
        "hostReceiptSha256": host_sha,
        "runtimeManifestSha256": manifest_sha,
        "activeManifest": manifest_path.name,
        "activeProfile": manifest["profile"],
    }
    variable_marker_path = output / "variable-public-api-smoke-mode.json"
    json_write(variable_marker_path, variable_marker)

    derived = ROOT / ".work/EnumeratedProductionDeviceDerivedData"
    run([
        "xcodebuild",
        "-project", PROJECT,
        "-scheme", SCHEME,
        "-configuration", "Release",
        "-destination", "id=" + args.device,
        "-derivedDataPath", derived,
        "SYMROOT=" + str(derived / "Build/Products"),
        "OBJROOT=" + str(derived / "Build/Intermediates.noindex"),
        "DEVELOPMENT_TEAM=" + args.team,
        "PRODUCT_BUNDLE_IDENTIFIER=" + args.bundle,
        "-allowProvisioningUpdates",
        "build",
    ])
    app = derived / "Build/Products/Release-iphoneos/CosyVoice3DeviceSmoke.app"
    run(["xcrun", "devicectl", "device", "install", "app", "--device", args.device, app])

    if not args.reuse_staging:
        copy_to(args.device, args.bundle, asset_root, "Documents/GeneratedAssets/Runtime")
    for path, destination in [
        (reference_wav, "Documents/GeneratedAssets/reference.wav"),
        (reference_transcript, "Documents/GeneratedAssets/reference.txt"),
        (staging_path, "Documents/GeneratedAssets/staging-complete.json"),
        (variable_marker_path, "Documents/GeneratedAssets/variable-public-api-smoke-mode.json"),
    ]:
        copy_to(args.device, args.bundle, path, destination)

    evidence = {
        "schemaVersion": 1,
        "status": "RUNNING",
        "sourceCommit": source,
        "runtimeManifestSha256": manifest_sha,
        "profile": manifest["profile"],
        "device": args.device,
        "bundle": args.bundle,
        "stagingReused": args.reuse_staging,
        "runs": {},
    }
    evidence_path = output / "enumerated-production-device-evidence.json"
    json_write(evidence_path, evidence)

    if not args.skip_variable_smoke:
        started = time.time()
        process = launch_with_console(
            args.device,
            args.bundle,
            output / "variable-public-api-console.log",
            [],
        )
        receipt = wait_receipt(
            device=args.device,
            bundle=args.bundle,
            filename="variable-public-api-smoke-receipt.json",
            output=output,
            process=process,
            started=started,
            timeout=args.timeout,
        )
        for name in ("variable-default.wav", "variable-reference.wav"):
            copy_from(args.device, args.bundle, "Documents/" + name, output / name)
        evidence["runs"]["variablePublicAPI"] = {
            "status": receipt["status"],
            "receiptSha256": sha256(output / "variable-public-api-smoke-receipt.json"),
            "defaultWavSha256": sha256(output / "variable-default.wav"),
            "referenceWavSha256": sha256(output / "variable-reference.wav"),
        }
        json_write(evidence_path, evidence)

    if not args.skip_candidate_benchmark:
        started = time.time()
        process = launch_with_console(
            args.device,
            args.bundle,
            output / "candidate-benchmark-console.log",
            ["--candidate-benchmark"],
        )
        receipt = wait_receipt(
            device=args.device,
            bundle=args.bundle,
            filename="candidate-benchmark-receipt.json",
            output=output,
            process=process,
            started=started,
            timeout=args.timeout,
        )
        evidence["runs"]["candidateBenchmark"] = {
            "status": receipt["status"],
            "receiptSha256": sha256(output / "candidate-benchmark-receipt.json"),
            "firstRTF": receipt.get("firstRTF"),
            "repeatRTF": receipt.get("repeatRTF"),
            "firstSamples": receipt.get("firstSamples"),
            "repeatSamples": receipt.get("repeatSamples"),
            "acousticShapeMode": receipt.get("acousticShapeMode"),
            "enumeratedAcousticExecution": receipt.get("enumeratedAcousticExecution"),
        }
        json_write(evidence_path, evidence)

    evidence["status"] = "PASS_ENUMERATED_PRODUCTION_DEVICE_VALIDATION"
    evidence["completedAtUnix"] = int(time.time())
    json_write(evidence_path, evidence)
    print(f"[COSY-ENUMERATED-DEVICE] PASS evidence={evidence_path}", flush=True)


if __name__ == "__main__":
    main()

# Code purpose: one-command signed physical-device validation for the final N1...450 exact EnumeratedShapes/multifunction CosyVoice3 production architecture without embedding multi-GB assets in the app bundle.
# Upstream source: schema-3 exporter/validator, existing public CosyVoice3Engine DeviceSmoke app, and the accepted devicectl external-staging workflow.
# Runtime environment: macOS Apple Silicon, Xcode 27+, Python 3, connected physical iPhone, valid Apple development team.
# Generated time: 2026-10-05 America/New_York.
# Changed lines: new file; exact Git/manifest/host-receipt binding, external asset staging, variable public API default/reference run, Candidate cold/warm run, durable evidence JSON and console logs.

# Changes 2026-10-05: match the already validated devicectl copy grammar exactly: copy to/from subcommand precedes appDataContainer domain flags.
