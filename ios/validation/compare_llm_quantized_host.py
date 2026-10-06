# compare_llm_quantized_host.py
# Requirement: controlled common-input stateful numerical comparison, not speech-quality or physical-device proof.
import argparse,gc,hashlib,json,math,time,traceback
from pathlib import Path
import numpy as np
import coremltools as ct

def compare(a,b):
 a=np.asarray(a,dtype=np.float64).reshape(-1);b=np.asarray(b,dtype=np.float64).reshape(-1);d=a-b
 return {'maxAbs':float(np.max(np.abs(d))),'meanAbs':float(np.mean(np.abs(d))),'RMSE':float(np.sqrt(np.mean(d*d))),'cosine':float(a.dot(b)/max(np.linalg.norm(a)*np.linalg.norm(b),1e-30))}
def main():
 p=argparse.ArgumentParser();p.add_argument('--baseline',type=Path,required=True);p.add_argument('--candidate',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--bits',type=int,choices=[8,4],default=8);p.add_argument('--q8',type=Path);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
 if a.bits==4 and a.q8 is None:raise ValueError('three-way Q4 host comparison requires actual Q8 packages')
 emb=np.memmap(a.baseline/'embeddings/speech_embedding_fp16.bin',dtype=np.float16,mode='r',shape=(6761,896));steps=64;fixture={'scope':'diagnostic deterministic speech-embedding prefill224 +commonteacherforced64decode; not actualinstruction/referenceprefix','compute':'macOSCPU_ONLY sameboth','KV':'oneprefillMLState sharedwithsamemodelvariantdecode,48FP16statesunchanged','tokens':[(i*37+11)%6500 for i in range(224+steps)]};(a.output/'fixture.json').write_text(json.dumps(fixture,indent=2)+'\n')
 def rope(positions):
  c=[];s=[]
  for pos in positions:
   cv=[math.cos(pos/(1000000.0**(2*i/64))) for i in range(32)];sv=[math.sin(pos/(1000000.0**(2*i/64))) for i in range(32)];c.append(cv+cv);s.append(sv+sv)
  return np.asarray(c,dtype=np.float16).reshape(1,1,len(c),64),np.asarray(s,dtype=np.float16).reshape(1,1,len(s),64)
 results={}
 try:
  for variant in (['baseline','q8'] if a.bits==8 else ['baseline','q8','q4']):
   root=a.q8 if variant=='q8' and a.bits==4 else a.candidate
   paths=(a.baseline/'models/llm-opt-perlayer-prefill.mlpackage',a.baseline/'models/llm-opt-perlayer-decode-maskwrite512.mlpackage') if variant=='baseline' else (root/f'cosyvoice-llm-{variant}-prefill.mlpackage',root/f'cosyvoice-llm-{variant}-decode.mlpackage')
   print('[Q8-HOST] load',variant,flush=True);prefill=ct.models.MLModel(str(paths[0]),compute_units=ct.ComputeUnit.CPU_ONLY);decode=ct.models.MLModel(str(paths[1]),compute_units=ct.ComputeUnit.CPU_ONLY);state=prefill.make_state();c,s=rope(range(224));mask=np.full((1,1,224,224),-65504,dtype=np.float16)
   for i in range(224):mask[0,0,i,:i+1]=0
   result=prefill.predict({'x':np.asarray(emb[fixture['tokens'][:224]]).reshape(1,224,896),'cos':c,'sin':s,'mask':mask},state=state);logits=[result['logits'].copy()];hidden=[result['hidden'].copy()]
   for i in range(steps):
    position=224+i;c,s=rope([position]);mask=np.full((1,1,1,512),-65504,dtype=np.float16);mask[:,:,:,:position+1]=0;write=np.zeros((1,1,512,1),dtype=np.float16);write[0,0,position,0]=1
    result=decode.predict({'x':np.asarray(emb[fixture['tokens'][224+i]]).reshape(1,1,896),'cos':c,'sin':s,'mask':mask,'write_mask':write},state=state);logits.append(result['logits'].copy());hidden.append(result['hidden'].copy())
    if (i+1)%16==0: print('[Q8-HOST]',variant,'decode',i+1,flush=True)
   states={name:state.read_state(name).copy() for name in sorted(decode.get_spec().description.state[i].name for i in range(48))};data={'logits':np.asarray(logits),'hidden':np.asarray(hidden),**states};np.savez(a.output/(variant+'-outputs.npz'),**data);results[variant]={'finite':all(np.isfinite(x).all() for x in data.values()),'observedStateDtypes':sorted(set(str(x.dtype) for x in states.values()))};del state,prefill,decode,result,logits,hidden,states,data;gc.collect()
  b=np.load(a.output/'baseline-outputs.npz');q=np.load(a.output/f'q{a.bits}-outputs.npz');rows=[]
  for i,(x,y) in enumerate(zip(q['logits'],b['logits'])):
   xx=x.reshape(-1);yy=y.reshape(-1);rows.append({'step':i,'stage':'prefill' if i==0 else 'decode',**compare(x,y),'top1Match':bool(np.argmax(xx)==np.argmax(yy)),'top20Overlap':len(set(np.argsort(xx)[-20:])&set(np.argsort(yy)[-20:]))/20,'hidden':compare(q['hidden'][i],b['hidden'][i])})
  results.update(status='HOST_NUMERICAL_COMPLETE_NOT_QUALITY_PASS',candidate=f'q{a.bits}',rows=rows,stateErrors={name:compare(q[name],b[name]) for name in b.files if name not in ['logits','hidden']},decodeTop1Agreement=sum(x['top1Match'] for x in rows[1:])/steps,decodeTop20OverlapMean=float(np.mean([x['top20Overlap'] for x in rows[1:]])))
  if a.bits==4:
   eight=np.load(a.output/'q8-outputs.npz');extra=[]
   for i,(x,y) in enumerate(zip(q['logits'],eight['logits'])):
    xx=x.reshape(-1);yy=y.reshape(-1);extra.append({'step':i,**compare(x,y),'top1Match':bool(np.argmax(xx)==np.argmax(yy)),'top20Overlap':len(set(np.argsort(xx)[-20:])&set(np.argsort(yy)[-20:]))/20,'hidden':compare(q['hidden'][i],eight['hidden'][i])})
   results['Q4vsQ8']={'rows':extra,'stateErrors':{name:compare(q[name],eight[name]) for name in eight.files if name not in ['logits','hidden']},'decodeTop1Agreement':sum(x['top1Match'] for x in extra[1:])/steps,'decodeTop20OverlapMean':float(np.mean([x['top20Overlap'] for x in extra[1:]]))}
  results['stateDtypeMeaning']='Python read_state float32 bridge views; encoded MLState and native IO remain FP16, not activation/KV quantization'
  (a.output/'numerical_summary.json').write_text(json.dumps(results,indent=2)+'\n');print('[QUANT-HOST] complete',results['decodeTop1Agreement'],flush=True)
 except Exception:
  results.update(status='HOST_COMPARISON_FAILED',traceback=traceback.format_exc());(a.output/'numerical_summary.json').write_text(json.dumps(results,indent=2)+'\n');raise
if __name__=='__main__':main()
# Purpose: pairedlogits/hidden/KV errors withstatefulteacherforcing; baselineQ8inputbytesidentical.
# Upstream frozenperlayerMLState/CoreML models; coremltools9/macOSCPU-only, generated2026-10-06 America/New_York.
# Q4 update2026-10-06: optional bits4/q8 runs all three samefixture64teachersteps and characterizes Q4vsCurrent/Q8, default8 preserved. Git diff line map.
