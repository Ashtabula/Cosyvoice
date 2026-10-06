# collect_enumerated_operation_signatures.py
# Requirement: attach hash-bound serialized tensor types to physical plan SSA names; do not infer actual runtime op placement/shapes from source metadata.
from pathlib import Path
import argparse,json
import coremltools as ct
from coremltools.proto import MIL_pb2

def signature(value):
    tensor=value.tensorType
    if not tensor.rank and not tensor.dataType:return dict(kind='non-tensor-or-state',serializedType=str(value))
    dimensions=[int(d.constant.size) if d.WhichOneof('dimension')=='constant' else 'UNKNOWN' for d in tensor.dimensions]
    return dict(dtype=MIL_pb2.DataType.Name(tensor.dataType),serializedShape=dimensions,dynamicDimension='UNKNOWN' in dimensions,actualRuntimeShape=None)

def main():
    p=argparse.ArgumentParser();p.add_argument('--asset-root',type=Path,required=True);p.add_argument('--partitions',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    work=Path(__file__).parents[1]/'.work/ane-residency'
    plans=[work/'plan-ne-llm-hift/ane-compute-plan-receipt.json',*sorted((work/'matrix').glob('plan-*/ane-compute-plan-receipt.json'))]
    data=dict(schemaVersion=1,meaning='Serialized tensor signatures matched to measured physical MLComputePlan SSA names; preferred/supported only, no actual per-operation assignment',models=[])
    for path in plans:
        receipt=json.loads(path.read_text())
        for model in receipt['models']:
            if model.get('status')!='PASS_COMPUTE_PLAN':continue
            device_path=model['path'];relative=device_path.split('/Runtime/')[-1] if '/Runtime/' in device_path else None
            if relative:source=a.asset_root/relative
            elif '/FlowPartitions/' in device_path:source=a.partitions/device_path.split('/FlowPartitions/')[-1]
            else:continue
            spec=ct.utils.load_spec(str(source/'Data/com.apple.CoreML/model.mlmodel'))
            function=spec.mlProgram.functions['n257_384' if model['role'].startswith('flow') or model['role']=='hift' else 'main']
            values={v.name:signature(v.type) for v in function.inputs};operators={}
            def visit(block):
                for op in block.operations:
                    for v in op.outputs:values[v.name]=signature(v.type);operators[v.name]=op.type
                    for child in op.blocks:visit(child)
            for block in function.block_specializations.values():visit(block)
            cpu=[]
            for operation in model['operations']:
                if 'MLCPUComputeDevice' not in operation['preferred']:continue
                outputs=operation.get('outputs',[]);inputs=operation.get('inputs',{})
                names=[name for group in inputs.values() for name in group]
                cpu.append(dict(operation,serializedInputs={name:values.get(name,dict(unknown=True)) for name in names},serializedOutputs={name:values.get(name,dict(unknown=True)) for name in outputs},
                                actualDeviceAssignment=None,actualFallbackLatencyMilliseconds=None,placementMeaning='anticipated CPU preferred, not measured individual fallback'))
            data['models'].append(dict(physicalPlanReceipt=str(path),sourceCommit=receipt['sourceCommit'],role=model['role'],sourcePackage=str(source),requestedPlacement=model['requestedPlacement'],preferredCounts=model['preferredCounts'],CPUPreferredOperations=cpu,
                                      compilerCausalBlocker=None,actualOpPlacement='UNKNOWN_RESIDENCY',sourceSignatureNotRuntimeMeasurement=True))
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(data,indent=2)+'\n')
    print('[OP-SIGNATURES]',len(data['models']),'physical plan models; actual individual assignments remain UNKNOWN',flush=True)

if __name__=='__main__':main()
# Purpose: exact op/type inventory separate from runtime residency. Upstream frozen/unchanged partition ML Programs and physical plan receipts; Python3.11/coremltools9/macOS. Generated2026-10-06 America/New_York, new file.
