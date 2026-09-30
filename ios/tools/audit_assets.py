# audit_assets.py
# Requirement: measure unique clone-only weights; distinguish loader inputs from shipping weights.
import hashlib
import json
from pathlib import Path
import torch
import onnx
from safetensors import safe_open

ROOT=Path(__file__).resolve().parents[2]
P=ROOT/'pretrained_models/Fun-CosyVoice3-0.5B-2512'
lock=json.loads((ROOT/'ios/validation/provenance/checkpoint-lock.json').read_text())
if not lock.get('download_verified'): raise RuntimeError('Unverified checkpoint')
report={'model_revision':lock['revision'],'pytorch':{},'onnx':{},'files':[]}
for filename in ['llm.pt','flow.pt','hift.pt']:
    state=torch.load(P/filename,map_location='cpu',weights_only=True,mmap=True)
    seen=set(); total=0; fp16=0; aliases=[]
    for name,t in state.items():
        key=(t.untyped_storage().data_ptr(),t.untyped_storage().nbytes())
        if key in seen:
            aliases.append(name); continue
        seen.add(key)
        total+=t.untyped_storage().nbytes()
        fp16+=t.numel()*2 if t.is_floating_point() else t.numel()*t.element_size()
    entry={'unique_storage_bytes':total,'fp16_payload_estimate_bytes':fp16,'tensor_count':len(state),'storage_aliases':aliases,
           'dtype_counts':{str(dt):sum(t.numel() for t in state.values() if t.dtype==dt) for dt in set(t.dtype for t in state.values())}}
    if filename=='llm.pt':
        with safe_open(P/'CosyVoice-BlankEN/model.safetensors',framework='pt') as f:
            missing=[k for k in f.keys() if 'llm.model.'+k not in state or list(state['llm.model.'+k].shape)!=f.get_slice(k).get_shape()]
        entry['blank_init_missing_or_shape_mismatch']=missing
        entry['blank_init_fully_overwritten_by_strict_load']=not missing
        a=state['llm.model.model.embed_tokens.weight']; b=state['llm.model.lm_head.weight']
        entry['qwen_lm_head_equals_text_embedding']=torch.equal(a,b)
        entry['qwen_lm_head_unused_in_speech_logit_path']=True
        entry['qwen_lm_head_bytes']=b.numel()*b.element_size()
    report['pytorch'][filename]=entry
    print(filename,entry,flush=True)
    del state
for filename in ['campplus.onnx','speech_tokenizer_v3.onnx','speech_tokenizer_v3.batch.onnx','flow.decoder.estimator.fp32.onnx']:
    model=onnx.load(str(P/filename))
    digests=[]; total=0
    for t in model.graph.initializer:
        array=onnx.numpy_helper.to_array(t)
        raw=array.tobytes()
        h=hashlib.sha256(raw).hexdigest()
        digests.append((str(array.dtype),list(array.shape),h,len(raw)))
        total+=len(raw)
    report['onnx'][filename]={'initializer_bytes':total,'initializer_count':len(digests),
                             'weight_fingerprint':hashlib.sha256(json.dumps(sorted(digests)).encode()).hexdigest(),
                             'inputs':[v.name for v in model.graph.input], 'outputs':[v.name for v in model.graph.output]}
    print(filename,report['onnx'][filename],flush=True)
    del model
runtime={'llm.pt','flow.pt','hift.pt','campplus.onnx','speech_tokenizer_v3.onnx'}
metadata={'cosyvoice3.yaml','CosyVoice-BlankEN/config.json','CosyVoice-BlankEN/tokenizer_config.json','CosyVoice-BlankEN/merges.txt','CosyVoice-BlankEN/vocab.json'}
for f in lock['files']:
    name=f['path']
    if name in runtime:
        purpose='clone-only learned weights'; required=True; representation='Core ML neural weights' if name.endswith('.pt') else 'ONNX Runtime CPU enrollment initially'
    elif name in metadata:
        purpose='architecture/text-tokenizer metadata'; required=True; representation='versioned engine metadata/tokenizer assets'
    elif name=='CosyVoice-BlankEN/model.safetensors':
        purpose='required by unchanged upstream constructor, overwritten by strict llm.pt load'; required=False; representation='omit from shipping; retain upstream oracle'
    elif name=='llm.rl.pt':
        purpose='alternative RL checkpoint, excluded by milestone'; required=False; representation='omit'
    elif name=='speech_tokenizer_v3.batch.onnx':
        purpose='alternative batch enrollment graph'; required=False; representation='omit; single-reference graph selected'
    elif name=='flow.decoder.estimator.fp32.onnx':
        purpose='alternative estimator deployment and independent oracle; flow.pt also has non-estimator weights'; required=False; representation='retain validation only'
    else:
        purpose='repository metadata/documentation/image or optional generation config'; required=False; representation='not inference weights; retain required attribution'
    report['files'].append({**f,'purpose':purpose,'clone_runtime_required':required,'ios_representation':representation})
report['repository_file_bytes']=sum(f['bytes'] for f in lock['files'])
report['selected_runtime_weight_file_bytes']=sum(f['bytes'] for f in lock['files'] if f['path'] in runtime)
report['selected_runtime_metadata_bytes']=sum(f['bytes'] for f in lock['files'] if f['path'] in metadata)
report['unique_clone_weight_payload_bytes']=sum(v['unique_storage_bytes'] for v in report['pytorch'].values())+sum(report['onnx'][f]['initializer_bytes'] for f in ['campplus.onnx','speech_tokenizer_v3.onnx'])
report['fp16_neural_plus_original_enrollment_payload_estimate_bytes']=sum(v['fp16_payload_estimate_bytes'] for v in report['pytorch'].values())+sum(report['onnx'][f]['initializer_bytes'] for f in ['campplus.onnx','speech_tokenizer_v3.onnx'])
report['batch_tokenizer_initializer_equivalent']=report['onnx']['speech_tokenizer_v3.onnx']['weight_fingerprint']==report['onnx']['speech_tokenizer_v3.batch.onnx']['weight_fingerprint']
report['size_caveat']='Unique tensor storage/ONNX initializer payload, not final Core ML package size. Graph overhead, compiler packing and later split-graph duplication unmeasured. FP16 estimate is not validated conversion or quality. Quantization not tested.'
(ROOT/'ios/validation/provenance/asset-audit.json').write_text(json.dumps(report,indent=2)+'\n')
print('AUDIT_COMPLETE',json.dumps({k:v for k,v in report.items() if k not in ['pytorch','onnx','files']}),flush=True)
# Purpose: establish measured asset accounting; upstream: official checkpoint and strict model loaders.
# Environment: .venv-upstream; generated 2026-09-29 America/New_York; new file, all lines added.
