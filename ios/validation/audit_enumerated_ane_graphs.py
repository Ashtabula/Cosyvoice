# audit_enumerated_ane_graphs.py
# Requirement: separately audit frozen LLM prefill/decode serialized operations, I/O and state ABI; never mutate packages.
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import coremltools as ct
from google.protobuf.json_format import MessageToDict

def fingerprint(root):
    rows=[]
    for p in sorted(root.rglob('*')):
        if p.is_file():
            h=hashlib.sha256()
            with p.open('rb') as f:
                for b in iter(lambda:f.read(4*1024*1024),b''): h.update(b)
            rows.append(dict(path=p.relative_to(root).as_posix(),bytes=p.stat().st_size,sha256=h.hexdigest()))
    h=hashlib.sha256()
    for r in rows: h.update(f"{r['path']}\0{r['bytes']}\0{r['sha256']}\n".encode())
    return dict(treeSha256=h.hexdigest(),bytes=sum(r['bytes'] for r in rows),files=rows)

def main():
    p=argparse.ArgumentParser();p.add_argument('--asset-root',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    manifest=json.loads((a.asset_root/'cosyvoice3_enumerated.json').read_text())
    names={r:manifest[r] for r in ['llmPrefill','llmDecode']}
    names.update(conditions=manifest['flowConditions'],hift=manifest['hift'])
    names.update({f'flow{i}':f'enumerated-acoustic/flow-shard-{i}.mlpackage' for i in range(6)})
    names.update(speechTokenizer=manifest['referenceEnrollment']['speechTokenizer'],campPlus=manifest['referenceEnrollment']['campPlus'])
    data=dict(schemaVersion=1,source='frozen serialized ML Program',models={},meaning='Operation presence is graph evidence; unsupported ANE attribution requires device compiler evidence. No runtime residency claim.')
    for role,name in names.items():
        model=ct.models.MLModel(str(a.asset_root/name),skip_model_load=True);spec=model.get_spec()
        functions=[]
        for fn,func in spec.mlProgram.functions.items():
            for specialization,block in func.block_specializations.items():
                counts=Counter();dynamic=[];state=[]
                def walk(b):
                    for op in b.operations:
                        counts[op.type]+=1
                        if op.type in ['read_state','write_state','coreml_update_state','slice_update','gather','gather_along_axis','select','reshape','while_loop','cond','slice_by_index']:
                            row=dict(type=op.type,outputs=[v.name for v in op.outputs],inputs=MessageToDict(op).get('inputs',{}))
                            (state if 'state' in op.type else dynamic).append(row)
                        for child in op.blocks:walk(child)
                walk(block)
                functions.append(dict(name=fn,specialization=specialization,operationCounts=dict(counts),stateTransitions=state,shapeAndIndexOperations=dynamic))
        data['models'][role]=dict(path=name,identity=fingerprint(a.asset_root/name),specificationVersion=spec.specificationVersion,description=MessageToDict(spec.description),functions=functions)
        print('[ANE-GRAPH-AUDIT]',role,functions[0]['operationCounts'],flush=True)
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(data,indent=2,sort_keys=True)+'\n')
if __name__=='__main__':main()
# Purpose: immutable graph identity/ABI/op inventory, separate prefill vs decode analysis.
# Upstream: frozen schema-3 Core ML packages; upstream purpose exact N1...450 public synthesis.
# Runtime: coremltools9/Python3.11/macOS, model load disabled. Generated 2026-10-05 America/New_York; all lines new.
