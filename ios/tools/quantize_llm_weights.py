# quantize_llm_weights.py
# Requirement: isolated matrix-only LLM Q8/Q4 weight compression with unchanged state/IO/activation contract.
import argparse,collections,hashlib,inspect,json,subprocess,time,traceback
from pathlib import Path
import coremltools as ct
from coremltools.optimize.coreml import OptimizationConfig,OpLinearQuantizerConfig,linear_quantize_weights

def identity(path):
 rows=[]
 for p in sorted(path.rglob('*')):
  if p.is_file():
   h=hashlib.sha256()
   with p.open('rb') as f:
    for chunk in iter(lambda:f.read(4*1024*1024),b''):h.update(chunk)
   rows.append({'path':p.relative_to(path).as_posix(),'bytes':p.stat().st_size,'sha256':h.hexdigest()})
 return {'treeSha256':hashlib.sha256(''.join(f"{r['path']}\0{r['bytes']}\0{r['sha256']}\n" for r in rows).encode()).hexdigest(),'bytes':sum(r['bytes'] for r in rows),'files':rows}
def main():
 p=argparse.ArgumentParser();p.add_argument('--source-root',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--evidence',type=Path,required=True);p.add_argument('--bits',type=int,choices=[8,4],default=8);p.add_argument('--q4-rescue-per-channel',action='store_true');p.add_argument('--roles',nargs='+',choices=['prefill','decode'],default=['prefill','decode']);a=p.parse_args();assert not a.q4_rescue_per_channel or a.bits==4,'rescue flag requires INT4';a.output.mkdir(parents=True,exist_ok=True);a.evidence.mkdir(parents=True,exist_ok=True)
 tag=f'Q{a.bits}';granularity='per_channel' if a.bits==8 or a.q4_rescue_per_channel else 'per_block'
 options={'mode':'linear_symmetric','dtype':f'int{a.bits}','granularity':granularity,'weight_threshold':2048}
 if a.bits==4 and not a.q4_rescue_per_channel:options['block_size']=32
 source_sha=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip();result={'status':'CONVERTING','sourceCommit':source_sha,'scriptSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'coremltools':ct.__version__,'candidate':tag+'_WEIGHT_ONLY_'+granularity.upper(),'config':dict(options,selection='only const inputs to linear.weight; no bias/mask/activation/state'),'compressionAPI':'coremltools.optimize.coreml.linear_quantize_weights','sourceWeightDtype':'CoreMLFP16; sourcecheckpointFP32 independently recorded in prior source_checkpoint_dtype.json','deploymentTarget':'iOS18/CoreML8/spec9 source preserved','computeUnitsRequested':'CPU_AND_NE unchanged','runtimeArithmetic':'floating tensor compute unchanged by compression API; actual ANE arithmetic/weightmaterialization UNKNOWN','productionPromotion':False,'roles':a.roles,'models':{}}
 def save(): (a.evidence/'conversion_receipt.json').write_text(json.dumps(result,indent=2)+'\n')
 save()
 try:
  for role,filename in [('prefill','llm-opt-perlayer-prefill.mlpackage'),('decode','llm-opt-perlayer-decode-maskwrite512.mlpackage')]:
   if role not in a.roles:continue
   print('['+tag+'] source',role,flush=True);start=time.monotonic();src=a.source_root/'models'/filename;dst=a.output/f'cosyvoice-llm-{tag.lower()}-{role}.mlpackage';assert not dst.exists(),'never overwrite candidate'
   original_identity=identity(src);model=ct.models.MLModel(str(src),skip_model_load=True,compute_units=ct.ComputeUnit.CPU_AND_NE);spec=model.get_spec();fn=spec.mlProgram.functions['main'];block=fn.block_specializations['CoreML8'];consts={o.outputs[0].name:o for o in block.operations if o.type=='const' and o.outputs}
   config=OpLinearQuantizerConfig(**options);selected={}
   for op in block.operations:
    if op.type=='linear':
     weight=op.inputs['weight'].arguments[0].name;co=consts[weight];name=co.attributes['name'].immediateValue.tensor.strings.values[0];selected[name]=config
   assert len(selected)==169;print('['+tag+'] quantize169 linear matrices only',role,options,flush=True)
   converted=linear_quantize_weights(model,OptimizationConfig(op_name_configs=selected));new=converted.get_spec();assert new.description.SerializeToString(deterministic=True)==spec.description.SerializeToString(deterministic=True),'IO/state metadata changed';assert new.specificationVersion==spec.specificationVersion
   after=list(new.mlProgram.functions['main'].block_specializations['CoreML8'].operations);counts=collections.Counter(o.type for o in after);before=collections.Counter(o.type for o in block.operations)
   for name in ['linear','matmul','read_state','write_state','select','softmax']:assert counts[name]==before[name],(name,counts[name],before[name])
   assert counts['constexpr_blockwise_shift_scale']==169;converted.save(str(dst));entry={'source':str(src),'sourceIdentity':original_identity,'output':str(dst),'outputIdentity':identity(dst),'selectedWeightNames':sorted(selected),'operationsBefore':dict(before),'operationsAfter':dict(counts),'stateAndDescriptionByteIdentical':True,'deploymentAndSpecificationUnchanged':True,'specificationVersion':new.specificationVersion,'compressionSeconds':time.monotonic()-start};result['models'][role]=entry;save();print('['+tag+'] saved',role,entry['outputIdentity']['bytes'],flush=True)
  result['status']='EXPORTED_NOT_VALIDATED';save()
 except Exception:
  result['status']='CONVERSION_FAILED';result['traceback']=traceback.format_exc();save();raise
if __name__=='__main__':main()
# Purpose: compressed storage experiment only, no production rewrite/overwrite/activation/KV quantization.
# Upstream frozen ac31e117 schema3 LLM MLPrograms; coremltools9/macOS isolated output, generated2026-10-06 America/New_York.
# Q4 update2026-10-06: --bits4 selects supported per-block32 INT4 compression of same169matrices; Q8 default unchanged. Argument/config/output/receipt regions only; exact line map Git diff.

# Compatibility rescue A2026-10-06: explicit --q4-rescue-per-channel tests broadcast scales [Cout,1] supported by installed ct9 config; default/originalQ4block32/Q8 unchanged. No sweep or sourceoverwrite.

# Rebuild recovery requirement: --roles decode permits accepted INT4 rescue-A decode reconstruction without any Full-Q4 prefill.
# Purpose: role restriction only; default legacy two-role behavior and all169-matrix/IO/spec assertions unchanged.
# Upstream: existing quantize_llm_weights.py coremltools9 recipe; runtime local Python3.11/macOS.
# Generated2026-10-06 America/New_York; changed argument/receipt/loop filter regions.
