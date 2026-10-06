# run_llm_quantization_screen.py
# Requirement: paired frozen public physical screens and actual task-native WAV export, never quantized promotion.
import argparse,hashlib,json,subprocess,threading,time
from pathlib import Path
DEVICE='00008150-000A05CA1440401C';BUNDLE='com.actacomes.cosyvoice3.candidatebenchmark'
def main():
 p=argparse.ArgumentParser();p.add_argument('--variant',choices=['baseline','q8'],required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--artifacts',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True);a.artifacts.mkdir(parents=True,exist_ok=True)
 flags=['--no-playback','--validation-llm-quantization',f'--validation-llm-variant={a.variant}','--validation-warm-pass','--validation-execution-audit','--validation-flow-partition=2','--validation-acoustic-cache=selected-family']
 cmd=['xcrun','devicectl','device','process','launch','--device',DEVICE,'--terminate-existing','--console',BUNDLE,'--',*flags];proc=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1);done=threading.Event()
 def consume():
  with (a.output/'console.log').open('w') as f:
   for line in proc.stdout:
    print(line,end='',flush=True);f.write(line);f.flush()
    if '[COSY-AUTO-DONE]' in line:done.set()
 threading.Thread(target=consume,daemon=True).start();deadline=time.monotonic()+1200
 while not done.wait(30):
  print('[Q8-SCREEN] pending; no timed device readback',flush=True)
  if proc.poll() is not None or time.monotonic()>deadline:raise RuntimeError('screen incomplete; no fabricated receipt')
 def copy(name,dest):
  subprocess.run(['xcrun','devicectl','device','copy','from','--device',DEVICE,'--domain-type','appDataContainer','--domain-identifier',BUNDLE,'--source','Documents/'+name,'--destination',str(dest)],check=True)
 name=f'llm-quantization-{a.variant}-receipt.json';copy(name,a.output/name);r=json.loads((a.output/name).read_text())
 if r.get('status')!='PASS_OBJECTIVE_SCREEN_PENDING_HUMAN':raise RuntimeError('physicalscreenFAIL preserved '+json.dumps(r))
 assert r['SHARDS']==2 and r['flowSteps']==6 and r['variant']==a.variant
 wav=r['WAVFilename'];copy(wav,a.artifacts/wav);assert hashlib.sha256((a.artifacts/wav).read_bytes()).hexdigest()==r['WAV_SHA256']
 record={'command':cmd,'runnerSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'physicalSourceCommit':r['sourceCommit'],'sourceGitHEADAtCollection':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'artifactFilename':wav,'artifactAbsolutePath':str((a.artifacts/wav).resolve()),'WAV_SHA256':r['WAV_SHA256'],'taskArtifactMechanism':'Codex native Markdown audio embed withabsolute localfile, displayedfilename notfilesystemnavigation','humanListening':'PENDING_HUMAN','charging':'screeningonly','noTimedReadback':True};(a.output/'host-collection.json').write_text(json.dumps(record,indent=2)+'\n');print('[Q8-SCREEN] artifactready',wav,flush=True)
if __name__=='__main__':main()
# Purpose: readable/exported exact WAV withvisibleaudiofilename; actualaudioembeddingisdoneinfinalresponse, not claimedbyprintingpath.
# Upstream nativeDeviceSmokeQuantizationscreen; Python3/macOS/iPhone18,4; generated2026-10-06 America/New_York.
