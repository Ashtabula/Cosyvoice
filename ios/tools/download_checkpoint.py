# download_checkpoint.py
# Requirement: download the exact official checkpoint and preserve revision, sizes and hashes.
import hashlib
import json
from pathlib import Path
from huggingface_hub import HfApi, snapshot_download

ROOT = Path(__file__).resolve().parents[2]
REPO = 'FunAudioLLM/Fun-CosyVoice3-0.5B-2512'
PROVENANCE = ROOT / 'ios/validation/provenance'
PROVENANCE.mkdir(parents=True, exist_ok=True)
lock = PROVENANCE / 'checkpoint-lock.json'
api = HfApi()
revision = json.loads(lock.read_text())['revision'] if lock.exists() else api.model_info(REPO).sha
info = api.model_info(REPO, revision=revision, files_metadata=True)
files = [{'path': f.rfilename, 'bytes': f.size, 'lfs_sha256': f.lfs.sha256 if f.lfs else None} for f in info.siblings]
lock.write_text(json.dumps({'repo': REPO, 'revision': info.sha, 'files': files}, indent=2) + '\n')
print('PINNED', info.sha, 'REMOTE_BYTES', sum(f['bytes'] or 0 for f in files), flush=True)
dest = ROOT / 'pretrained_models/Fun-CosyVoice3-0.5B-2512'
snapshot_download(REPO, revision=info.sha, local_dir=dest, max_workers=4)
for f in files:
    p = dest / f['path']
    h = hashlib.sha256()
    with p.open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            h.update(block)
    f['local_sha256'] = h.hexdigest()
    if p.stat().st_size != f['bytes']:
        raise RuntimeError('Size mismatch: ' + f['path'])
    if f['lfs_sha256'] and f['local_sha256'] != f['lfs_sha256']:
        raise RuntimeError('Hash mismatch: ' + f['path'])
    print('VERIFIED', f['path'], f['bytes'], f['local_sha256'], flush=True)
lock.write_text(json.dumps({'repo': REPO, 'revision': info.sha, 'files': files, 'download_verified': True}, indent=2) + '\n')
# Purpose: reproducible local checkpoint; upstream: HF official repository, supplying inference assets.
# Environment: .venv-upstream; generated 2026-09-29 America/New_York; new file, all lines added.
