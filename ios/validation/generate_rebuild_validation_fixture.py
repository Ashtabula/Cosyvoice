#@title generate_rebuild_validation_fixture.py
# Requirement: generate deterministic shape-complete LLM/Flow/HiFT validation tensors from the pinned checkpoint so a clean rebuild never depends on historical ignored conversion tensors or a developer-local reference recording.
from __future__ import annotations
import argparse,hashlib,json,sys,time
from pathlib import Path
import torch
def sha(path):
    h=hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda:f.read(8*1024*1024),b""): h.update(b)
    return h.hexdigest()
def tensor_sha(t):
    h=hashlib.sha256(); h.update(t.detach().cpu().contiguous().numpy().tobytes()); return h.hexdigest()
def main():
    p=argparse.ArgumentParser(); p.add_argument("--source-root",type=Path,required=True); p.add_argument("--output",type=Path,required=True); a=p.parse_args()
    source=a.source_root.resolve(); out=a.output.resolve(); tools=source/"iOS/tools"; sys.path[:0]=[str(tools),str(source),str(source/"third_party/Matcha-TTS")]
    from llm_graphs import SpeechLLM,rope
    from flow_graphs import BroadcastMaskDiTGraph
    from export_pipeline_acoustics import Conditions
    from hyperpyyaml import load_hyperpyyaml
    validation_dir=Path(__file__).resolve().parent
    if str(validation_dir) not in sys.path: sys.path.insert(0,str(validation_dir))
    from prepare_acoustic_rebuild_config import derive as derive_acoustic_config
    out.mkdir(parents=True,exist_ok=False); g=torch.Generator(device="cpu").manual_seed(20261002); model_dir=source/"pretrained_models/Fun-CosyVoice3-0.5B-2512"
    acoustic_config=model_dir/"cosyvoice3.acoustic.yaml"
    derive_acoustic_config(model_dir,acoustic_config)
    llm=SpeechLLM("prefill",512,compact_cache=True,grouped_gqa=True).eval()
    x0=torch.randn((1,224,896),generator=g,dtype=torch.float32)*0.05; c0,s0=rope(llm.config,list(range(224))); mask0=torch.full((1,1,224,224),torch.finfo(torch.float32).min).triu(1); dummy=torch.zeros(1)
    with torch.inference_mode(): prefill=llm(x0,c0,s0,mask0,dummy,dummy,dummy)
    cache=tuple((prefill[1][i].detach().clone(),prefill[2][i].detach().clone()) for i in range(24)); x1=torch.randn((1,1,896),generator=g,dtype=torch.float32)*0.05
    torch.save({"args":(x0,),"kwargs":{}},out/"llm_step_000_input.pt"); torch.save(prefill,out/"llm_step_000_output.pt"); torch.save({"args":(x1,),"kwargs":{"cache":cache}},out/"llm_step_001_input.pt")
    tokens=((torch.arange(225,dtype=torch.int64)*29+17)%6561).to(torch.int32); torch.save(tokens,out/"generated_speech_tokens.pt")
    target=tokens.unsqueeze(0); prompt_tokens=((torch.arange(151,dtype=torch.int64)*31+7)%6561).to(torch.int32).unsqueeze(0); prompt_feat=-4.0+torch.randn((1,302,80),generator=g)*0.5; speaker=torch.randn((1,192),generator=g); flow_inputs={"prompt_token":prompt_tokens,"prompt_feat":prompt_feat,"embedding":speaker}
    with acoustic_config.open() as handle: flow_configs=load_hyperpyyaml(handle,overrides={"qwen_pretrain_path":str(model_dir/"CosyVoice-BlankEN")})
    flow=flow_configs["flow"].eval(); flow.load_state_dict(torch.load(model_dir/"flow.pt",weights_only=True,map_location="cpu"),strict=True); del flow_configs; conditions=Conditions(flow,flow_inputs).eval()
    with torch.inference_mode(): mu,spks,cond=conditions(target)
    estimator=flow.decoder.estimator.eval(); graph=BroadcastMaskDiTGraph(estimator).eval()
    initial_noise=flow.decoder.rand_noise[:,:,:752].to(dtype=mu.dtype).clone()
    if tuple(initial_noise.shape)!=(1,80,752): raise RuntimeError(f"official Flow rand_noise ABI mismatch: {tuple(initial_noise.shape)}")
    mask=torch.ones((2,1,752),dtype=mu.dtype)
    t_span=torch.linspace(0,1,11,dtype=mu.dtype)
    if flow.decoder.t_scheduler=="cosine": t_span=1-torch.cos(t_span*0.5*torch.pi)
    elif flow.decoder.t_scheduler!="linear": raise RuntimeError(f"unsupported Flow scheduler for rebuild fixture: {flow.decoder.t_scheduler}")
    cfg=float(flow.decoder.inference_cfg_rate)
    state=initial_noise.clone(); first_args=None; first_velocity=None
    with torch.inference_mode():
        for step in range(10):
            t=torch.full((2,),float(t_span[step].item()),dtype=mu.dtype)
            if tuple(t.shape)!=(2,) or not bool(torch.equal(t,t[0].expand_as(t))): raise RuntimeError(f"Flow scheduler time ABI mismatch: shape={tuple(t.shape)} values={t.tolist()}")
            batch_x=state.repeat(2,1,1)
            args=(batch_x,mask,mu,t,spks,cond)
            velocity=graph(*args)
            if step==0:
                first_args=tuple(value.detach().clone() for value in args)
                first_velocity=velocity.detach().clone()
            dt=t_span[step+1]-t_span[step]
            state=state+dt*((1.0+cfg)*velocity[0:1]-cfg*velocity[1:2])
    if first_args is None or first_velocity is None: raise RuntimeError("Flow scheduler fixture did not execute")
    generated_mel=state[:,:,302:].contiguous()
    if tuple(generated_mel.shape)!=(1,80,450) or not bool(torch.isfinite(generated_mel).all()): raise RuntimeError("generated HiFT mel fixture invalid")
    torch.save({"args":first_args,"output":first_velocity},out/"estimator_00.pt"); torch.save({"args":(),"kwargs":{"token":target,**flow_inputs}},out/"flow_input.pt"); torch.save({"args":(generated_mel,),"kwargs":{}},out/"hift_input.pt")
    mel_stats={"min":float(generated_mel.min()),"max":float(generated_mel.max()),"mean":float(generated_mel.mean()),"std":float(generated_mel.std())}
    receipt={"schemaVersion":2,"status":"PASS_DETERMINISTIC_REBUILD_FIXTURE","seed":20261002,"scope":"conversion/parity fixture only; not a bundled voice/reference and not product audio","sourceCommit":subprocess_check(source),"shapes":{"llmPrefill":[1,224,896],"llmDecode":[1,1,896],"speechTokens":[225],"flowX":[2,80,752],"flowT":[2],"flowTSharedScalar":True,"flowMu":list(mu.shape),"flowSpks":list(spks.shape),"flowCond":list(cond.shape),"hiftMel":[1,80,450]},"flowScheduler":{"steps":10,"scheduler":flow.decoder.t_scheduler,"cfgRate":cfg,"initialNoiseSource":"CausalConditionalCFM.rand_noise(seed=0)","initialNoiseSha256":tensor_sha(initial_noise),"generatedMelSource":"official 10-step CFG Euler target crop after 302 prompt frames","generatedMelSha256":tensor_sha(generated_mel),"generatedMelStats":mel_stats},"files":{p.name:{"bytes":p.stat().st_size,"sha256":sha(p)} for p in sorted(out.iterdir()) if p.is_file()}}
    (out/"rebuild_fixture_receipt.json").write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-REBUILD-FIXTURE] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
