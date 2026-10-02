#!/usr/bin/env python3
# export_frontend_tables.py
# Requirement: export exact fine-tuned Qwen text/speech embedding tables and a self-contained swift-transformers-compatible CosyVoice3 Qwen2 tokenizer.
from __future__ import annotations

import argparse
import ast
import hashlib
import json
from pathlib import Path

import torch

TEXT_KEY = "llm.model.model.embed_tokens.weight"
SPEECH_KEY = "speech_embedding.weight"
END_OF_PROMPT = "<|endofprompt|>"
END_OF_PROMPT_ID = 151646
QWEN2_PRETOKENIZE_REGEX = r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def cosyvoice3_special_tokens(source: Path) -> dict:
    tree = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
    for node in tree.body:
        if not isinstance(node, ast.ClassDef) or node.name != "CosyVoice3Tokenizer":
            continue
        for member in node.body:
            if not isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef)) or member.name != "__init__":
                continue
            for statement in member.body:
                if not isinstance(statement, ast.Assign):
                    continue
                if not any(isinstance(target, ast.Name) and target.id == "special_tokens" for target in statement.targets):
                    continue
                value = ast.literal_eval(statement.value)
                if not isinstance(value, dict) or not isinstance(value.get("additional_special_tokens"), list):
                    raise RuntimeError("CosyVoice3Tokenizer special_tokens has unexpected structure")
                return value
    raise RuntimeError(f"CosyVoice3Tokenizer.special_tokens not found in {source}")


def added_token_record(token_id: int, content: str) -> dict:
    return {
        "id": token_id,
        "content": content,
        "single_word": False,
        "lstrip": False,
        "rstrip": False,
        "normalized": False,
        "special": True,
    }


