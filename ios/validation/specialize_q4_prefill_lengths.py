# specialize_q4_prefill_lengths.py
# Requirement: specialize only sequence length of the frozen rescue-A Q4 prefill, preserving every compressed weight byte/state ABI/operator/input binding.
import argparse,copy,hashlib,json,os,shutil,subprocess
from collections import Counter,defaultdict
from pathlib import Path
import coremltools as ct
from coremltools.converters.mil.frontend.milproto.load import load

def sha(path):
 h=hashlib.sha256()
 with Path(path).open('rb') as f:
  for b in iter(lambda:f.read(4*1024*1024),b''):h.update(b)
 return h.hexdigest()
def identity(folder):
 rows=[{'path':p.relative_to(folder).as_posix(),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(folder.rglob('*')) if p.is_file()]
 return {'treeSha256':hashlib.sha256(''.join(f"{r['path']}\0{r['bytes']}\0{r['sha256']}\n" for r in rows).encode()).hexdigest(),'bytes':sum(x['bytes'] for x in rows),'files':rows}
def specialize(message,length):
 changes=0
 # Every224 tensor dimension in this exact graph is sequence-derived; source weight/state dimensions are independently protected below.
 for field,value in message.ListFields():
  if field.type != field.TYPE_MESSAGE:continue
  items=value.values() if field.message_type.GetOptions().map_entry else value if field.is_repeated else (value,)
  for child in items:
   if field.name=='dimensions' and child.HasField('constant') and child.constant.size==224:
    child.constant.size=length;changes+=1
   else:changes+=specialize(child,length)
 return changes

def main():
 p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--evidence',type=Path,required=True);p.add_argument('--lengths',type=int,nargs='+',default=[1,16,32,64,128,224]);a=p.parse_args();assert all(1<=n<=224 for n in a.lengths)
 a.output.mkdir(parents=True,exist_ok=True);a.evidence.mkdir(parents=True,exist_ok=True)
 original=identity(a.source);assert original['treeSha256']=='905f29f5ffa83161cf91d4d93db6fd28423f246b0e43acdbbe1ff646151eaee4'
 model=ct.models.MLModel(str(a.source),skip_model_load=True);spec=model.get_spec();block=spec.mlProgram.functions['main'].block_specializations['CoreML8'];counts=Counter(op.type for op in block.operations);assert counts['linear']==counts['constexpr_blockwise_shift_scale']==169 and counts['slice_update']==48
 uses=defaultdict(list)
 for op in block.operations:
  for port,binding in op.inputs.items():
   for argument in binding.arguments:
    if argument.name:uses[argument.name].append((op.type,port))
 sequence_constants=[op.outputs[0].name for op in block.operations if op.type=='const' and 224 in op.attributes['val'].immediateValue.tensor.ints.values]
 assert len(sequence_constants)==361
 assert Counter(role for name in sequence_constants for role in uses[name])==Counter({('slice_by_index','end'):289,('slice_update','end'):48,('reshape','shape'):24})
 compressed=[op.SerializeToString(deterministic=True) for op in block.operations if op.type=='constexpr_blockwise_shift_scale'];states=[x.SerializeToString(deterministic=True) for x in spec.description.state]
 receipt={'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'scriptSHA256':sha(Path(__file__)),'coremltools':ct.__version__,'sourceIdentity':original,'sourceWeightScheme':'INT4 symmetric per_channel169 matrices; no requantization','computeUnits':'CPU_AND_NE','originalProductionLength':224,'decodeUntouched':True,'variants':[]}
 def save(): (a.evidence/'specialization_receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 save()
 for length in a.lengths:
  dest=a.output/f'prefill-l{length:03d}.mlpackage';assert not dest.exists(),'never overwrite a variant';row={'length':length,'status':'SPECIALIZING','destination':str(dest)};receipt['variants'].append(row);save();print('[PREFILL-LENGTH] specialize',length,flush=True)
  try:
   if length==224:
    shutil.copytree(a.source,dest,copy_function=os.link);row['sourceByteIdentical']=True;row['typeDimensionChanges']=0;row['integerConstantChanges']=[]
   else:
    new=copy.deepcopy(spec);row['typeDimensionChanges']=specialize(new.mlProgram,length);integer_changes=[]
    for feature in new.description.input:
     shape=feature.type.multiArrayType.shape
     for i,value in enumerate(shape):
      if value==224:shape[i]=length
    nb=new.mlProgram.functions['main'].block_specializations['CoreML8']
    for op in nb.operations:
     if op.type!='const':continue
     value=op.attributes['val'];ints=value.immediateValue.tensor.ints.values
     if 224 in ints:
      before=list(ints)
      for i,n in enumerate(ints):
       if n==224:ints[i]=length
      integer_changes.append({'name':op.outputs[0].name,'before':before,'after':list(ints)})
    assert len(integer_changes)==361, len(integer_changes)
    assert {x['name'] for x in integer_changes}==set(sequence_constants)
    assert [op.SerializeToString(deterministic=True) for op in nb.operations if op.type=='constexpr_blockwise_shift_scale']==compressed
    assert [x.SerializeToString(deterministic=True) for x in new.description.state]==states
    assert counts==Counter(op.type for op in nb.operations)
    # Reconstruct MIL and validate inferred outputs against stored specialized tensor types.
    program=load(new,new.specificationVersion,model.weights_dir)
    program.validate()
    for function in program.functions.values():
     for op in function.operations:
      stored=[x.sym_type for x in op.outputs];op.type_value_inference(overwrite_output=True);assert stored==[x.sym_type for x in op.outputs],op.name
    clone=ct.models.MLModel(new,weights_dir=model.weights_dir,skip_model_load=True,compute_units=ct.ComputeUnit.CPU_AND_NE);clone.save(str(dest));row['integerConstantChanges']=integer_changes
    candidate_weight=dest/'Data/com.apple.CoreML/weights/weight.bin';source_weight=a.source/'Data/com.apple.CoreML/weights/weight.bin';assert sha(candidate_weight)==sha(source_weight)
    candidate_weight.unlink();os.link(source_weight,candidate_weight)
   row.update(status='STATIC_VALIDATED_NOT_DEVICE_TESTED',packageIdentity=identity(dest),compressed169OperationsByteIdentical=True,stateSchemaByteIdentical=True,operatorCounts=dict(counts),weightBlobByteIdentical=True,metadataOnlyShapeEdit=False)
  except Exception as error:
   import traceback;row.update(status='SPECIALIZATION_FAILED',error=str(error),traceback=traceback.format_exc());print(row['traceback'],flush=True)
  save()
 assert identity(a.source)==original,'source changed'
 print('[PREFILL-LENGTH] complete; source unchanged',flush=True)
if __name__=='__main__':main()
# Purpose: real graph specialization including input/output inferred types and static sequence slice/reshape/state-write extents, never description-only metadata widening.
# Upstream exact frozen rescue-A CoreML8/spec9 prefill; same169INT4 weight expressions/blob and48FP16states. No new quantization/decode export.
# Environment installed coremltools9/macOS; generated2026-10-06 America/New_York. New diagnostic tool; source artifacts remain immutable.
