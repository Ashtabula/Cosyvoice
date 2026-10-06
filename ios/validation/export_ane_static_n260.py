# export_ane_static_n260.py
# Requirement: diagnostic exact N260 input contract of the unchanged extracted n257_384 program; preserve every MIL byte and weight byte.
from pathlib import Path
import argparse, copy, hashlib, json
import coremltools as ct
from audit_enumerated_ane_graphs import fingerprint

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--static-program-inputs',action='store_true')
    args=parser.parse_args()
    if args.output.exists(): raise RuntimeError('never overwrite existing diagnostic assets')
    args.output.mkdir(parents=True)
    parent=json.loads((args.source/'export-receipt.json').read_text())
    receipt=dict(schemaVersion=1,N=260,function='n257_384',diagnosticOnly=True,productionPromotion=False,
                 scope='input descriptor and optional input tensor-type narrowing; every operator block and weight unchanged',models={})
    for role,binding in parent['models'].items():
        package=args.source/(role+'.mlpackage')
        model=ct.models.MLModel(str(package),skip_model_load=True)
        original=model.get_spec();spec=copy.deepcopy(original);shapes={}
        for feature in spec.description.input:
            value=feature.type.multiArrayType
            if value.enumeratedShapes.shapes:
                if len(value.enumeratedShapes.shapes)!=128: raise RuntimeError('unexpected enumerated bucket size')
                shape=list(value.enumeratedShapes.shapes[3].shape)
                value.ClearField('enumeratedShapes');value.ClearField('shapeRange')
                del value.shape[:];value.shape.extend(shape)
            shapes[feature.name]=list(value.shape)
        if args.static_program_inputs:
            for parameter in spec.mlProgram.functions['main'].inputs:
                dimensions=parameter.type.tensorType.dimensions
                shape=shapes[parameter.name]
                if len(dimensions)!=len(shape):raise RuntimeError('input rank mismatch')
                for dimension,size in zip(dimensions,shape):
                    dimension.Clear();dimension.constant.size=size
        unchanged=spec.mlProgram.functions['main'].block_specializations==original.mlProgram.functions['main'].block_specializations
        if not unchanged: raise RuntimeError('MIL operator blocks modified')
        destination=args.output/(role+'.mlpackage')
        ct.models.MLModel(spec,weights_dir=model.weights_dir,skip_model_load=True).save(str(destination))
        before=fingerprint(package);after=fingerprint(destination)
        def weights(identity):return sorted((f['bytes'],f['sha256']) for f in identity['files'] if '/weights/' in f['path'])
        if weights(before)!=weights(after):raise RuntimeError('weight payload changed')
        receipt['models'][role]=dict(source=binding['source'],sourceIdentity=binding['sourceIdentity'],
                                    extractedSourceIdentity=before,experimentalIdentity=after,graphIdentical=not args.static_program_inputs,weightsIdentical=True,operatorBlocksByteIdentical=True,programInputTypesStatic=args.static_program_inputs,
                                    inputShapes=shapes,status='EXPORTED_HOST_AND_PHYSICAL_GATES_PENDING')
        (args.output/'export-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
        print('[ANE-STATIC-EXPORT]',role,shapes,'operator blocks/weights byte-identical',flush=True)

if __name__=='__main__':main()
# Purpose: separate enumerated-input specialization limits from graph limits. Upstream frozen n257_384 single-function diagnostic; Python3.11/coremltools9/macOS, generated2026-10-05 America/New_York. New file; shipping four-bucket packages untouched.