def build_tokenizer(
    tokenizer_dir: Path,
    output: Path,
    source_file: Path,
    text_rows: int,
) -> dict:
    vocab_path = tokenizer_dir / "vocab.json"
    merges_path = tokenizer_dir / "merges.txt"
    config_path = tokenizer_dir / "tokenizer_config.json"
    for path in (vocab_path, merges_path, config_path, source_file):
        if not path.is_file():
            raise FileNotFoundError(path)

    vocab = json.loads(vocab_path.read_text(encoding="utf-8"))
    config = json.loads(config_path.read_text(encoding="utf-8"))
    if not isinstance(vocab, dict) or not vocab:
        raise RuntimeError("Qwen2 vocab.json is empty/malformed")

    vocab_ids = [int(value) for value in vocab.values()]
    if min(vocab_ids) != 0 or max(vocab_ids) != len(vocab_ids) - 1:
        raise RuntimeError("Qwen2 base vocab IDs are not contiguous from zero")

    base_decoder = config.get("added_tokens_decoder")
    if not isinstance(base_decoder, dict):
        raise RuntimeError("tokenizer_config.json has no added_tokens_decoder")

    id_to_token: dict[int, str] = {}
    token_to_id: dict[str, int] = {}
    for raw_id, entry in base_decoder.items():
        token_id = int(raw_id)
        content = entry.get("content") if isinstance(entry, dict) else None
        if not isinstance(content, str):
            raise RuntimeError(f"malformed base added token id={raw_id}")
        id_to_token[token_id] = content
        token_to_id[content] = token_id

    upstream_special = cosyvoice3_special_tokens(source_file)
    next_id = max(max(vocab_ids), max(id_to_token)) + 1
    for content in upstream_special["additional_special_tokens"]:
        if content in vocab or content in token_to_id:
            continue
        token_to_id[content] = next_id
        id_to_token[next_id] = content
        next_id += 1

    if token_to_id.get(END_OF_PROMPT) != END_OF_PROMPT_ID:
        raise RuntimeError(
            f"{END_OF_PROMPT} id mismatch: {token_to_id.get(END_OF_PROMPT)} != {END_OF_PROMPT_ID}"
        )
    if next_id != text_rows:
        raise RuntimeError(
            f"CosyVoice3 tokenizer rows mismatch after exact upstream special-token expansion: "
            f"next_id={next_id} textEmbeddingRows={text_rows}"
        )

    added_tokens = [
        added_token_record(token_id, id_to_token[token_id])
        for token_id in sorted(id_to_token)
    ]

    merges = [
        line
        for line in merges_path.read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    ]
    if not merges:
        raise RuntimeError("Qwen2 merges.txt contains no merge rules")

    tokenizer_json = {
        "version": "1.0",
        "truncation": None,
        "padding": None,
        "added_tokens": added_tokens,
        "normalizer": {"type": "NFC"},
        "pre_tokenizer": {
            "type": "Sequence",
            "pretokenizers": [
                {
                    "type": "Split",
                    "pattern": {"Regex": QWEN2_PRETOKENIZE_REGEX},
                    "behavior": "Isolated",
                    "invert": False,
                },
                {
                    "type": "ByteLevel",
                    "add_prefix_space": False,
                    "trim_offsets": True,
                    "use_regex": False,
                },
            ],
        },
        "post_processor": None,
        "decoder": {
            "type": "ByteLevel",
            "add_prefix_space": False,
            "trim_offsets": True,
            "use_regex": True,
        },
        "model": {
            "type": "BPE",
            "dropout": None,
            "unk_token": None,
            "continuing_subword_prefix": "",
            "end_of_word_suffix": "",
            "fuse_unk": False,
            "byte_fallback": False,
            "vocab": vocab,
            "merges": merges,
        },
    }

    extended_config = dict(config)
    extended_config["eos_token"] = upstream_special["eos_token"]
    extended_config["pad_token"] = upstream_special["pad_token"]
    extended_config["additional_special_tokens"] = upstream_special["additional_special_tokens"]
    extended_config["added_tokens_decoder"] = {
        str(item["id"]): {
            "content": item["content"],
            "lstrip": False,
            "normalized": False,
            "rstrip": False,
            "single_word": False,
            "special": True,
        }
        for item in added_tokens
    }

    output.mkdir(parents=True, exist_ok=True)
    (output / "vocab.json").write_bytes(vocab_path.read_bytes())
    (output / "merges.txt").write_bytes(merges_path.read_bytes())
    (output / "tokenizer_config.json").write_text(
        json.dumps(extended_config, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    tokenizer_json_path = output / "tokenizer.json"
    tokenizer_json_path.write_text(
        json.dumps(tokenizer_json, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    optional_config = tokenizer_dir / "config.json"
    if optional_config.is_file():
        (output / "config.json").write_bytes(optional_config.read_bytes())

    return {
        "tokenizerJsonSha256": sha256(tokenizer_json_path),
        "tokenizerConfigSha256": sha256(output / "tokenizer_config.json"),
        "baseVocabCount": len(vocab),
        "addedTokenCount": len(added_tokens),
        "textRows": text_rows,
        "endOfPromptID": token_to_id[END_OF_PROMPT],
        "lastTokenID": max(id_to_token),
        "specialTokenSource": str(source_file),
        "specialTokenSourceSha256": sha256(source_file),
        "construction": "Qwen2 vocab+merges + exact CosyVoice3Tokenizer.add_special_tokens list; no transformers runtime required",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--llm", type=Path, required=True)
    parser.add_argument("--tokenizer-dir", type=Path, required=True)
    parser.add_argument("--cosyvoice-tokenizer-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rope-theta", type=float, required=True)
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    state = torch.load(args.llm, map_location="cpu", weights_only=True, mmap=True)
    missing = [key for key in (TEXT_KEY, SPEECH_KEY) if key not in state]
    if missing:
        embedding_keys = sorted(key for key in state if "embed" in key.lower())
        raise RuntimeError(
            f"required embedding keys missing: {missing}; available embedding-like keys: {embedding_keys}"
        )

    text = state[TEXT_KEY].detach().cpu().to(torch.float16).contiguous().numpy()
    speech = state[SPEECH_KEY].detach().cpu().to(torch.float16).contiguous().numpy()
    if text.ndim != 2 or text.shape[1] != 896:
        raise RuntimeError(f"unexpected text embedding shape {text.shape}")
    if tuple(speech.shape) != (6761, 896):
        raise RuntimeError(f"unexpected speech embedding shape {speech.shape}")

    text_path = args.output / "text_embedding_fp16.bin"
    speech_path = args.output / "speech_embedding_fp16.bin"
    text.tofile(text_path)
    speech.tofile(speech_path)

    tokenizer_output = args.output / "Tokenizer"
    tokenizer_receipt = build_tokenizer(
        args.tokenizer_dir,
        tokenizer_output,
        args.cosyvoice_tokenizer_source,
        int(text.shape[0]),
    )

    receipt = {
        "status": "EXPORTED_NOT_DEVICE_VALIDATED",
        "schemaVersion": 2,
        "text": {
            "rows": int(text.shape[0]),
            "width": 896,
            "dtype": "float16",
            "sha256": sha256(text_path),
        },
        "speech": {
            "rows": 6761,
            "width": 896,
            "dtype": "float16",
            "sha256": sha256(speech_path),
        },
        "tokenizer": tokenizer_receipt,
        "ropeTheta": args.rope_theta,
        "sourceKeys": {"text": TEXT_KEY, "speech": SPEECH_KEY},
    }
    (args.output / "frontend_tables_receipt.json").write_text(
        json.dumps(receipt, indent=2) + "\n"
    )
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()

# Code purpose: build native Swift embedding assets plus the exact local tokenizer contract required by swift-transformers AutoTokenizer.
# Upstream: pinned llm.pt, CosyVoice-BlankEN vocab/merges/config, and exact CosyVoice3Tokenizer special-token declaration from locked source.
# Runtime: host PyTorch + Python standard library; no Python/transformers dependency in the shipping iOS runtime.
# Generated: 2026-10-02 America/New_York.
