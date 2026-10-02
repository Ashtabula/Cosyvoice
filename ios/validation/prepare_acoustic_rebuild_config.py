#@title prepare_acoustic_rebuild_config.py
# Requirement: derive the exact runtime-construction prefix from the pinned checkpoint YAML so Flow/HiFT rebuilds preserve official RNG1986 object-construction order while excluding GAN/dataset/training objects.
from __future__ import annotations
import argparse,hashlib,json
from pathlib import Path

EXPECTED_SHA256="f5a6b2c6f05139d0f18861a1fe506f751e787026b77c05f7e8fef9f8a4405965"
SEED_LINES=(
    "__set_seed1: !apply:random.seed [1986]",
    "__set_seed2: !apply:numpy.random.seed [1986]",
    "__set_seed3: !apply:torch.manual_seed [1986]",
    "__set_seed4: !apply:torch.cuda.manual_seed_all [1986]",
)

def sha256(path:Path)->str:
    h=hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda:stream.read(1024*1024),b""): h.update(block)
    return h.hexdigest()

def derive(model:Path,output:Path)->dict:
    model=model.resolve(); source=model/"cosyvoice3.yaml"; output=output.resolve()
    actual=sha256(source)
    if actual!=EXPECTED_SHA256: raise RuntimeError(f"pinned cosyvoice3.yaml sha256 mismatch: {actual}")
    text=source.read_text(encoding="utf-8")
    gan_marker="\n# gan related module"
    gan_start=text.find(gan_marker)
    if gan_start<0: raise RuntimeError("pinned config GAN boundary not found")
    derived=text[:gan_start].rstrip()+"\n"

    for line in SEED_LINES:
        if derived.count(line)!=1: raise RuntimeError(f"missing/duplicate canonical seed directive: {line}")
    required=(
        "qwen_pretrain_path: ''",
        "\nllm: !new:cosyvoice.llm.llm.CosyVoice3LM",
        "\nflow: !new:cosyvoice.flow.flow.CausalMaskedDiffWithDiT",
        "\nhift: !new:cosyvoice.hifigan.generator.CausalHiFTGenerator",
    )
    for token in required:
        if derived.count(token)!=1: raise RuntimeError(f"runtime-prefix config missing/duplicates required token: {token}")
    order=[derived.index(token) for token in (SEED_LINES[0],required[1],required[2],required[3])]
    if order!=sorted(order): raise RuntimeError(f"runtime construction order changed: {order}")
    forbidden=("\n# gan related module","cosyvoice.hifigan.hifigan","matcha.hifigan.models","cosyvoice.dataset","parquet_opener","data_pipeline","train_conf:")
    leaked=[token for token in forbidden if token in derived]
    if leaked: raise RuntimeError(f"post-HiFT training/GAN content leaked into runtime-prefix config: {leaked}")

    output.write_text(derived,encoding="utf-8")
    receipt={
        "schemaVersion":2,
        "status":"PASS_RUNTIME_PREFIX_CONFIG_DERIVATION",
        "source":str(source),
        "sourceSha256":actual,
        "output":str(output),
        "outputSha256":sha256(output),
        "constructionPrefixByteExact":derived==text[:gan_start].rstrip()+"\n",
        "rngSeed":1986,
        "rngConstructionOrder":["seed","llm","flow","hift"],
        "sections":["llm","flow","hift"],
        "qwenPretrainPathPresent":True,
        "excluded":["gan wrapper/discriminators","dataset processors","training config"],
        "reason":"CausalHiFTGenerator.SineGen2 creates rand_ini and sine_waves during construction; preserving the original YAML prefix preserves their RNG trajectory without instantiating post-HiFT training objects.",
        "runtimeMathChanged":False,
    }
    (output.parent/"cosyvoice3.acoustic.config-receipt.json").write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n")
    print("[COSYVOICE3-ACOUSTIC-CONFIG] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
    return receipt

def main():
    p=argparse.ArgumentParser(); p.add_argument("--model-dir",type=Path,required=True); p.add_argument("--output",type=Path,required=True); a=p.parse_args()
    derive(a.model_dir,a.output)

if __name__=="__main__": main()

# Code purpose: derive a release-only runtime YAML that is byte-identical to the official config from its RNG seed directives through HiFT construction, then stops before GAN/dataset/training sections.
# Upstream source: FunAudioLLM/Fun-CosyVoice3-0.5B-2512 cosyvoice3.yaml sha256 f5a6b2c6f05139d0f18861a1fe506f751e787026b77c05f7e8fef9f8a4405965.
# Runtime environment: Python 3 standard library in the rebuild venv.
# Generated: 2026-10-02 America/New_York.
# Changes: replace the earlier Flow+HiFT-only extraction with an exact seed->LLM->Flow->HiFT prefix so non-checkpointed CausalHiFTGenerator SineGen2 excitation buffers reproduce the accepted RNG1986 construction trajectory.