def subprocess_check(source):
    import subprocess
    return subprocess.check_output(["git","-C",str(source),"rev-parse","HEAD"],text=True).strip()
if __name__=="__main__": main()
# Code purpose: replace uncommitted historical Phase-0 tensors with a deterministic pinned-checkpoint validation fixture having the exact production shapes required by the accepted converters.
# Upstream: CosyVoice3_NPU llm_graphs.py, flow_graphs.py, export_pipeline_acoustics.Conditions, official LLM/Flow weights.
# Runtime: pinned Python 3.11/Core ML rebuild environment on macOS; generation itself uses PyTorch CPU.
# Generated: 2026-10-02 America/New_York.
# Changes: synthesizes fixed224 LLM prefill/cache, 225 teacher-forced speech tokens, internally consistent 752-frame Flow conditioning/estimator oracle, and 450-frame HiFT input without old converted assets or user-private reference audio.\n# Changes 2026-10-02: construct export_pipeline_acoustics.Conditions with the actual weighted Flow object plus prompt inputs, exactly matching the upstream converter contract, instead of incorrectly passing model_dir.
# Changes 2026-10-02: load only the SHA-derived cosyvoice3.acoustic.yaml Flow/HiFT graph so fixture construction never instantiates unrelated GAN/dataset/training objects.
# Changes 2026-10-02: always re-derive the exact acoustic-only config before loading it, so an interrupted/older rebuild cannot reuse a stale malformed derived YAML.
# Changes 2026-10-02: load the derived seed->LLM->Flow->HiFT prefix with the canonical qwen_pretrain_path override, then immediately release unused LLM/HiFT objects after extracting Flow.
# Changes 2026-10-02: HiFT fixture mel is now the actual target crop of a deterministic official 10-step cosine CFG Euler Flow rollout using CausalConditionalCFM.rand_noise(seed=0), not the conditioning mean mu; prompt mel is deterministic model-like synthetic data.\n