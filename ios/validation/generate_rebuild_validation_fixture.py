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
def main():
    p=argparse.ArgumentParser(); p.add_argument("--source-root",type=Path,required=True); p.add_argument("--output",type=Path,required=True); a=p.parse_args()
    source=a.source_root.resolve(); out=a.output.resolve(); tools=source/"iOS/tools"; sys.path[:0]=[str(tools),str(source),str(source/"third_party/Matcha-TTS")]
    from llm_graphs import SpeechLLM,rope
    from flow_graphs import BroadcastMaskDiTGraph
    from export_pipeline_acoustics import Conditions
    from cosyvoice.flow.DiT.dit import DiT
    from hyperpyyaml import load_hyperpyyaml
    import yaml
    validation_dir=Path(__file__).resolve().parent
    if str(validation_dir) not in sys.path: sys.path.insert(0,str(validation_dir))
    from prepare_acoustic_rebuild_config import derive as derive_acoustic_config
    out.mkdir(parents=True,exist_ok=False); g=torch.Generator(device="cpu").manual_seed(20261002); model_dir=source/"pretrained_models/Fun-CosyVoice3-0.5B-2512"
    acoustic_config=model_dir/"cosyvoice3.acoustic.yaml"
    if not acoustic_config.is_file(): derive_acoustic_config(model_dir,acoustic_config)
    llm=SpeechLLM("prefill",512,compact_cache=True,grouped_gqa=True).eval()
    x0=torch.randn((1,224,896),generator=g,dtype=torch.float32)*0.05; c0,s0=rope(llm.config,list(range(224))); mask0=torch.full((1,1,224,224),torch.finfo(torch.float32).min).triu(1); dummy=torch.zeros(1)
    with torch.inference_mode(): prefill=llm(x0,c0,s0,mask0,dummy,dummy,dummy)
    cache=tuple((prefill[1][i].detach().clone(),prefill[2][i].detach().clone()) for i in range(24)); x1=torch.randn((1,1,896),generator=g,dtype=torch.float32)*0.05
    torch.save({"args":(x0,),"kwargs":{}},out/"llm_step_000_input.pt"); torch.save(prefill,out/"llm_step_000_output.pt"); torch.save({"args":(x1,),"kwargs":{"cache":cache}},out/"llm_step_001_input.pt")
    tokens=((torch.arange(225,dtype=torch.int64)*29+17)%6561).to(torch.int32); torch.save(tokens,out/"generated_speech_tokens.pt")
    target=tokens.unsqueeze(0); prompt_tokens=((torch.arange(151,dtype=torch.int64)*31+7)%6561).to(torch.int32).unsqueeze(0); prompt_feat=torch.randn((1,302,80),generator=g)*0.03; speaker=torch.randn((1,192),generator=g)*0.02; flow_inputs={"prompt_token":prompt_tokens,"prompt_feat":prompt_feat,"embedding":speaker}
    with acoustic_config.open() as handle: flow_configs=load_hyperpyyaml(handle)
    flow=flow_configs["flow"].eval(); flow.load_state_dict(torch.load(model_dir/"flow.pt",weights_only=True,map_location="cpu"),strict=True); conditions=Conditions(flow,flow_inputs).eval()
    with torch.inference_mode(): mu,spks,cond=conditions(target)
    x=torch.randn((2,80,752),generator=g)*0.1; mask=torch.ones((2,1,752),dtype=torch.float32); t=torch.tensor(0.25,dtype=torch.float32)
    config=yaml.load(acoustic_config.read_text(),Loader=yaml.BaseLoader)["flow"]["decoder"]["estimator"]; kwargs={k:int(config[k]) for k in ("dim","depth","heads","dim_head","ff_mult","mel_dim","mu_dim","spk_dim","out_channels")}
    estimator=DiT(**kwargs,static_chunk_size=50,num_decoding_left_chunks=-1).eval(); state=torch.load(model_dir/"flow.pt",map_location="cpu",weights_only=True,mmap=True); prefix="decoder.estimator."; estimator.load_state_dict({k[len(prefix):]:v for k,v in state.items() if k.startswith(prefix)},strict=True)
    flow_args=(x,mask,mu,t,spks,cond)
    with torch.inference_mode(): flow_output=BroadcastMaskDiTGraph(estimator)(*flow_args)
    torch.save({"args":flow_args,"output":flow_output},out/"estimator_00.pt"); torch.save({"args":(),"kwargs":{"token":target,**flow_inputs}},out/"flow_input.pt"); torch.save({"args":(mu[0:1,:,302:].contiguous(),),"kwargs":{}},out/"hift_input.pt")
    receipt={"schemaVersion":1,"status":"PASS_DETERMINISTIC_REBUILD_FIXTURE","seed":20261002,"scope":"conversion/parity fixture only; not a bundled voice/reference and not product audio","sourceCommit":subprocess_check(source),"shapes":{"llmPrefill":[1,224,896],"llmDecode":[1,1,896],"speechTokens":[225],"flowX":[2,80,752],"flowMu":list(mu.shape),"flowSpks":list(spks.shape),"flowCond":list(cond.shape),"hiftMel":[1,80,450]},"files":{p.name:{"bytes":p.stat().st_size,"sha256":sha(p)} for p in sorted(out.iterdir()) if p.is_file()}}
    (out/"rebuild_fixture_receipt.json").write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n"); print("[COSYVOICE3-REBUILD-FIXTURE] PASS "+json.dumps(receipt,sort_keys=True),flush=True)
def subprocess_check(source):
    import subprocess
    return subprocess.check_output(["git","-C",str(source),"rev-parse","HEAD"],text=True).strip()
if __name__=="__main__": main()
# Code purpose: replace uncommitted historical Phase-0 tensors with a deterministic pinned-checkpoint validation fixture having the exact production shapes required by the accepted converters.
# Upstream: CosyVoice3_NPU llm_graphs.py, flow_graphs.py, export_pipeline_acoustics.Conditions, official LLM/Flow weights.
# Runtime: pinned Python 3.11/Core ML rebuild environment on macOS; generation itself uses PyTorch CPU.
# Generated: 2026-10-02 America/New_York.
# Changes: new file; synthesizes fixed224 LLM prefill/cache, 225 teacher-forced speech tokens, internally consistent 752-frame Flow conditioning/estimator oracle, and 450-frame HiFT input without old converted assets or user-private reference audio.\n# Changes 2026-10-02: construct export_pipeline_acoustics.Conditions with the actual weighted Flow object plus prompt inputs, exactly matching the upstream converter contract, instead of incorrectly passing model_dir.
# Changes 2026-10-02: load only the SHA-derived cosyvoice3.acoustic.yaml Flow/HiFT graph so fixture construction never instantiates unrelated GAN/dataset/training objects.
# Changes 2026-10-02: self-derive the exact acoustic-only config when it is absent, making the Python fixture gate robust even if invoked independently of rebuild_assets.sh ordering.
