#!/usr/bin/env python3
#@title record_release_environment.py
# Requirement: record the canonical macOS Apple-Silicon release/build/validation environment required by the shared SDK checklist. Fail closed when the host is not Darwin arm64 or required Apple toolchain identity is unavailable. Optionally bind one physical-device receipt.
from __future__ import annotations
import argparse,json,os,platform,re,subprocess,time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parent

def run(*args:str)->str:
    p=subprocess.run(list(args),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=False)
    if p.returncode!=0: raise RuntimeError(f"command failed rc={p.returncode}: {' '.join(args)}\n{p.stdout}")
    return p.stdout.strip()

def load(path:Path)->dict:
    value=json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value,dict): raise RuntimeError(f"JSON object required: {path}")
    return value

def main()->int:
    p=argparse.ArgumentParser()
    p.add_argument("--device-receipt",type=Path)
    p.add_argument("--asset-profile")
    p.add_argument("--asset-version")
    p.add_argument("--output",type=Path,default=ROOT/"validation/evidence/release_environment.json")
    a=p.parse_args()

    system=platform.system(); arch=platform.machine()
    if system!="Darwin" or arch!="arm64":
        raise RuntimeError(f"canonical release host must be Darwin arm64, observed {system} {arch}")

    sw=run("sw_vers")
    hardware=run("system_profiler","SPHardwareDataType")
    model=re.search(r"^\s*Model Name:\s*(.+)$",hardware,re.M)
    chip=re.search(r"^\s*Chip:\s*(.+)$",hardware,re.M)
    if not model or not chip: raise RuntimeError("could not resolve Mac hardware model/chip")
    host_model=model.group(1).strip(); host_chip=chip.group(1).strip()
    canonical_host=(host_model=="Mac mini" and host_chip.startswith("Apple M4"))
    compatible_override=os.environ.get("COSYVOICE3_ALLOW_COMPATIBLE_RELEASE_MAC")=="1"
    if not canonical_host and not compatible_override:
        raise RuntimeError(f"canonical release host must be Mac mini / Apple M4; observed {host_model} / {host_chip}")

    xcode=run("xcodebuild","-version")
    swift=run("swift","--version")
    sdk=run("xcrun","--sdk","iphoneos","--show-sdk-version")
    sdk_path=run("xcrun","--sdk","iphoneos","--show-sdk-path")
    clang=run("xcrun","clang","--version").splitlines()[0]
    head=run("git","-C",str(REPO),"rev-parse","HEAD")

    package=(ROOT/"Package.swift").read_text(encoding="utf-8")
    target=re.search(r"\.iOS\(\.v(\d+)\)",package)
    deployment=f"iOS {target.group(1)}+" if target else "documented Package.swift platform"
    tools=re.search(r"swift-tools-version:\s*([0-9.]+)",package)
    swift_language_mode=f"Swift {tools.group(1)} package language mode" if tools else "Package.swift-defined Swift language mode"

    device=None
    if a.device_receipt:
        raw=load(a.device_receipt.expanduser().resolve())
        nested=raw.get("device") if isinstance(raw.get("device"),dict) else {}
        device={
            "model":nested.get("model") or raw.get("device"),
            "modelIdentifier":nested.get("modelIdentifier") or raw.get("deviceModelIdentifier") or raw.get("modelIdentifier"),
            "systemName":nested.get("systemName") or raw.get("systemName") or "iOS",
            "systemVersion":nested.get("systemVersion") or raw.get("systemVersion"),
        }
        if not device["modelIdentifier"] or not device["systemVersion"]:
            raise RuntimeError("device receipt does not contain physical modelIdentifier/systemVersion")

    receipt={
        "schemaVersion":1,
        "status":"PASS_RELEASE_ENVIRONMENT_RECORDED",
        "sourceCommit":head,
        "environment":{
            "cleanRoomHost":f"{host_model} ({host_chip}), {sw.replace(chr(10),' | ')}",
            "releaseHost":"macOS Apple Silicon",
            "canonicalReferenceHost":"Mac mini / Apple M4",
            "canonicalReferenceHostMatched":canonical_host,
            "compatibleHostOverride":compatible_override,
            "hostSystem":system,
            "hostArchitecture":arch,
            "hostModel":host_model,
            "hostChip":host_chip,
            "macOS":sw,
            "xcode":xcode,
            "appleSDK":sdk,
            "appleSDKPath":sdk_path,
            "swift":swift,
            "swiftLanguageMode":swift_language_mode,
            "clang":clang,
            "deploymentTarget":deployment,
            "validationTarget":device,
            "toolchain":f"{xcode.replace(chr(10),' / ')}; iPhoneOS SDK {sdk}; {swift.splitlines()[0]}; {swift_language_mode}",
            "consumerRequirements":f"macOS Apple Silicon clean-room host; Swift package; {deployment}; immutable validated CosyVoice3 asset root",
            "historicalAssetBuildProvenance":"Non-Mac conversion provenance may be retained only behind immutable hash-bound assets; it is not part of the Candidate/Production clean-room consumer path."
        },
        "assetSelection":{
            "profile":a.asset_profile,
            "version":a.asset_version
        },
        "validationTarget":device,
        "recordedAtUnix":int(time.time())
    }
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    print("[COSYVOICE3-RELEASE-ENV] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
    return 0

if __name__=="__main__": raise SystemExit(main())

# Code purpose: capture exact canonical Mac release host, Xcode/Swift/iPhoneOS SDK/deployment identity and optional physical-device identity for Candidate/Production release receipts.
# Upstream source: canonical NPU_engines_Demo SDK_RELEASE.md environment block.
# Runtime environment: macOS Apple Silicon release host with Xcode command-line tools.
# Generated time: 2026-10-04 America/New_York.
# Changes: new fail-closed environment recorder; no hard-coded workstation-specific absolute paths.

# Changes 2026-10-04: device binding accepts both raw DeviceSmoke receipts and sanitized Candidate benchmark receipts with nested device metadata.

# Changes 2026-10-04: canonical Candidate environment now requires Mac mini with Apple M4 by default; a non-reference Apple-Silicon Mac requires explicit COSYVOICE3_ALLOW_COMPATIBLE_RELEASE_MAC=1 and the override is recorded rather than hidden.

# Changes 2026-10-04: environment block now contains validationTarget directly as required by the canonical receipt schema and records the Package.swift Swift language mode/tools version.
