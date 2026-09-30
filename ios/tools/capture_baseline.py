# capture_baseline.py
# Requirement: run official zero-shot inference unchanged and archive reproducible parity fixtures.
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import random
import subprocess
import sys
import time
import traceback
from datetime import datetime
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT), str(ROOT / 'third_party/Matcha-TTS')]


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda: f.read(8 * 1024 * 1024), b''):
            h.update(b)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--reference', type=Path, default=ROOT / 'asset/leijun-1.wav')
    parser.add_argument('--transcript', type=Path, default=ROOT / 'asset/leijun-1.txt')
    parser.add_argument('--text', default='今天我们一起回顾过去的经历，也期待未来能够创造更多有意义的事情。')
    parser.add_argument('--seed', type=int, default=1986)
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    tensors = out / 'tensors'
    tensors.mkdir()
    import numpy as np
    import soundfile as sf
    import torch
    from cosyvoice.cli.cosyvoice import CosyVoice3
    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    lock = json.loads((ROOT / 'ios/validation/provenance/checkpoint-lock.json').read_text())
    if not lock.get('download_verified'):
        raise RuntimeError('Checkpoint download/hash verification must complete first')
    model_dir = ROOT / 'pretrained_models/Fun-CosyVoice3-0.5B-2512'
    reference, sr = sf.read(args.reference)
    if reference.ndim != 1 or not 5 <= len(reference) / sr <= 10 or not np.isfinite(reference).all():
        raise ValueError('Reference must be finite mono 5–10 second audio')
    transcript = args.transcript.read_text().strip()
    prompt = 'You are a helpful assistant.<|endofprompt|>' + transcript
    receipt = dict(status='RUNNING', timestamp=datetime.now(ZoneInfo('America/New_York')).isoformat(),
                   source_revision=subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip(),
                   source_status=subprocess.check_output(['git','status','--short'], cwd=ROOT, text=True),
                   model_revision=lock['revision'], model_repo=lock['repo'], seed=args.seed,
                   reference=str(args.reference.resolve()), reference_sha256=sha(args.reference),
                   transcript=transcript, transcript_sha256=sha(args.transcript), prompt=prompt,
                   target_text=args.text, reference_sample_rate=sr, reference_duration=len(reference)/sr,
                   script_sha256=sha(__file__), python=sys.version, platform=platform.platform(),
                   packages={p:importlib.metadata.version(p) for p in ['torch','torchaudio','transformers','onnxruntime','numpy','soundfile','hyperpyyaml']},
                   policy={'stream':False,'speed':1.0,'fp16':False,'text_frontend':False,
                           'sampling':'upstream RAS: top_p=0.8, top_k=25, win_size=10, tau_r=0.1',
                           'stochastic_stages':['LLM multinomial sampling','flow initial Gaussian noise','HiFT excitation noise/phase'],
                           'determinism':'seeded CPU; cross-platform bitwise determinism not claimed',
                           'threads':args.threads, 'language':'Chinese user-provided fixture'},
                   human_listening='PENDING', captures={})
    def flush():
        (out / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')
    def snapshot(x):
        if isinstance(x, torch.Tensor):
            return x.detach().cpu().clone()
        if hasattr(x, 'to_legacy_cache'):
            return snapshot(x.to_legacy_cache())
        if isinstance(x, dict):
            return {k:snapshot(v) for k,v in x.items()}
        if isinstance(x, (tuple,list)):
            return type(x)(snapshot(v) for v in x)
        if x is None or isinstance(x,(str,bool,int,float)):
            return x
        return repr(x)
    def describe(x):
        if isinstance(x, torch.Tensor):
            b=x.contiguous().view(torch.uint8).numpy().tobytes()
            return {'shape':list(x.shape),'dtype':str(x.dtype),'sha256':hashlib.sha256(b).hexdigest(),
                    'samples':x.flatten()[:8].tolist()}
        if isinstance(x,dict): return {k:describe(v) for k,v in x.items()}
        if isinstance(x,(list,tuple)): return [describe(v) for v in x]
        return x
    def capture(name,x):
        x=snapshot(x)
        p=tensors/(name+'.pt')
        torch.save(x,p)
        receipt['captures'][name]={'file':str(p.relative_to(out)),'sha256':sha(p),'values':describe(x)}
        print('CAPTURE',name,flush=True)
        flush()
    flush()
    try:
        start=time.perf_counter()
        model=CosyVoice3(str(model_dir),fp16=False,load_trt=False,load_vllm=False)
        receipt['model_load_seconds']=time.perf_counter()-start
        receipt['device']=str(model.model.device)
        receipt['qwen_config']=model.model.llm.llm.model.config.to_dict()
        receipt['frontend']=model.frontend.text_frontend
        for f in ['cosyvoice3.yaml','CosyVoice-BlankEN/config.json','CosyVoice-BlankEN/tokenizer_config.json']:
            receipt.setdefault('config_sha256',{})[f]=sha(model_dir/f)
        original_frontend=model.frontend.frontend_zero_shot
        def frontend(*a,**kw):
            x=original_frontend(*a,**kw)
            capture('conditioning',x)
            return x
        model.frontend.frontend_zero_shot=frontend
        original_step=model.model.llm.llm.forward_one_step
        step_count=0
        def step(*a,**kw):
            nonlocal step_count
            n=step_count
            if n < 2: capture('llm_step_%03d_input'%n,{'args':a,'kwargs':kw})
            y=original_step(*a,**kw)
            if n < 2: capture('llm_step_%03d_output'%n,y)
            step_count+=1
            if step_count%25==0: print('LLM_STEPS',step_count,flush=True)
            return y
        model.model.llm.llm.forward_one_step=step
        logits=[]
        model.model.llm.llm_decoder.register_forward_hook(lambda m,a,y:logits.append(snapshot(y)))
        original_inference=model.model.llm.inference
        raw_tokens=[]
        def inference(*a,**kw):
            for token in original_inference(*a,**kw):
                raw_tokens.append(int(token))
                yield token
        model.model.llm.inference=inference
        flow_original=model.model.flow.inference
        def flow(*a,**kw):
            capture('flow_input',{'args':a,'kwargs':kw})
            result=flow_original(*a,**kw)
            capture('flow_output',result)
            return result
        model.model.flow.inference=flow
        estimator_count=0
        def estimator_hook(m,a,kw,y):
            nonlocal estimator_count
            capture('estimator_%02d'%estimator_count,{'args':a,'kwargs':kw,'output':y})
            estimator_count+=1
        model.model.flow.decoder.estimator.register_forward_hook(estimator_hook,with_kwargs=True)
        hift_original=model.model.hift.inference
        def hift(*a,**kw):
            capture('hift_input',{'args':a,'kwargs':kw})
            result=hift_original(*a,**kw)
            capture('hift_output',result)
            return result
        model.model.hift.inference=hift
        random.seed(args.seed); np.random.seed(args.seed); torch.manual_seed(args.seed)
        capture('rng_before_inference',torch.get_rng_state())
        start=time.perf_counter()
        chunks=[]
        for result in model.inference_zero_shot(args.text,prompt,str(args.reference),stream=False,speed=1.0,text_frontend=False):
            chunks.append(result['tts_speech'].detach().cpu())
        pcm=torch.cat(chunks,dim=1)
        receipt['instrumented_synthesis_seconds']=time.perf_counter()-start
        if pcm.ndim!=2 or pcm.shape[0]!=1 or pcm.numel()==0 or model.sample_rate!=24000 or not torch.isfinite(pcm).all():
            raise RuntimeError('Invalid waveform')
        capture('generated_speech_tokens',torch.tensor(raw_tokens,dtype=torch.int32))
        capture('llm_logits',torch.cat(logits,dim=0))
        capture('pcm',pcm)
        sf.write(out/'baseline.wav',pcm.squeeze(0).numpy(),model.sample_rate,subtype='FLOAT')
        receipt.update(status='AUTOMATED_CAPTURE_PASS',sample_rate=model.sample_rate,duration=pcm.shape[1]/model.sample_rate,
                       samples=pcm.shape[1],wav_sha256=sha(out/'baseline.wav'),llm_steps=step_count,
                       estimator_calls=estimator_count,peak_amplitude=pcm.abs().max().item(),
                       rms=pcm.square().mean().sqrt().item())
        receipt['instrumented_rtf']=receipt['instrumented_synthesis_seconds']/receipt['duration']
        receipt['latency_caveat']='CPU with fixture IO instrumentation; not iPhone or production timing'
        flush()
        print('BASELINE_CAPTURE_PASS',out/'baseline.wav',flush=True)
    except BaseException:
        receipt['status']='FAILED'
        receipt['error']=traceback.format_exc()
        flush()
        raise

if __name__=='__main__':
    main()
# Purpose: archive official baseline and stage oracles without editing upstream source.
# Upstream: cosyvoice.cli.cosyvoice.CosyVoice3, official offline zero-shot synthesis.
# Environment: local .venv-upstream; generated 2026-09-29 America/New_York; new file, all lines added.
