# materialize_existing_flow_te.py
# Requirement: expose existing te cast result without adding/changing any operation or weight; diagnose fullFlow GPU endpoint divergence.
from pathlib import Path
import copy,json
import coremltools as ct
from audit_enumerated_ane_graphs import fingerprint
root=Path('/private/tmp/cosy-flow-partitions-20261005');source=root/'p1/group-0.mlpackage';destination=root/'p1-te/group-0.mlpackage';destination.parent.mkdir(exist_ok=True)
if destination.exists():raise RuntimeError('never overwrite diagnostic package')
model=ct.models.MLModel(str(source),skip_model_load=True);original=model.get_spec();spec=copy.deepcopy(original)
old=ct.models.MLModel('ios/.work/enumerated-n1-n450/generated-ac31e117938ed50132365973a103cc8425942700/enumerated-acoustic/flow-shard-0.mlpackage',skip_model_load=True).get_spec()
for desc in spec.description.functions:
 original_desc=next(f for f in old.description.functions if f.name==desc.name)
 desc.output.append(copy.deepcopy(next(v for v in original_desc.output if v.name=='te')))
 block=spec.mlProgram.functions[desc.name].block_specializations['CoreML8'];block.outputs.append('te')
 assert [o.SerializeToString(deterministic=True) for o in block.operations]==[o.SerializeToString(deterministic=True) for o in original.mlProgram.functions[desc.name].block_specializations['CoreML8'].operations]
ct.models.MLModel(spec,weights_dir=model.weights_dir,skip_model_load=True).save(str(destination))
p=root/'partition-export-receipt.json';r=json.loads(p.read_text());r['variants']['1-te']=copy.deepcopy(r['variants']['1']);v=r['variants']['1-te'];v['scope']='Expose existing te cast result as extra diagnostic output; zero operation/weight/precision changes; test backend materialization';v['packages'][0]['path']=str(destination);v['packages'][0]['identity']=fingerprint(destination)
p.write_text(json.dumps(r,indent=2,sort_keys=True)+'\n');Path('ios/validation/evidence/equivalent_flow_partition_export.json').write_text(p.read_text())
print('exported existing-te diagnostic',v['packages'][0]['identity']['bytes'],flush=True)
# Purpose: isolate GPU lowering boundary materialization; primary velocity ABI unchanged.
# Upstream frozen-derived fullFlow; environment coremltools9/Python3.11/macOS. Generated2026-10-05 America/New_York; new file.
