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


def payload_rows(root: Path) -> list[dict]:
    rows = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        if path.name == "enumerated-production-export-receipt.json" or ".family-build" in path.parts:
            continue
        rows.append({
            "path": path.relative_to(root).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
        })
    return rows


def payload_tree_identity(rows: list[dict]) -> str:
    digest = hashlib.sha256()
    for row in sorted(rows, key=lambda item: item["path"]):
        digest.update(row["path"].encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(int(row["bytes"])).encode("ascii"))
        digest.update(b"\0")
        digest.update(row["sha256"].encode("ascii"))
        digest.update(b"\n")
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
    parser.add_argument("--bundle", default="com.actacomes.cosyvoice3.candidatebenchmark")
    parser.add_argument("--reuse-staging", action="store_true")
    parser.add_argument("--skip-variable-smoke", action="store_true")
    parser.add_argument("--skip-candidate-benchmark", action="store_true")
    parser.add_argument("--diagnostic-enumerated-compute", choices=("production", "cpu-gpu", "cpu-only"), default="production")
    parser.add_argument("--placement", action="append", default=[], help="role:CPU_ONLY|CPU_AND_GPU|CPU_AND_NE; validation only")
    parser.add_argument("--single-function", action="append", default=[])
    parser.add_argument("--sustained-count", type=int, default=0)
    parser.add_argument("--acoustic-cache", choices=("none","small","decoder","selected-family"), default="none")
    parser.add_argument("--wait-thermal-nominal", action="store_true")
    parser.add_argument("--reset-reference-conditioning", action="store_true")
    parser.add_argument("--skip-build", action="store_true", help="reuse the already installed exact diagnostic host")
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
    export_receipt_path = asset_root / "enumerated-production-export-receipt.json"
    if not export_receipt_path.is_file():
        raise RuntimeError("enumerated production export receipt missing from asset root")
    manifest = json.loads(manifest_path.read_text())
    export_receipt = json.loads(export_receipt_path.read_text())
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
    if export_receipt.get("profile") != "ios18-enumerated-n1-n450" or not str(export_receipt.get("status", "")).startswith("PASS_"):
        raise RuntimeError("enumerated export receipt is not a completed PASS")
    if export_receipt.get("manifest", {}).get("sha256") != sha256(manifest_path):
        raise RuntimeError("enumerated export receipt manifest hash mismatch")
    rows = payload_rows(asset_root)
    local_payload_tree = payload_tree_identity(rows)
    local_payload_bytes = sum(int(row["bytes"]) for row in rows)
    if export_receipt.get("payloadTreeSha256") != local_payload_tree:
        raise RuntimeError("enumerated payload tree hash mismatch")
    if int(export_receipt.get("payloadBytes", -1)) != local_payload_bytes:
        raise RuntimeError("enumerated payload byte count mismatch")
    if not reference_wav.is_file() or not reference_transcript.is_file():
        raise RuntimeError("reference WAV/transcript missing")

    source = run(["git", "-C", REPO, "rev-parse", "HEAD"], capture=True)
    asset_export_source = str(export_receipt.get("sourceCommit", ""))
    if len(asset_export_source) != 40:
        raise RuntimeError("enumerated export receipt sourceCommit missing")
    runtime_changed = run(
        ["git", "-C", REPO, "diff", "--name-only", asset_export_source, source, "--", "ios/Package.swift", "ios/Sources"],
        capture=True,
    ).splitlines()
    diagnostic_compute = args.diagnostic_enumerated_compute != "production" or bool(args.placement) or bool(args.single_function) or args.acoustic_cache != "none"
    diagnostic_allowed_runtime_files = {"ios/Sources/CosyVoice3Core/CosyVoice3AssetLoader.swift"}
    if runtime_changed and not (
        diagnostic_compute
        and set(runtime_changed).issubset(diagnostic_allowed_runtime_files)
    ):
        raise RuntimeError(
            "shipping iOS runtime changed after enumerated asset export; rebuild assets before device validation: "
            + ",".join(runtime_changed)
        )
    manifest_sha = sha256(manifest_path)
    export_receipt_sha = sha256(export_receipt_path)
    host_sha = sha256(host_receipt)
    staging = {
        "schemaVersion": 1,
        "status": "LOCAL_ENUMERATED_VALIDATION_STAGING",
        "sourceCommit": source,
        "runtimeManifestName": manifest_path.name,
        "runtimeManifestSha256": manifest_sha,
        "exportReceiptSha256": export_receipt_sha,
        "payloadTreeSha256": local_payload_tree,
        "payloadBytes": local_payload_bytes,
        "assetExportSourceCommit": asset_export_source,
        "profile": manifest["profile"],
        "speechTokenBounds": [1, 450],
        "logicalPrefixMaximumForFullSpeechWindow": 62,
        "hostReceiptSha256": host_sha,
        "recordedAtUnix": int(time.time()),
        "diagnosticEnumeratedCompute": args.diagnostic_enumerated_compute,
        "requestedRoleOverrides": args.placement,
        "experimentalSingleFunctionRoles": args.single_function,
        "diagnosticRuntimeChangedFiles": runtime_changed,
        "productionPromotion": False if diagnostic_compute else None,
    }
    staging_path = output / "staging-complete.json"
    json_write(staging_path, staging)
    variable_marker = {
        "schemaVersion": 1,
        "benchmark": "variable-public-api-default-and-reference-v1",
        "sourceCommit": source,
        "hostReceiptSha256": host_sha,
        "runtimeManifestSha256": manifest_sha,
        "exportReceiptSha256": export_receipt_sha,
        "payloadTreeSha256": local_payload_tree,
        "payloadBytes": local_payload_bytes,
        "assetExportSourceCommit": asset_export_source,
        "activeManifest": manifest_path.name,
        "activeProfile": manifest["profile"],
    }
    variable_marker_path = output / "variable-public-api-smoke-mode.json"
    json_write(variable_marker_path, variable_marker)

    derived = ROOT / ".work/EnumeratedProductionDeviceDerivedData"
    build_marker = ROOT / "validation/DeviceSmoke/GeneratedAssets/validation-build-source.json"
    if not args.skip_build:
        build_marker.parent.mkdir(parents=True, exist_ok=True)
        json_write(build_marker, {"sourceCommit": source})
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
            "-allowProvisioningDeviceRegistration",
            "build",
        ])
        app = derived / "Build/Products/Release-iphoneos/CosyVoice3DeviceSmoke.app"
        if not args.reuse_staging:
            uninstall = [
                "xcrun", "devicectl", "device", "uninstall", "app",
                "--device", args.device, args.bundle,
            ]
            print("[COSY-ENUMERATED-DEVICE] RUN " + " ".join(uninstall), flush=True)
            removed = subprocess.run(uninstall, check=False)
            print(f"[COSY-ENUMERATED-DEVICE] clean-container uninstall returnCode={removed.returncode}", flush=True)
        run(["xcrun", "devicectl", "device", "install", "app", "--device", args.device, app])

    if not args.reuse_staging:
        copy_to(args.device, args.bundle, asset_root, "Documents/GeneratedAssets/Runtime")
    if args.reuse_staging:
        previous = output / "previous-device-staging.json"
        copy_from(args.device, args.bundle, "Documents/GeneratedAssets/staging-complete.json", previous)
        remote = json.loads(previous.read_text())
        for key in ("payloadTreeSha256", "payloadBytes", "runtimeManifestSha256", "assetExportSourceCommit"):
            if remote.get(key) != staging[key]:
                raise RuntimeError(f"reuse staging identity mismatch: {key}")
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
        "exportReceiptSha256": export_receipt_sha,
        "payloadTreeSha256": local_payload_tree,
        "payloadBytes": local_payload_bytes,
        "assetExportSourceCommit": asset_export_source,
        "profile": manifest["profile"],
        "device": args.device,
        "bundle": args.bundle,
        "stagingReused": args.reuse_staging,
        "diagnosticEnumeratedCompute": args.diagnostic_enumerated_compute,
        "requestedRoleOverrides": args.placement,
        "experimentalSingleFunctionRoles": args.single_function,
        "diagnosticRuntimeChangedFiles": runtime_changed,
        "productionPromotion": False if diagnostic_compute else None,
        "runs": {},
    }
    evidence_path = output / "enumerated-production-device-evidence.json"
    json_write(evidence_path, evidence)

    try:
        if not args.skip_candidate_benchmark:
            started = time.time()
            candidate_args = ["--candidate-benchmark", "--no-playback", "--reset-cosy-cache"]
            if args.diagnostic_enumerated_compute == "cpu-gpu":
                candidate_args.append("--validation-enumerated-cpu-gpu")
            elif args.diagnostic_enumerated_compute == "cpu-only":
                candidate_args.append("--validation-enumerated-cpu-only")
            candidate_args.append("--validation-sustained-count=" + str(args.sustained_count))
            candidate_args.append("--validation-acoustic-cache=" + args.acoustic_cache)
            candidate_args += ["--validation-placement=" + item for item in args.placement]
            candidate_args += ["--validation-single-function=" + item for item in args.single_function]
            if args.wait_thermal_nominal:
                candidate_args.append("--wait-thermal-nominal")
            if args.reset_reference_conditioning:
                candidate_args.append("--reset-reference-conditioning")
            process = launch_with_console(
                args.device,
                args.bundle,
                output / "candidate-benchmark-console.log",
                candidate_args,
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
                "thermalStart": receipt.get("thermalStart"),
                "thermalEnd": receipt.get("thermalEnd"),
                "validationSamplerSeed": receipt.get("validationSamplerSeed"),
                "matchedDeterministicSpeechLength": receipt.get("matchedDeterministicSpeechLength"),
                "matchedDeterministicWav": receipt.get("matchedDeterministicWav"),
                "firstWavSha256": receipt.get("firstWavSha256"),
                "repeatWavSha256": receipt.get("repeatWavSha256"),
                "validationCacheReset": receipt.get("validationCacheReset"),
                "requestedComputePlacement": receipt.get("requestedComputePlacement"),
            }
            json_write(evidence_path, evidence)
    except Exception as exc:
        evidence["status"] = "FAIL_CANDIDATE_BENCHMARK"
        evidence["error"] = f"{type(exc).__name__}: {exc}"
        evidence["completedAtUnix"] = int(time.time())
        json_write(evidence_path, evidence)
        raise

    try:
        if not args.skip_variable_smoke:
            started = time.time()
            process = launch_with_console(
                args.device,
                args.bundle,
                output / "variable-public-api-console.log",
                ["--no-playback"],
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
    except Exception as exc:
        evidence["status"] = "FAIL_VARIABLE_PUBLIC_API_SMOKE"
        evidence["error"] = f"{type(exc).__name__}: {exc}"
        evidence["completedAtUnix"] = int(time.time())
        json_write(evidence_path, evidence)
        raise

    evidence["status"] = "PASS_ENUMERATED_DIAGNOSTIC_DEVICE_VALIDATION" if diagnostic_compute else "PASS_ENUMERATED_PRODUCTION_DEVICE_VALIDATION"
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

# Changes 2026-10-05: enumerated physical benchmark reuses the already-provisioned candidate benchmark bundle ID instead of inventing a new App ID/profile; Xcode build also allows device registration consistently with the existing DeviceSmoke installer. Explicit --bundle override remains supported.

# Changes 2026-10-05: automated variable smoke and Candidate benchmark now pass --no-playback. Candidate app itself requires nominal thermal start, so validation cannot silently accept a smoke-heated performance run.

# Changes 2026-10-05: run the strict nominal-start Candidate benchmark before any full synthesis smoke. Correctness default/reference smoke runs afterward, so its compute heat cannot contaminate cold/warm performance evidence.

# Changes 2026-10-05: Candidate launch resets only validation-app CosyVoice3 compiled/warm caches before the first measurement, preventing prior same-bundle runs from masquerading as a cold benchmark.

# Changes 2026-10-05: physical schema-3 validation now re-hashes the complete shipping payload tree, verifies it against the exporter receipt, binds payload bytes/tree/export-receipt SHA into staging/evidence, and rejects runtime-source changes after asset export. Manifest-only identity is no longer sufficient.

# Changes 2026-10-05: non-reuse validation now best-effort uninstalls the prior validation bundle before install, forcing a fresh app data container and preventing stale Runtime/Documents/Library cache files from contaminating clean-room evidence. --reuse-staging intentionally preserves the existing container.

# Changes 2026-10-05: host physical-validation evidence now closes fail-stop as FAIL_CANDIDATE_BENCHMARK or FAIL_VARIABLE_PUBLIC_API_SMOKE with exact error/completion time before rethrowing. A failed run no longer leaves the top-level evidence permanently RUNNING.

# Changes 2026-10-05: top-level device evidence now surfaces Candidate thermal start/end, deterministic seed/matched-length gate, and cache-reset status instead of requiring later readers to reopen the raw receipt for benchmark comparability.

# Changes 2026-10-05: top-level Candidate summary now carries the deterministic WAV equality gate and both WAV SHA256 values, making matched cold/warm workload identity visible without reopening the raw device receipt.

# Changes 2026-10-05: add explicit non-promotable schema-3 compute-placement probes (cpu-gpu/cpu-only). Diagnostic mode may cross only the known AssetLoader validation-probe source diff, records that diff and placement in evidence, reuses identical asset bytes, and never labels the run Production validation.

# Changes 2026-10-05 19:15 America/New_York: argparse/main allow independent role overrides, exact installed host reuse, and verify frozen staging identity before marker update. Purpose: placement diagnostics; upstream existing enumerated device runner; environment macOS/Xcode/physical iPhone.
