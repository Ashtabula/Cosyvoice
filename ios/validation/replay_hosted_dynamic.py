# replay_hosted_dynamic.py
# Requirement: replay an already fetched immutable dynamic RC on a physical iPhone without conversion, upload, or a multi-GB app-bundle copy; preserve public default/reference and cold/warm receipts.
from pathlib import Path
import argparse, hashlib, json, subprocess, threading, time

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent

def run(command):
    print('[COSYVOICE3-HOSTED-REPLAY] RUN '+ ' '.join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True)

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(4*1024*1024), b''): h.update(block)
    return h.hexdigest()

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--asset-root', type=Path, required=True)
    p.add_argument('--device', required=True)
    p.add_argument('--reference-wav', type=Path, required=True)
    p.add_argument('--reference-transcript', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--team', required=True)
    p.add_argument('--catalog', type=Path, default=ROOT/'assets/releases.json')
    p.add_argument('--bundle', default='com.actacomes.cosyvoice3.hostedreplay')
    p.add_argument('--mode', choices=['dynamic', 'candidate'], default='dynamic')
    p.add_argument('--reuse-staging', action='store_true')
    p.add_argument('--timeout', type=int, default=1200)
    a = p.parse_args(); a.output.mkdir(parents=True, exist_ok=True)
    manifest_path = a.asset_root/'asset-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('profile') != 'ios-dynamic-n1-n479-reference' or manifest.get('assetVersion') != '0.2.0-rc1':
        raise RuntimeError('wrong immutable runtime profile/version')
    # The ordinary fetcher verifies every immutable payload file/tree; verify again
    # here so an arbitrary local tree cannot satisfy this physical replay path.
    import sys
    sys.path.insert(0, str(ROOT/'assets'))
    import fetch_assets
    catalog = json.loads(a.catalog.read_text())
    entry = fetch_assets.choose(catalog, manifest['profile'], manifest['assetVersion'])
    if entry.get('revision') != '8a1f25460a157f35fe79c42a79946c40a59da08e': raise RuntimeError('wrong catalog immutable revision')
    fetch_assets.validate_release(a.asset_root, entry)
    source = subprocess.check_output(['git','-C',str(REPO),'rev-parse','HEAD'],text=True).strip()
    marker = {'sourceCommit':source, 'immutableManifestSha256':digest(manifest_path),
              'repoId':'actacomes/CosyVoice-assets', 'revision':'8a1f25460a157f35fe79c42a79946c40a59da08e',
              'payloadTreeSha256':manifest['payloadTreeSha256'], 'testedRuntimeTreeSha256':manifest['testedRuntimeTreeSha256']}
    marker_path = a.output/'staging-complete.json'
    marker_path.write_text(json.dumps(marker, indent=2)+'\n')
    derived = ROOT/'.work/HostedReplayDerivedData'
    run(['xcodebuild','-project',ROOT/'validation/DeviceSmoke/CosyVoice3DeviceSmoke.xcodeproj',
         '-scheme','CosyVoice3DeviceSmoke','-configuration','Release','-destination','id='+a.device,
         '-derivedDataPath',derived,'SYMROOT='+str(derived/'Build/Products'),
         'OBJROOT='+str(derived/'Build/Intermediates.noindex'), 'DEVELOPMENT_TEAM='+a.team,
         'PRODUCT_BUNDLE_IDENTIFIER='+a.bundle,'-allowProvisioningUpdates','build'])
    app = derived/'Build/Products/Release-iphoneos/CosyVoice3DeviceSmoke.app'
    run(['xcrun','devicectl','device','install','app','--device',a.device,app])
    copy = ['xcrun','devicectl','device','copy']
    domain = ['--device',a.device,'--domain-type','appDataContainer','--domain-identifier',a.bundle]
    if not a.reuse_staging:
        run(copy+['to',*domain,'--source',a.asset_root.resolve(),'--destination','Documents/GeneratedAssets/Runtime'])
    for path, name in [(a.reference_wav,'reference.wav'), (a.reference_transcript,'reference.txt'),
                       (marker_path,'dynamic-public-api-smoke-mode.json'), (marker_path,'staging-complete.json')]:
        run(copy+['to',*domain,'--source',path.resolve(),'--destination','Documents/GeneratedAssets/'+name])
    filename = 'dynamic-public-api-smoke-receipt.json' if a.mode=='dynamic' else 'candidate-benchmark-receipt.json'
    start = time.time()
    cmd = ['xcrun','devicectl','device','process','launch','--device',a.device,'--terminate-existing','--console',a.bundle]
    if a.mode=='candidate': cmd += ['--','--candidate-benchmark']
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    def forward():
        with (a.output/'console.log').open('w') as f:
            for line in process.stdout:
                print(line,end='',flush=True); f.write(line); f.flush()
    threading.Thread(target=forward,daemon=True).start()
    receipt_path = a.output/filename
    while time.time()-start < a.timeout:
        time.sleep(10)
        try:
            run(copy+['from',*domain,'--source','Documents/'+filename,'--destination',receipt_path])
            receipt = json.loads(receipt_path.read_text())
            if receipt.get('recordedAtUnix',0) < start-1: continue
            print('[COSYVOICE3-HOSTED-REPLAY] phase='+str(receipt.get('phase',receipt.get('status'))),flush=True)
            if receipt.get('status')=='RUNNING': continue
            binding = {**marker, 'physicalReceiptSha256':digest(receipt_path), 'mode':a.mode,
                       'referenceWavSha256':digest(a.reference_wav),
                       'referenceTranscriptSha256':digest(a.reference_transcript),
                       'recordedAtUnix':int(time.time()), 'status':receipt.get('status')}
            (a.output/'immutable-replay-binding.json').write_text(json.dumps(binding,indent=2)+'\n')
            if not str(receipt.get('status','')).startswith('PASS_'): raise RuntimeError(str(receipt))
            names = ['dynamic-default.wav','dynamic-reference.wav'] if a.mode=='dynamic' else []
            for name in names: run(copy+['from',*domain,'--source','Documents/'+name,'--destination',a.output/name])
            print('[COSYVOICE3-HOSTED-REPLAY] PASS '+str(receipt_path),flush=True)
            return
        except subprocess.CalledProcessError as error:
            print('[COSYVOICE3-HOSTED-REPLAY] receipt unavailable: '+str(error),flush=True)
        if process.poll() is not None: raise RuntimeError('physical process ended before final receipt; see console.log')
    raise RuntimeError('physical replay timeout; preserve console and intermediate receipt')

if __name__=='__main__': main()
# Purpose: exact immutable asset validation, receipt-last external staging and physical public API replay.
# Upstream: assets/fetch_assets.py and existing DeviceSmoke public API paths; upstream purpose: immutable acquisition and actual synthesis evidence.
# Environment: project-local Python, macOS Apple Silicon, Xcode, signed physical iPhone; generated 2026-10-04 America/New_York.
# Changes: new bounded hosted-replay entry; no historical conversion prerequisite, replacement upload or production parameter override.
