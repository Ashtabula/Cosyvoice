# cleanup_verified_duplicates.py
# User request: reclaim obsolete history storage; remove only large byte-identical copies with a retained canonical file.
from pathlib import Path
import hashlib
import json
import os
import subprocess

REPOSITORY = Path('/Volumes/WD/Codes/Cosyvoice')
EVIDENCE = REPOSITORY / 'ios/validation/evidence/storage_cleanup_20261006'
FIXED = REPOSITORY / 'ios/.work/hf-release/ios-fixed225-reference/0.1.0-rc1'
DYNAMIC = REPOSITORY / 'ios/.work/hf-release/ios-dynamic-n1-n479-reference/0.2.0-rc1'
FROZEN = REPOSITORY / 'ios/.work/enumerated-n1-n450/generated-ac31e117938ed50132365973a103cc8425942700'
FIXED_COPIES = [
    'ios/.work/candidate/fetched-runtime',
    'ios/.work/production-clean-room/fetched-runtime',
    'ios/.work/runtime-performance/fetched-runtime',
    'ios/validation/ProductionCleanRoom/GeneratedAssets/Runtime',
    'ios/.work/rebuilt-runtime/ios-fixed225-reference',
    'ios/.work/device-runtime',
    'ios/.work/hf-download-replay/0.1.0-rc1/ios-fixed225-reference/0.1.0-rc1',
    'ios/.work/hf-fetch-replay/0.1.0-rc1',
]
DYNAMIC_COPIES = [
    'ios/.work/hf-download-replay/ios-dynamic-n1-n479-reference-0.2.0-rc1/ios-dynamic-n1-n479-reference/0.2.0-rc1',
    'ios/.work/hf-fetch-replay/ios-dynamic-n1-n479-reference-0.2.0-rc1',
    'ios/.work/enumerated-n1-n450/shared-dynamic-rc',
    'ios/.work/ane-optimization/preserved-original-bundled-GeneratedAssets/Runtime',
]
READBACK_COPIES = [
    '/private/tmp/cosy-multibucket-audit-20261005/Runtime',
    '/private/tmp/cosy-persistent-runtime-readback-20261005',
]


def signature(path):
    s = path.stat()
    return (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as handle:
        while chunk := handle.read(8 * 1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def main():
    rows = []
    canonical_hashes = {}
    mappings = [(REPOSITORY / p, FIXED) for p in FIXED_COPIES]
    mappings += [(REPOSITORY / p, DYNAMIC) for p in DYNAMIC_COPIES]
    mappings += [(Path(p), FROZEN) for p in READBACK_COPIES]
    assert all(p != c and not p.is_relative_to(c) and not c.is_relative_to(p) for p, c in mappings)
    tracked = set(subprocess.check_output(['git', 'ls-files'], cwd=REPOSITORY, text=True).splitlines())
    for obsolete, canonical in mappings:
        assert not obsolete.is_symlink() and not canonical.is_symlink()
        assert canonical.is_dir()
        print('[ROOT_BEGIN]', obsolete, 'retained canonical', canonical, flush=True)
        for p in sorted(obsolete.rglob('*')):
            if p.is_symlink() or not p.is_file() or p.stat().st_size < 1024 * 1024:
                continue
            assert str(p.relative_to(REPOSITORY)) not in tracked if p.is_relative_to(REPOSITORY) else True
            reference = canonical / p.relative_to(obsolete)
            row = dict(path=str(p), logicalBytes=p.stat().st_size, allocatedBytes=p.stat().st_blocks * 512,
                       retainedCanonical=str(reference))
            if not reference.is_file() or reference.is_symlink() or reference.stat().st_size != p.stat().st_size:
                row['status'] = 'UNMATCHED_RETAINED'
            elif os.path.samefile(p, reference):
                row['status'] = 'ALREADY_SHARED_RETAINED'
            else:
                before = signature(p)
                reference_before = signature(reference)
                reference_key = (str(reference), reference_before)
                if reference_key not in canonical_hashes:
                    canonical_hashes[reference_key] = sha256(reference)
                row['sha256'] = sha256(p)
                row['retainedCanonicalSHA256'] = canonical_hashes[reference_key]
                if row['sha256'] != row['retainedCanonicalSHA256']:
                    row['status'] = 'DIFFERENT_BYTES_RETAINED'
                else:
                    assert signature(p) == before and signature(reference) == reference_before
                    row['status'] = 'VERIFIED_FOR_DELETION'
                    # Persist proof BEFORE unlink, so interruption cannot erase the audit trail.
                    rows.append(row)
                    (EVIDENCE / 'duplicate_deletion_receipt.json').write_text(json.dumps(rows, indent=2) + '\n')
                    p.unlink()
                    row['status'] = 'DELETED_IDENTICAL_OBSOLETE_COPY'
                    print('[DUPLICATE_DELETED]', p, row['logicalBytes'], row['sha256'], flush=True)
                    (EVIDENCE / 'duplicate_deletion_receipt.json').write_text(json.dumps(rows, indent=2) + '\n')
                    continue
            rows.append(row)
        (EVIDENCE / 'duplicate_deletion_receipt.json').write_text(json.dumps(rows, indent=2) + '\n')
        print('[ROOT_DONE]', obsolete, 'deleted total bytes', sum(r['logicalBytes'] for r in rows if r['status'].startswith('DELETED')), flush=True)
    print('[COMPLETE]', 'rows', len(rows), 'deleted', sum(r['status'].startswith('DELETED') for r in rows), flush=True)


if __name__ == '__main__':
    main()
# Purpose: remove obsolete duplicate payloads while preserving canonical bytes, all small receipts/specs and unique files.
# Upstream frozen schema3 + retained legacy release packages; Python3/macOS; generated2026-10-06 America/New_York.
# New housekeeping script. Historical copy roots become incomplete; receipt maps each removed path to exact retained SHA for restoration.
