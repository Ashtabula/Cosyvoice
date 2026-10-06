# export_flow_partition_single.py
# Requirement: clone only exact n257_384 of lossless p2/p3 partitions for diagnostic plans, preserve operation and weight bytes.
from pathlib import Path
import argparse,copy,json,subprocess
import coremltools as ct
from audit_enumerated_ane_graphs import fingerprint

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--partitions',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    if args.output.exists():raise RuntimeError('never overwrite diagnostic export')
    args.output.mkdir(parents=True);rows=[]
    for count in [2,3]:
        folder=args.output/f'p{count}';folder.mkdir()
        for index in range(count):
            source=args.partitions/f'p{count}/group-{index}.mlpackage';output=folder/f'flow{index}.mlpackage'
            model=ct.models.MLModel(str(source),skip_model_load=True);original=model.get_spec();spec=copy.deepcopy(original)
            selected=next(f for f in original.description.functions if f.name=='n257_384')
            spec.description.input.extend(selected.input);spec.description.output.extend(selected.output);spec.description.state.extend(selected.state)
            spec.description.ClearField('functions');spec.description.ClearField('defaultFunctionName');function=copy.deepcopy(original.mlProgram.functions['n257_384'])
            spec.mlProgram.ClearField('functions');spec.mlProgram.functions['main'].CopyFrom(function)
            assert spec.mlProgram.functions['main'].SerializeToString(deterministic=True)==original.mlProgram.functions['n257_384'].SerializeToString(deterministic=True)
            ct.models.MLModel(spec,weights_dir=model.weights_dir,skip_model_load=True).save(str(output))
            before=fingerprint(source);after=fingerprint(output)
            def weights(value):return sorted((f['bytes'],f['sha256']) for f in value['files'] if '/weights/' in f['path'])
            assert weights(before)==weights(after)
            rows.append(dict(partition=count,role=f'flow{index}',sourcePackage=str(source),sourceIdentity=before,package=str(output),identity=after,selectedFunctionByteIdentical=True,weightsByteIdentical=True,diagnosticOnly=True))
            print('[FLOW-PARTITION-SINGLE]',count,index,after['treeSha256'],flush=True)
    (args.output/'export-receipt.json').write_text(json.dumps(dict(schemaVersion=1,sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),status='EXPORTED_NUMERICAL_AND_DEVICE_GATES_PENDING',packages=rows,promotion=False),indent=2)+'\n')

if __name__=='__main__':main()
# Purpose: distinguish packaging failure from graph coverage. Upstream unchanged four-function Flow partitions; Python3.11/coremltools9/macOS, generated2026-10-06 America/New_York. New script; no shipping overwrite or performance promotion.
