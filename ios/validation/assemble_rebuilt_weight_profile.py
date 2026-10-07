# assemble_rebuilt_weight_profile.py
# Requirement: assemble only new Q8 or Hybrid Q4 from the strictly host-validated rebuilt Current basis; preserve old hard-coded historical recipe scripts and never build Full-Q4.
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def rows(root):
    return [{"path": path.relative_to(root).as_posix(), "bytes": path.stat().st_size, "sha256": sha(path)}
            for path in sorted(root.rglob("*")) if path.is_file() and path.name != "enumerated-production-export-receipt.json"]


def tree(files):
    return hashlib.sha256("".join(f"{row['path']}\0{row['bytes']}\0{row['sha256']}\n"
                                  for row in sorted(files, key=lambda row: row["path"])).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--current", type=Path, required=True)
    parser.add_argument("--current-gate", type=Path, required=True)
    parser.add_argument("--profile", choices=["q8", "hybrid_q4"], required=True)
    parser.add_argument("--q8", type=Path, required=True)
    parser.add_argument("--q8-conversion", type=Path, required=True)
    parser.add_argument("--q8-host", type=Path, required=True)
    parser.add_argument("--hybrid-decode", type=Path)
    parser.add_argument("--hybrid-conversion", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise RuntimeError("preserve existing profile; never overwrite")
    gate = json.loads(args.current_gate.read_text())
    assert gate["status"] == "PASS_CURRENT_STATIC_HOST_GATE"
    current_files = rows(args.current)
    assert tree(current_files) == gate["newCurrentIdentity"]["payloadTreeSHA256"]
    q8 = json.loads(args.q8_conversion.read_text())
    host = json.loads(args.q8_host.read_text())
    assert q8["status"] == "EXPORTED_NOT_VALIDATED" and q8["coremltools"] == "9.0"
    assert host["status"] == "HOST_NUMERICAL_COMPLETE_NOT_QUALITY_PASS" and host["baseline"]["finite"] and host["q8"]["finite"]
    assert q8["config"]["mode"] == "linear_symmetric" and q8["config"]["dtype"] == "int8" and q8["config"]["granularity"] == "per_channel"
    prefill = args.q8 / "cosyvoice-llm-q8-prefill.mlpackage"
    decode = args.q8 / "cosyvoice-llm-q8-decode.mlpackage"
    decode_name = decode.name
    conversions = {"prefill": q8["models"]["prefill"], "decode": q8["models"]["decode"]}
    marker = "Q8_WEIGHT_ONLY_UNPROMOTED"
    if args.profile == "hybrid_q4":
        assert args.hybrid_decode and args.hybrid_conversion
        hybrid = json.loads(args.hybrid_conversion.read_text())
        assert hybrid["status"] == "EXPORTED_NOT_VALIDATED" and list(hybrid["models"]) == ["decode"]
        assert hybrid["config"]["mode"] == "linear_symmetric" and hybrid["config"]["dtype"] == "int4" and hybrid["config"]["granularity"] == "per_channel"
        decode = args.hybrid_decode / "cosyvoice-llm-q4-decode.mlpackage"
        decode_name = "cosyvoice-llm-q4-rescue-a-decode.mlpackage"
        conversions["decode"] = hybrid["models"]["decode"]
        marker = "Q4_DECODE_HYBRID_A_Q8_PREFILL_INT4_PER_CHANNEL_DECODE"
    for role, package in [("prefill", prefill), ("decode", decode)]:
        assert tree(rows(package)) == conversions[role]["outputIdentity"]["treeSha256"]
        assert len(conversions[role]["selectedWeightNames"]) == 169
        assert conversions[role]["stateAndDescriptionByteIdentical"] and conversions[role]["deploymentAndSpecificationUnchanged"]
    manifest = json.loads((args.current / "cosyvoice3_enumerated.json").read_text())
    old_paths = [manifest["llmPrefill"], manifest["llmDecode"]]
    reuse = [row for row in current_files if row["path"] != "cosyvoice3_enumerated.json"
             and not any(row["path"].startswith(prefix + "/") for prefix in old_paths)]
    args.output.mkdir(parents=True)
    for row in reuse:
        relative = Path(row["path"])
        assert not relative.is_absolute() and ".." not in relative.parts
        destination = args.output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.link(args.current / relative, destination)
    for package, name in [(prefill, prefill.name), (decode, decode_name)]:
        shutil.copytree(package, args.output / "models" / name, copy_function=os.link)
    manifest.update(llmPrefill="models/" + prefill.name, llmDecode="models/" + decode_name, experimentalLLMVariant=marker)
    (args.output / "cosyvoice3_enumerated.json").write_text(json.dumps(manifest, indent=2) + "\n")
    files = rows(args.output)
    receipt = {"schemaVersion": 1, "status": "NEW_PROFILE_ASSEMBLED_PENDING_PHYSICAL_AND_HUMAN",
               "profileID": args.profile, "parentPayloadTreeSHA256": tree(current_files),
               "payloadTreeSha256": tree(files), "payloadBytes": sum(row["bytes"] for row in files),
               "manifestSHA256": sha(args.output / "cosyvoice3_enumerated.json"),
               "prefillSHA256": tree(rows(prefill)), "decodeSHA256": tree(rows(decode)),
               "sourceCommit": q8["sourceCommit"], "reuseFiles": reuse,
               "candidateFiles": [row for row in files if row not in reuse], "allFiles": files,
               "prefillRepresentation": "INT8 per-channel", "decodeRepresentation": "INT4 per-channel" if args.profile == "hybrid_q4" else "INT8 per-channel",
               "stateBridgeMode": "Q8-prefill -> Q4-decode request-level FP16 state-copy bridge" if args.profile == "hybrid_q4" else "shared FP16 MLState",
               "productionPromotion": False, "FullQ4PrefillIncluded": False}
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print("[REBUILD-PROFILE]", args.profile, receipt["payloadTreeSha256"], "PENDING_PHYSICAL_AND_HUMAN", flush=True)


if __name__ == "__main__":
    main()
# Purpose: new identity assembly after strict Current host validation, never replacing old historical recipe gates.
# Upstream: accepted matrix quantizer, original profile recipe layout and immutable Current content identity.
# Environment: local macOS Python3.11; generated2026-10-06 America/New_York.
# Changed lines: new file; exact file/parent/model/169-matrix/IO/spec checks precede output creation.
