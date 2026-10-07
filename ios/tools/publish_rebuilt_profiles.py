# publish_rebuilt_profiles.py
# Requirement: publish only the three newly revalidated profiles after explicit gate receipts, with fresh immutable HF identity and independent redownload verification.
import argparse
import hashlib
import json
import re
from pathlib import Path
from huggingface_hub import HfApi, snapshot_download


def rows(root):
    result = []
    for p in sorted(root.rglob('*')):
        if not p.is_file():
            continue
        digest = hashlib.sha256()
        with p.open('rb') as handle:
            for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b''):
                digest.update(chunk)
        result.append(dict(path=p.relative_to(root).as_posix(), bytes=p.stat().st_size, sha256=digest.hexdigest()))
    return result


def tree(items):
    digest = hashlib.sha256()
    for row in sorted(items, key=lambda r: r['path']):
        digest.update((row['path'] + '\0' + str(row['bytes']) + '\0' + row['sha256'] + '\n').encode())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--collection', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--gates', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', default='0.3.1-rc1')
    parser.add_argument('--upload', action='store_true')
    args = parser.parse_args()
    assert re.fullmatch(r'[0-9A-Za-z][0-9A-Za-z._-]*', args.version)
    inventory = json.loads(args.inventory.read_text())
    gates = json.loads(args.gates.read_text())
    profiles = ['current', 'q8', 'hybrid_q4']
    required = ['provenance', 'environment', 'conversion', 'host', 'physical', 'deterministic',
                'memory', 'performance', 'aneTopology', 'humanEquivalence', 'failClosed', 'swiftTests', 'signedRelease']
    for profile in profiles:
        for gate in required:
            entry = gates['profiles'][profile][gate]
            assert entry['status'] == 'PASS', f'{profile}/{gate}: publication blocked'
            evidence = Path(entry['path'])
            assert evidence.is_file() and hashlib.sha256(evidence.read_bytes()).hexdigest() == entry['sha256']
        physical = json.loads(Path(gates['profiles'][profile]['physical']['path']).read_text())
        assert physical['status'] == 'PASS_OBJECTIVE_SCREEN_PENDING_HUMAN'
        assert physical['SHARDS'] == 2 and physical['flowSteps'] == 6 and len(physical['rows']) == 5
        assert physical['payloadTreeSHA256'] == inventory[profile]['payloadTreeSHA256']
        assert len({r['PCM_SHA256'] for r in physical['rows']}) == 1
        assert len({r['tokenSequenceSHA256'] for r in physical['rows']}) == 1
        human = json.loads(Path(gates['profiles'][profile]['humanEquivalence']['path']).read_text())
        assert human['status'].startswith('PASS_REBUILT_')
        topology = json.loads(Path(gates['profiles'][profile]['aneTopology']['path']).read_text())
        assert topology['status'] == 'PASS_FRESH_HASH_PID_STAGE_BOUND_ANE_TOPOLOGY'
        assert topology['profile'] == profile and not topology['historicalTraceReused']
        actual = [r for r in rows(args.collection / profile) if r['path'] != 'enumerated-production-export-receipt.json']
        assert actual == inventory[profile]['allFiles'], f'{profile}: file inventory mismatch'
        assert tree(actual) == inventory[profile]['payloadTreeSHA256']
        manifest = json.loads((args.collection / profile / 'cosyvoice3_enumerated.json').read_text())
        for role in ['prefill', 'decode']:
            assert tree(rows(args.collection / profile / manifest['llm' + role.capitalize()])) == inventory[profile][role + 'SHA256']
    assert set(p.name for p in args.collection.iterdir()) <= set(profiles + ['FlowPartitions', 'hf-profile-collection-manifest.json'])
    for p in args.collection.rglob('*'):
        assert not any(x in p.name.lower() for x in ['q4-prefill', 'block32', 'q4_full', '.trace', '.wav'])
    for name, sha in inventory['current']['P2'].items():
        assert tree(rows(args.collection / 'FlowPartitions/p2' / name)) == sha
    content = [r for r in rows(args.collection) if r['path'] != 'hf-profile-collection-manifest.json']
    manifest = dict(schemaVersion=2, engine='CosyVoice3', profileCollection='ios-weight-profiles-current-q8-q4hybrid',
                    assetVersion=args.version, acousticShards=2, flowSteps=6, fullQ4PrefillIncluded=False,
                    collectionTreeSha256=tree(content), collectionBytes=sum(r['bytes'] for r in content),
                    profiles=[{k:inventory[p][k] for k in ['profileID', 'displayName', 'compression', 'stateBridgeMode', 'manifestSHA256', 'payloadTreeSHA256', 'prefillSHA256', 'decodeSHA256', 'P2', 'payloadBytes', 'human', 'acousticShards', 'flowSteps']} for p in profiles],
                    validatedCosySourceCommit=gates['physicalSourceCommit'], distributionStatus='PRIVATE_RC',
                    publicRedistributionApproved=False, fileInventory=content,
                    gateReceiptSHA256=hashlib.sha256(args.gates.read_bytes()).hexdigest())
    manifest_path = args.collection / 'hf-profile-collection-manifest.json'
    if manifest_path.exists():
        assert json.loads(manifest_path.read_text()) == manifest, 'existing freeze differs'
    else:
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    args.output.mkdir(parents=True, exist_ok=True)
    expected = rows(args.collection)
    (args.output / 'upload-inventory.json').write_text(json.dumps(expected, indent=2) + '\n')
    print('[REBUILD-HF] all required gates and actual bytes PASS', flush=True)
    if not args.upload:
        return
    api = HfApi()
    repo = 'actacomes/CosyVoice-assets'
    assert api.whoami()['name'] == 'actacomes'
    info = api.repo_info(repo)
    assert info.private is True
    prefix = f'ios-weight-profiles-current-q8-q4hybrid/{args.version}'
    assert not any(p.startswith(prefix + '/') for p in api.list_repo_files(repo)), 'immutable destination already exists'
    commit = api.upload_folder(repo_id=repo, folder_path=str(args.collection), path_in_repo=prefix,
                               commit_message=f'publish rebuilt revalidated three profiles {args.version}')
    assert re.fullmatch('[0-9a-f]{40}', commit.oid)
    receipt = dict(status='UPLOADED_REMOTE_VERIFICATION_PENDING', repoId=repo, revision=commit.oid,
                   pathInRepo=prefix, version=args.version, collectionTreeSha256=manifest['collectionTreeSha256'])
    receipt_path = args.output / 'hf-upload-receipt.json'
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    tag = f'ios-weight-profiles-current-q8-q4hybrid-v{args.version}'
    api.create_tag(repo, tag=tag, revision=commit.oid, exist_ok=False)
    receipt['tag'] = tag
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    remote = args.output / 'clean-redownload'
    assert not remote.exists(), 'verification must use a fresh destination'
    snapshot_download(repo, revision=commit.oid, allow_patterns=[prefix + '/**'], local_dir=remote,
                      cache_dir=args.output / 'fresh-hf-cache', force_download=True)
    downloaded = remote / prefix
    actual = rows(downloaded)
    assert actual == expected, 'remote file inventory differs'
    receipt['status'] = 'PASS_UPLOADED_IMMUTABLE_CLEAN_REDOWNLOAD_HASH_VERIFIED'
    receipt['remoteRoot'] = str(downloaded.resolve())
    receipt['verifiedFiles'] = len(actual)
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    (args.output / 'HF_REMOTE_VERIFICATION.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('[REBUILD-HF]', json.dumps(receipt), flush=True)


if __name__ == '__main__':
    main()
# Purpose: strict new candidate publication and actual remote preservation proof. Upstream historical private HF publisher and SDK content-tree convention.
# Environment: local macOS Python3.11/huggingface_hub0.36.2; generated2026-10-06 America/New_York. New file; old immutable contracts unchanged.
