#@title validate_shipping_hift_host.py
# Requirement: validate the actual shipping HiFT path: exported FP64 F0 coefficients + host Float64 phase accumulation + Core ML HiFT body, using the clean-house Flow-generated mel fixture.
from __future__ import annotations
import argparse,hashlib,json,sys
from pathlib import Path
import coremltools as ct
import numpy as np
import torch

def sha256(path:Path)->str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda:f.read(8*1024*1024),b""): h.update(block)
    return h.hexdigest()

def metric(a,b):
    a=np.asarray(a,dtype=np.float64); b=np.asarray(b,dtype=np.float64); d=np.abs(a-b)
    return {
        "max_abs":float(d.max()),
        "mean_abs":float(d.mean()),
        "p99_abs":float(np.quantile(d,0.99)),
        "rmse":float(np.sqrt(np.mean((a-b)**2))),
        "relative_l2":float(np.linalg.norm(a-b)/max(np.linalg.norm(b),1e-20)),
        "finite":bool(np.isfinite(a).all() and np.isfinite(b).all()),
    }

def read_hift_mel(path:Path)->torch.Tensor:
    record=torch.load(path,weights_only=True,map_location="cpu")
    if isinstance(record,dict) and "kwargs" in record and "speech_feat" in record["kwargs"]:
        mel=record["kwargs"]["speech_feat"]
    elif isinstance(record,dict) and "args" in record and record["args"]:
        mel=record["args"][0]
    else:
        raise RuntimeError("unsupported HiFT fixture record")
    mel=mel.float().contiguous()
    if tuple(mel.shape)!=(1,80,450) or not bool(torch.isfinite(mel).all()):
        raise RuntimeError(f"invalid HiFT mel fixture: {tuple(mel.shape)}")
    return mel

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--source-root",type=Path,required=True)
    p.add_argument("--fixture",type=Path,required=True)
    p.add_argument("--output",type=Path,required=True)
    a=p.parse_args()
    source=a.source_root.resolve(); fixture=a.fixture.resolve(); output=a.output.resolve()
    tools_dir=source/"iOS/tools"; sys.path[:0]=[str(tools_dir),str(source),str(source/"third_party/Matcha-TTS")]
    from hyperpyyaml import load_hyperpyyaml
    from export_pipeline_acoustics import HiFTPortable

    model_dir=source/"pretrained_models/Fun-CosyVoice3-0.5B-2512"
    config=model_dir/"cosyvoice3.acoustic.yaml"
    if not config.is_file(): raise RuntimeError("missing derived runtime-prefix config")
    with config.open() as handle:
        configs=load_hyperpyyaml(handle,overrides={"qwen_pretrain_path":str(model_dir/"CosyVoice-BlankEN")})
    hift=configs["hift"].eval()
    hift.load_state_dict({k.replace("generator.",""):v for k,v in torch.load(model_dir/"hift.pt",weights_only=True,map_location="cpu").items()},strict=True)

    mel_path=fixture/"hift_input.pt"; mel=read_hift_mel(mel_path)
    graph=HiFTPortable(hift,450).eval()
    hift.f0_predictor.to(torch.float64)
    with torch.inference_mode():
        f0_fp64=hift.f0_predictor(mel.to(torch.float64),finalize=True).to(torch.float32).contiguous()
    f0_np=f0_fp64.numpy()
    harmonics=np.arange(1,10,dtype=np.float32)[None,None,:]
    radians=np.remainder(f0_np[:,:,None]*harmonics/np.float32(24000),np.float32(1))
    phase=np.cumsum(radians.astype(np.float64),axis=1).astype(np.float32)*np.float32(2*np.pi)
    phase_tensor=torch.from_numpy(phase)
    with torch.inference_mode():
        torch_body=graph(mel,f0_fp64,phase_tensor).numpy()
        upstream,_=hift.inference(mel,finalize=True)
        upstream=upstream.numpy()

    package=source/"iOS/converted/full-pipeline/hift-portable-phase-host-fp32.mlpackage"
    if not package.is_dir(): raise RuntimeError("missing host-phase HiFT Core ML package")
    coreml=ct.models.MLModel(str(package),compute_units=ct.ComputeUnit.CPU_ONLY)
    predicted=coreml.predict({"mel":mel.numpy(),"f0":f0_np,"phase":phase})["pcm"]

    inputs=source/"iOS/converted/full-pipeline/inputs"
    exact_rows=[]
    convs=list(hift.f0_predictor.condnet[::2])
    for i,conv in enumerate(convs):
        for name,value in (("weight",conv.weight),("bias",conv.bias)):
            path=inputs/f"f0-{i}-{name}.bin"
            expected=value.detach().double().cpu().numpy().reshape(-1)
            actual=np.fromfile(path,dtype=np.float64)
            exact=actual.shape==expected.shape and bool(np.array_equal(actual,expected))
            exact_rows.append({"path":str(path.relative_to(source)),"count":int(actual.size),"sha256":sha256(path),"exactEffectiveWeight":exact})
    for name,value in (("weight",hift.f0_predictor.classifier.weight),("bias",hift.f0_predictor.classifier.bias)):
        path=inputs/f"f0-classifier-{name}.bin"
        expected=value.detach().double().cpu().numpy().reshape(-1); actual=np.fromfile(path,dtype=np.float64)
        exact=actual.shape==expected.shape and bool(np.array_equal(actual,expected))
        exact_rows.append({"path":str(path.relative_to(source)),"count":int(actual.size),"sha256":sha256(path),"exactEffectiveWeight":exact})
    reference_f0=inputs/"reference_f0.bin"
    reference_actual=np.fromfile(reference_f0,dtype=np.float32).reshape(1,450)
    f0_reference_metric=metric(reference_actual,f0_np)
    all_weights_exact=all(row["exactEffectiveWeight"] for row in exact_rows)

    body_metric=metric(predicted,torch_body)
    upstream_metric=metric(predicted,upstream)
    criteria={"relativeL2Max":0.02,"maxAbsPolicy":"diagnostic-only; historical accepted production evidence was evaluated primarily by relative L2 on same-mel device output","pcmSamples":216000}
    passed=(
        all_weights_exact and
        f0_reference_metric["finite"] and f0_reference_metric["max_abs"]==0.0 and f0_reference_metric["relative_l2"]==0.0 and
        body_metric["finite"] and body_metric["relative_l2"]<=criteria["relativeL2Max"] and
        upstream_metric["finite"] and upstream_metric["relative_l2"]<=criteria["relativeL2Max"] and
        int(np.asarray(predicted).size)==criteria["pcmSamples"]
    )
    report={
        "schemaVersion":1,
        "status":"PASS_SHIPPING_HIFT_HOST_PARITY" if passed else "FAIL_SHIPPING_HIFT_HOST_PARITY",
        "scope":"clean-house production HiFT contract: exported effective FP64 F0 weights, Float64 host phase accumulation rounded to FP32, and Core ML HiFT body",
        "fixture":{"path":str(mel_path),"sha256":sha256(mel_path),"shape":[1,80,450]},
        "f0PredictorDtype":"float64",
        "f0UpstreamContract":"CausalHiFTGenerator.inference explicitly moves f0_predictor and speech_feat to torch.float64 before prediction",
        "f0ExportedEffectiveWeightsExact":all_weights_exact,
        "f0WeightFiles":exact_rows,
        "f0ReferenceVsTorchFP64":f0_reference_metric,
        "coremlBodyVsTorchSameFP64F0":body_metric,
        "coremlBodyVsUpstreamFP64":upstream_metric,
        "phaseAccumulation":"Float32 radians accumulated in Float64, rounded to Float32 before Core ML; matches CosyVoice3AcousticRuntime.swift",
        "criteria":criteria,
        "coremlPackage":str(package),
        "coremlPackageBytes":sum(x.stat().st_size for x in package.rglob("*") if x.is_file()),
    }
    output.parent.mkdir(parents=True,exist_ok=True); output.write_text(json.dumps(report,indent=2,sort_keys=True)+"\n")
    print("[COSYVOICE3-SHIPPING-HIFT] "+json.dumps(report,sort_keys=True),flush=True)
    if not passed: raise SystemExit(1)

if __name__=="__main__": main()

# Code purpose: gate the same FP64-F0/host-phase/HiFT-body architecture that ships in CosyVoice3Core instead of treating the diagnostic FP32 Core ML F0 model as production.
# Upstream source: pinned CosyVoice3 CausalHiFTGenerator, export_pipeline_acoustics.HiFTPortable, and effective F0 weights exported by --export-f0-double.
# Runtime environment: macOS Apple Silicon / clean-house Python 3.11 / Core ML Tools 9 CPU_ONLY.
# Generated: 2026-10-02 America/New_York.
# Changes: production-path host parity gate; explicitly mirrors CausalHiFTGenerator.inference by moving the complete F0 predictor to torch.float64 before inference and before exact effective-weight comparison; max-abs remains diagnostic while the accepted global PCM criterion is finite output plus relative-L2 <= 0.02.
