# audit_handoff_closure.py
# Requirement: independently redownload the already new immutable HF release into an empty directory and extract actual package/spec/program/IO/state evidence without changing prior reports or runtime bytes.
import argparse
import hashlib
import json
from pathlib import Path
import sys
import coremltools as ct
from huggingface_hub import HfApi, snapshot_download


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def rows(root):
    return [dict(path=p.relative_to(root).as_posix(), bytes=p.stat().st_size, sha256=sha(p))
            for p in sorted(root.rglob('*')) if p.is_file()]


def tree(items):
    digest = hashlib.sha256()
    for r in sorted(items, key=lambda x: x['path']):
        digest.update((r['path'] + '\0' + str(r['bytes']) + '\0' + r['sha256'] + '\n').encode())
    return digest.hexdigest()


def feature(f):
    kind = f.type.WhichOneof('Type')
    out = dict(name=f.name, kind=kind)
    a = f.type.stateType.arrayType if kind == 'stateType' else f.type.multiArrayType if kind == 'multiArrayType' else None
    if a is not None:
        out.update(shape=list(a.shape), dtype=ct.proto.FeatureTypes_pb2.ArrayFeatureType.ArrayDataType.Name(a.dataType))
        shapes = [list(s.shape) for s in a.enumeratedShapes.shapes]
        if shapes:
            out.update(enumeratedShapeCount=len(shapes), enumeratedShapeSHA256=hashlib.sha256(json.dumps(shapes).encode()).hexdigest())
        if a.shapeRange.sizeRanges:
            out['shapeRanges'] = [[s.lowerBound, s.upperBound] for s in a.shapeRange.sizeRanges]
    return out


def abi(description):
    return dict(inputs=[feature(f) for f in description.input], outputs=[feature(f) for f in description.output],
                states=[feature(f) for f in description.state], stateCount=len(description.state))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--verification-directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--prior-evidence', type=Path, required=True)
    args = parser.parse_args()
    assert not args.verification_directory.exists(), 'verification directory must be new and empty'
    args.output.mkdir(parents=True, exist_ok=False)
    prior = args.prior_evidence
    upload = json.loads((prior / 'hf-upload-receipt.json').read_text())
    inventory = json.loads((prior / 'NEW_ASSET_INVENTORY.json').read_text())
    expected = json.loads((prior / 'uploaded-file-inventory.json').read_text())
    api = HfApi()
    info = api.repo_info(upload['repoId'], revision=upload['revision'])
    assert info.sha == upload['revision'] and info.private
    snapshot_download(upload['repoId'], revision=upload['revision'], repo_type='model',
                      allow_patterns=[upload['pathInRepo'] + '/**'], local_dir=args.verification_directory,
                      cache_dir=args.verification_directory.parent / (args.verification_directory.name + '-fresh-cache'),
                      force_download=True)
    root = args.verification_directory / upload['pathInRepo']
    actual = rows(root)
    assert actual == expected, 'remote full file inventory differs'
    manifest = json.loads((root / 'hf-profile-collection-manifest.json').read_text())
    assert tree([r for r in actual if r['path'] != 'hf-profile-collection-manifest.json']) == upload['collectionTreeSha256']
    profiles = ['current', 'q8', 'hybrid_q4']
    assert [p['profileID'] for p in manifest['profiles']] == profiles and not manifest['fullQ4PrefillIncluded']
    metadata = []
    for p in sorted(root.rglob('*.mlpackage')):
        spec = ct.utils.load_spec(str(p))
        item = dict(path=p.relative_to(root).as_posix(), packageSHA256=tree(rows(p)),
                    packageBytes=sum(r['bytes'] for r in rows(p)), specificationVersion=spec.specificationVersion,
                    modelType=spec.WhichOneof('Type'), programVersion=spec.mlProgram.version,
                    functions=[dict(name=k, opset=v.opset) for k,v in spec.mlProgram.functions.items()],
                    rootABI=abi(spec.description), functionABIs=[dict(name=f.name, **abi(f)) for f in spec.description.functions],
                    deploymentEvidence='Actual specification/opset read from remote protobuf; minimumOS mapping from frozen original converter target, not a fabricated protobuf OS field.')
        metadata.append(item)
        print('[HANDOFF-PACKAGE]', item['path'], 'spec', item['specificationVersion'], 'program', item['programVersion'], flush=True)
    for profile in profiles:
        content = [r for r in rows(root / profile) if r['path'] != 'enumerated-production-export-receipt.json']
        assert tree(content) == inventory[profile]['payloadTreeSHA256']
        m = json.loads((root / profile / 'cosyvoice3_enumerated.json').read_text())
        for role in ['prefill', 'decode']:
            path = root / profile / m['llm' + role.capitalize()]
            assert tree(rows(path)) == inventory[profile][role + 'SHA256']
            model = next(x for x in metadata if x['path'] == path.relative_to(root).as_posix())
            assert model['rootABI']['stateCount'] == 48 and all(s['dtype'] == 'FLOAT16' for s in model['rootABI']['states'])
    for name, value in inventory['current']['P2'].items():
        assert tree(rows(root / 'FlowPartitions/p2' / name)) == value
    (args.output / 'COMPONENT_METADATA.json').write_text(json.dumps(dict(
        status='PASS_ACTUAL_REMOTE_PACKAGE_SPEC_PROGRAM_IO_STATE_METADATA', models=metadata,
        minimumLLMDeployment='iOS18/CoreML8 as pinned converter target and unchanged spec9',
        humanStatus='Exact approved output equivalence; distinct historical approvals and new physical output receipts retained'), indent=2) + '\n')
    verification = dict(status='PASS_NEW_EMPTY_DIRECTORY_EXACT_REVISION_FULL_FILE_PACKAGE_PROFILE_P2_HASH_VERIFICATION',
                        repoId=upload['repoId'], revision=upload['revision'], remoteRoot=str(root.resolve()),
                        verificationDirectoryWasNew=True, forceDownload=True, localBuildOutputUsed=False,
                        verifiedFiles=len(actual), packageCount=len(metadata), profiles=profiles,
                        collectionTreeSha256=upload['collectionTreeSha256'], fullQ4Included=False,
                        sourceScriptSHA256=sha(Path(__file__)), python=sys.version.split()[0], coremltools=ct.__version__)
    (args.output / 'HF_REMOTE_VERIFICATION.json').write_text(json.dumps(verification, indent=2) + '\n')
    print('[HANDOFF-CLOSURE]', json.dumps(verification), flush=True)


if __name__ == '__main__':
    main()
# Purpose: fresh immutable preservation and complete actual metadata audit. Upstream existing frozen rebuild receipts and HF file inventory; never reconverts or uploads models.
# Environment: local macOS pinned Python3.11/coremltools9/huggingface_hub; generated2026-10-06 America/New_York. New audit file; previous reports/branches/models unchanged.
