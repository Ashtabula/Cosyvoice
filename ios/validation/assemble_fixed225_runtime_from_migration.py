#!/usr/bin/env python3
# assemble_fixed225_runtime_from_migration.py
# Requirement: assemble a standalone fixed225 SDK runtime asset root from already validated CosyVoice3_NPU iOS migration assets without mutating the source repository.
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORT_FRONTEND = ROOT / "tools/export_frontend_tables.py"
VALIDATE_ASSETS = ROOT / "assets/validate_assets.py"

SOURCE_COMMIT = "878940245562bcd1dd0231d78157ba78d70b39f6"
MODEL_RELATIVE = Path("pretrained_models/Fun-CosyVoice3-0.5B-2512")


def fail(message: str) -> None:
    raise RuntimeError(message)


def run(command: list[str | Path]) -> None:
    values = [str(value) for value in command]
    print("[COSYVOICE3-RUNTIME-ASSEMBLY] RUN " + " ".join(values), flush=True)
    subprocess.run(values, check=True)


def require(path: Path) -> Path:
    if not path.exists():
        fail(f"missing source asset: {path}")
    return path


def remove(path: Path) -> None:
    if not path.exists():
        return
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def copy_asset(source: Path, destination: Path) -> None:
    require(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    remove(destination)

    if source.is_dir():
        # Prefer copy-on-write cloning on macOS/APFS to avoid duplicating multi-GB
        # Core ML weight blobs. Fall back to an ordinary recursive copy.
        result = subprocess.run(
            ["cp", "-cR", str(source), str(destination)],
            check=False,
        )
        if result.returncode != 0:
            print(
                f"[COSYVOICE3-RUNTIME-ASSEMBLY] clone-copy unavailable; "
                f"falling back source={source}",
                flush=True,
            )
            shutil.copytree(source, destination)
    else:
        shutil.copy2(source, destination)

    print(
        f"[COSYVOICE3-RUNTIME-ASSEMBLY] COPY source={source} destination={destination}",
        flush=True,
    )


def tree_sha256(path: Path) -> str:
    h = hashlib.sha256()
    if path.is_file():
        h.update(path.read_bytes())
        return h.hexdigest()
    for item in sorted(p for p in path.rglob("*") if p.is_file()):
        h.update(str(item.relative_to(path)).encode("utf-8"))
        h.update(item.read_bytes())
    return h.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path("/Volumes/WD/Codes/CosyVoice3_NPU"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / ".work/device-runtime",
    )
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    source = args.source_root.resolve()
    output = args.output.resolve()
    model = source / MODEL_RELATIVE

    if not (source / ".git").exists():
        fail(f"CosyVoice3_NPU source repository missing: {source}")

    head = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"],
        text=True,
    ).strip()
    if head != SOURCE_COMMIT:
        print(
            f"[COSYVOICE3-RUNTIME-ASSEMBLY] NOTE source working tree HEAD={head}; "
            f"runtime candidates are accepted only by their explicit artifact paths/validation receipts. "
            f"locked SDK source semantics remain {SOURCE_COMMIT}.",
            flush=True,
        )

    if output.exists():
        if not args.force:
            fail(f"output already exists; pass --force to replace: {output}")
        remove(output)
    output.mkdir(parents=True)

    llm_dir = source / "iOS/converted/llm_fp16"
    flow_dir = source / "iOS/converted/device-probes"
    acoustic_dir = source / "iOS/converted/full-pipeline"
    acoustic_inputs = acoustic_dir / "inputs"

    sources = {
        "llmPrefill": require(llm_dir / "llm-opt-perlayer-prefill.mlpackage"),
        "llmDecode": require(llm_dir / "llm-opt-perlayer-decode-maskwrite512.mlpackage"),
        "flowConditions": require(acoustic_dir / "flow-conditions.mlpackage"),
        "hift": require(acoustic_dir / "hift-portable-phase-host-fp32.mlpackage"),
        "flowMask": require(acoustic_inputs / "flow_mask.bin"),
        "flowNoise": require(acoustic_inputs / "flow_x.bin"),
    }

    shard_sources = [
        require(flow_dir / "flow-fp16-shard-00-blocks-00-03.mlpackage"),
        require(flow_dir / "flow-fp16-shard-01-blocks-04-07.mlpackage"),
        require(flow_dir / "flow-fp16-shard-02-blocks-08-11.mlpackage"),
        require(flow_dir / "flow-fp16-shard-03-blocks-12-15.mlpackage"),
        require(flow_dir / "flow-fp16-shard-04-blocks-16-19.mlpackage"),
        require(flow_dir / "flow-fp16-shard-05-blocks-20-21.mlpackage"),
    ]

    # Generate the two small native embedding tables and tokenizer metadata from
    # the pinned checkpoint instead of copying benchmark-app resources. Extract
    # tokenizer.py from the locked SDK source commit explicitly so a newer local
    # development HEAD cannot silently change release tokenizer semantics.
    with tempfile.TemporaryDirectory(
        prefix="cosyvoice3-frontend-",
        dir=str(output.parent),
    ) as temp_name:
        temp = Path(temp_name)
        locked_tokenizer_source = temp / "cosyvoice_tokenizer_locked.py"
        with locked_tokenizer_source.open("wb") as handle:
            print(
                "[COSYVOICE3-RUNTIME-ASSEMBLY] RUN "
                f"git -C {source} show {SOURCE_COMMIT}:cosyvoice/tokenizer/tokenizer.py",
                flush=True,
            )
            subprocess.run(
                [
                    "git", "-C", str(source), "show",
                    f"{SOURCE_COMMIT}:cosyvoice/tokenizer/tokenizer.py",
                ],
                check=True,
                stdout=handle,
            )
        require(locked_tokenizer_source)

        run([
            sys.executable,
            EXPORT_FRONTEND,
            "--llm",
            require(model / "llm.pt"),
            "--tokenizer-dir",
            require(model / "CosyVoice-BlankEN"),
            "--cosyvoice-tokenizer-source",
            locked_tokenizer_source,
            "--output",
            temp,
            "--rope-theta",
            "1000000",
        ])
        frontend_receipt = json.loads((temp / "frontend_tables_receipt.json").read_text())
        text_rows = int(frontend_receipt["text"]["rows"])

        copy_asset(temp / "text_embedding_fp16.bin", output / "embeddings/text_embedding_fp16.bin")
        copy_asset(temp / "speech_embedding_fp16.bin", output / "embeddings/speech_embedding_fp16.bin")
        copy_asset(temp / "Tokenizer", output / "tokenizer")

    copy_asset(sources["llmPrefill"], output / "models/llm-opt-perlayer-prefill.mlpackage")
    copy_asset(sources["llmDecode"], output / "models/llm-opt-perlayer-decode-maskwrite512.mlpackage")
    copy_asset(sources["flowConditions"], output / "models/flow-conditions-baked-reference.mlpackage")
    copy_asset(sources["hift"], output / "models/hift-portable-phase-host-fp32.mlpackage")

    flow_manifest_paths: list[str] = []
    for index, source_shard in enumerate(shard_sources):
        relative = f"models/flow-shard-{index}.mlpackage"
        copy_asset(source_shard, output / relative)
        flow_manifest_paths.append(relative)

    f0_names = [
        *(f"f0-{index}-{kind}.bin" for index in range(5) for kind in ("weight", "bias")),
        "f0-classifier-weight.bin",
        "f0-classifier-bias.bin",
    ]
    for name in f0_names:
        copy_asset(require(acoustic_inputs / name), output / "f0-double" / name)

    copy_asset(sources["flowMask"], output / "buffers/flow-mask.f32")
    copy_asset(sources["flowNoise"], output / "buffers/flow-noise.f32")

    manifest = {
        "schemaVersion": 1,
        "profile": "ios18-fixed225",
        "tokenizerFolder": "tokenizer",
        "textEmbedding": "embeddings/text_embedding_fp16.bin",
        "textEmbeddingRows": text_rows,
        "speechEmbedding": "embeddings/speech_embedding_fp16.bin",
        "llmPrefill": "models/llm-opt-perlayer-prefill.mlpackage",
        "llmDecode": "models/llm-opt-perlayer-decode-maskwrite512.mlpackage",
        "flowConditions": "models/flow-conditions-baked-reference.mlpackage",
        "flowShards": flow_manifest_paths,
        "hift": "models/hift-portable-phase-host-fp32.mlpackage",
        "f0Folder": "f0-double",
        "flowMask": "buffers/flow-mask.f32",
        "flowNoise": "buffers/flow-noise.f32",
        "ropeTheta": 1000000.0,
        "referenceEnrollment": {
            "status": "NOT_VALIDATED",
            "speechTokenizer": "reference/speech-tokenizer-fixed605.mlpackage",
            "campPlus": "reference/campplus-fixed604.mlpackage",
            "whisperMel128": "reference/whisper_mel_128.f32",
            "kaldiMel80": "reference/kaldi_mel_80.f32",
            "matchaMel80": "reference/matcha_mel_80.f32",
            "flowConditionsDynamic": "reference/flow-conditions-dynamic-151-302.mlpackage",
            "promptTokenCount": 151,
            "promptFrameCount": 302,
        },
    }
    manifest_path = output / "cosyvoice3_fixed225.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    run([sys.executable, VALIDATE_ASSETS, "--root", output])

    receipt = {
        "schemaVersion": 1,
        "status": "ASSEMBLED_BASE_RUNTIME_NOT_REFERENCE_PROMOTED",
        "sourceRepository": str(source),
        "lockedSDKSourceCommit": SOURCE_COMMIT,
        "sourceWorkingTreeHead": head,
        "output": str(output),
        "manifest": manifest,
        "sourceArtifacts": {
            key: {
                "path": str(path),
                "sha256": tree_sha256(path),
            }
            for key, path in sources.items()
        },
        "flowShards": [
            {
                "path": str(path),
                "sha256": tree_sha256(path),
            }
            for path in shard_sources
        ],
        "referenceAssetsIncluded": False,
        "next": "validation/prepare_device_smoke_assets.py merges only host-parity-approved reference candidates into a staged copy",
    }
    receipt_path = output / "runtime_assembly_receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({
        "status": receipt["status"],
        "output": str(output),
        "manifest": str(manifest_path),
        "receipt": str(receipt_path),
        "textEmbeddingRows": text_rows,
    }, indent=2))


if __name__ == "__main__":
    main()

# Code purpose: build the standalone fixed225 release-layout runtime from previously validated migration artifacts while keeping the migration repository read-only and sourcing tokenizer semantics from the locked SDK source commit rather than the local development HEAD.
# Upstream artifact sources: CosyVoice3_NPU iOS converted LLM/Flow/HiFT/F0 candidates and Fun-CosyVoice3-0.5B-2512 checkpoint.
# Runtime: macOS host; Python 3.11 environment with torch/numpy for embedding export; large packages remain outside Git.
# Generated: 2026-10-02 America/New_York.
