# repack_equivalent_flow_partitions.py
# Requirement: concatenate adjacent frozen MIL graphs without deleting/changing any operation, dtype, cast or weight byte; retain all four functions.
from pathlib import Path
from collections import Counter
import argparse,copy,hashlib,json,shutil,subprocess,tempfile,traceback
import coremltools as ct
from audit_enumerated_ane_graphs import fingerprint

def transform(message,names,weight):
 for field,value in message.ListFields():
  if field.type==field.TYPE_MESSAGE:
   if field.is_repeated:
    children=value.values() if field.message_type.GetOptions().map_entry else value
    for child in children:
     if hasattr(child,'ListFields'):transform(child,names,weight)
   else:transform(value,names,weight)
  elif field.type==field.TYPE_STRING:
   if field.name=='name' and not field.is_repeated and value in names:setattr(message,field.name,names[value])
   elif field.name=='fileName' and not field.is_repeated and value=='@model_path/weights/weight.bin':setattr(message,field.name,'@model_path/weights/'+weight)
   elif field.name=='outputs' and field.is_repeated:
    for i,v in enumerate(value):
     if v in names:value[i]=names[v]

def main():
 p=argparse.ArgumentParser();p.add_argument('--asset-root',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 a.output.mkdir(parents=True,exist_ok=True)
 models=[ct.models.MLModel(str(a.asset_root/f'enumerated-acoustic/flow-shard-{i}.mlpackage'),skip_model_load=True) for i in range(6)]
 specs=[m.get_spec() for m in models];functions=sorted(specs[0].mlProgram.functions)
 receipt=dict(schemaVersion=1,sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),algorithmUnchanged=True,scope='serialized MIL concatenation only; all boundary casts preserved; original weight files kept byte identical; no conversion/reprecision',families=functions,variants={},sourcePackages={f'flow{i}':fingerprint(a.asset_root/f'enumerated-acoustic/flow-shard-{i}.mlpackage') for i in range(6)},productionPromotion=False)
 for count,groups in [(3,[[0,1],[2,3],[4,5]]),(2,[[0,1,2],[3,4,5]]),(1,[list(range(6))])]:
  folder=a.output/f'p{count}';folder.mkdir(exist_ok=True);variant=dict(groups=groups,packages=[],status='EXPORTING')
  receipt['variants'][str(count)]=variant
  for index,group in enumerate(groups):
   dest=folder/f'group-{index}.mlpackage'
   if dest.exists():variant['status']='EXISTS_NOT_OVERWRITTEN';continue
   try:
    out=copy.deepcopy(specs[group[0]]);out.mlProgram.ClearField('functions');out.description.ClearField('functions')
    mapping=[]
    for fn in functions:
     function=copy.deepcopy(specs[group[0]].mlProgram.functions[fn]);function.ClearField('block_specializations')
     desc=copy.deepcopy(next(f for f in specs[group[0]].description.functions if f.name==fn));desc.ClearField('output')
     previous=None;carried_te='te';count_before=Counter();count_after=Counter()
     for i in group:
      original=specs[i].mlProgram.functions[fn];block=original.block_specializations['CoreML8']
      names={v.name:f's{i}_{v.name}' for op in block.operations for v in op.outputs}
      if i==group[0]:names.update({v.name:v.name for v in original.inputs})
      else:names.update(h=previous,te=carried_te,mask='mask')
      if i==0: names['te']='te';carried_te='te'
      final_name='velocity' if i==5 else ('h' if group[0]==0 else 'h_out')
      if i==group[-1]:names['velocity' if i==5 else 'h' if i==0 else 'h_out']=final_name
      for op in block.operations:
       clone=copy.deepcopy(op);transform(clone,names,f'weight-s{i}.bin')
       if 'name' in clone.attributes:
        strings=clone.attributes['name'].immediateValue.tensor.strings.values
        if strings:strings[0]=f's{i}_'+strings[0]
       # Exact equality against independently renamed source: no arithmetic attributes/constants changed.
       expected=copy.deepcopy(op);transform(expected,names,f'weight-s{i}.bin')
       if 'name' in expected.attributes:
        strings=expected.attributes['name'].immediateValue.tensor.strings.values
        if strings:strings[0]=f's{i}_'+strings[0]
       assert clone.SerializeToString(deterministic=True)==expected.SerializeToString(deterministic=True)
       function.block_specializations['CoreML8'].operations.append(clone)
      previous=names['velocity' if i==5 else 'h' if i==0 else 'h_out']
      count_before.update(op.type for op in block.operations)
     merged=function.block_specializations['CoreML8'];merged.outputs.append(previous)
     last=next(f for f in specs[group[-1]].description.functions if f.name==fn)
     feature=copy.deepcopy(last.output[0]);feature.name=previous;desc.output.append(feature)
     if group[0]==0 and group[-1]!=5:
      merged.outputs.append('te');desc.output.append(copy.deepcopy(next(f for f in next(d for d in specs[0].description.functions if d.name==fn).output if f.name=='te')))
     count_after.update(op.type for op in merged.operations);assert count_before==count_after
     out.mlProgram.functions[fn].CopyFrom(function);out.description.functions.append(desc)
     mapping.append(dict(function=fn,sourceShardIndices=group,inputNames=[v.name for v in function.inputs],outputNames=list(merged.outputs),sourceOperationCounts=dict(count_before),optimizedOperationCounts=dict(count_after),allSourceOperationsPreserved=True,boundaryCastsPreserved=True))
    with tempfile.TemporaryDirectory(prefix='cosy-flow-repack-') as temp:
     weights=Path(temp)
     for i in group:
      source=Path(models[i].weights_dir)/'weight.bin';destination=weights/f'weight-s{i}.bin';shutil.copyfile(source,destination)
      assert hashlib.sha256(source.read_bytes()).hexdigest()==hashlib.sha256(destination.read_bytes()).hexdigest()
     ct.models.MLModel(out,weights_dir=str(weights),skip_model_load=True).save(str(dest))
    variant['packages'].append(dict(path=str(dest),identity=fingerprint(dest),partitionMapping=mapping,weightBytesUnchanged=True))
    print('[EQUIVALENT-REPACK] EXPORTED',count,index,group,flush=True)
   except Exception as e:
    variant.setdefault('failures',[]).append(dict(group=group,error=str(e),traceback=traceback.format_exc()));print('[EQUIVALENT-REPACK] FAILED',count,index,str(e),flush=True)
   (a.output/'partition-export-receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
  variant['status']='EXPORTED_HOST_PARITY_PENDING' if len(variant['packages'])==count else 'EXPORT_FAILED_OR_INCOMPLETE'
  (a.output/'partition-export-receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
if __name__=='__main__':main()
# Purpose: lossless graph partition experiments 6->3/2/1 with four original multifunction families and exact weights.
# Upstream: frozen schema-3 Flow shards; runtime Python3.11/coremltools9/macOS. Generated2026-10-05 America/New_York; new file.
