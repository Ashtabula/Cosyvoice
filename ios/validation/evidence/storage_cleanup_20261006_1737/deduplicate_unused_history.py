# deduplicate_unused_history.py
# Requirement: release storage from unused historical model-weight duplicates without losing any model/evidence, plus explicit obsolete build caches.
import argparse,collections,hashlib,json,os,shutil,stat,time
from pathlib import Path
ROOT=Path('/Volumes/WD/Codes/Cosyvoice');EVIDENCE=ROOT/'ios/validation/evidence/storage_cleanup_20261006_1737'
ELIGIBLE=[ROOT/'ios/.work/dynamic-acoustic',ROOT/'ios/.work/enumerated-n1-n450/generated-108651803461ed76c4f5f226f87349754a3150c9',ROOT/'ios/.work/enumerated-n1-n450/generated-ec5630ecac20ca51416f542fb3ab43374eb8e422',ROOT/'ios/.work/rebuild/ios-fixed225-reference/source/iOS/converted']
ELIGIBLE += [p for pattern in ['cosy-ane-single*','cosy-ane-static-*','cosy-flow-partition-single-*'] for p in Path('/private/tmp').glob(pattern) if p.is_dir()]
CACHES=[ROOT/'ios/.work'/x for x in ['RuntimePerformanceDerivedData','FlowStepsHeadToHeadDerivedData','DeviceSmokeDerivedData','CandidateBenchmarkDerivedData','ProductionCleanRoomDerivedData']]
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for chunk in iter(lambda:f.read(8*1024*1024),b''):h.update(chunk)
 return h.hexdigest()
def free():return {str(p):shutil.disk_usage(p).free for p in [ROOT,Path('/private/tmp')]}
def main():
 a=argparse.ArgumentParser();a.add_argument('--apply',action='store_true');a=a.parse_args();EVIDENCE.mkdir(parents=True,exist_ok=True)
 if not a.apply:
  groups=collections.defaultdict(list);seen=set()
  for root in ELIGIBLE:
   if not root.exists():continue
   for p in root.rglob('weight.bin'):
    if not any(x.endswith('.mlpackage') for x in p.parts):continue
    if p.is_symlink():continue
    st=p.stat();key=(st.st_dev,st.st_ino)
    if st.st_size<8*1024*1024 or st.st_nlink!=1 or key in seen:continue
    seen.add(key);groups[(st.st_dev,st.st_size)].append(p)
  candidates={k:v for k,v in groups.items() if len(v)>1};total=sum(k[1]*len(v) for k,v in candidates.items());print('[HISTORY-CLEANUP] hashing candidates',sum(map(len,candidates.values())),'bytes',total,flush=True)
  duplicates=[];done=0;last=time.monotonic()
  for (dev,size),paths in candidates.items():
   hashes=collections.defaultdict(list)
   for p in paths:
    h=sha(p);hashes[h].append(p);done+=size
    if time.monotonic()-last>15:print('[HISTORY-CLEANUP] hashed',done,'/',total,flush=True);last=time.monotonic()
   for h,equal in hashes.items():
    if len(equal)>1:duplicates.append({'device':dev,'bytes':size,'sha256':h,'canonical':str(equal[0]),'replaceWithReadOnlyHardlink':[str(p) for p in equal[1:]]})
  plan={'status':'HASH_VERIFIED_PLAN','freeBefore':free(),'eligibleHistoryRoots':[str(x) for x in ELIGIBLE],'protected':'allCurrent/Q8/originalQ4/rescueA/hybrid/LLMsource/reference/receipts/WAVs/traces/currentlengthwork/activebuild/VoxCPM2 excluded','groups':duplicates,'reclaimableLogicalBytes':sum(x['bytes']*len(x['replaceWithReadOnlyHardlink']) for x in duplicates),'obsoleteBuildCaches':[str(x) for x in CACHES if x.exists()]};(EVIDENCE/'plan.json').write_text(json.dumps(plan,indent=2)+'\n');print('[HISTORY-CLEANUP] verifiedgroups',len(duplicates),'reclaimablelogical',plan['reclaimableLogicalBytes'],flush=True);return
 plan=json.loads((EVIDENCE/'plan.json').read_text());before=free();events=[]
 def save(): (EVIDENCE/'deduplication_receipt.json').write_text(json.dumps({'status':'APPLYING','freeBefore':before,'events':events},indent=2)+'\n')
 for group in plan['groups']:
  canonical=Path(group['canonical']);assert not canonical.is_symlink();assert any(canonical.resolve().is_relative_to(r.resolve()) for r in ELIGIBLE);assert sha(canonical)==group['sha256'];os.chmod(canonical,stat.S_IMODE(canonical.stat().st_mode)&~0o222)
  for name in group['replaceWithReadOnlyHardlink']:
   target=Path(name);assert not target.is_symlink();assert any(target.resolve().is_relative_to(r.resolve()) for r in ELIGIBLE);st=target.stat();assert st.st_dev==canonical.stat().st_dev and st.st_nlink==1 and st.st_size==group['bytes'];assert sha(target)==group['sha256']
   temporary=target.with_name(target.name+'.cleanup-link');assert not temporary.exists();os.link(canonical,temporary);os.replace(temporary,target)
   assert target.stat().st_ino==canonical.stat().st_ino;events.append({'path':name,'canonical':str(canonical),'sha256':group['sha256'],'bytes':group['bytes'],'action':'replacedexactduplicatewithreadonlyhardlink','allModelFilesPreserved':True});save()
  print('[HISTORY-CLEANUP] groupcomplete',len(group['replaceWithReadOnlyHardlink']),group['bytes'],flush=True)
 caches=[]
 for name in plan['obsoleteBuildCaches']:
  p=Path(name);assert p in CACHES
  if p.exists():shutil.rmtree(p);caches.append({'path':name,'action':'removedobsoleteRebuildableDerivedData','currentBuildPreserved':True})
 after=free();result={'status':'CLEANUP_COMPLETE','freeBefore':before,'freeAfter':after,'freedBytes':{k:after[k]-before[k] for k in before},'duplicateFilesDeduplicated':len(events),'logicalDuplicateBytesRemoved':sum(x['bytes'] for x in events),'obsoleteBuildCachesDeleted':caches,'modelPackagesEvidenceAudioTracesPreserved':True,'unrelatedVoxWorkUntouched':True};(EVIDENCE/'result.json').write_text(json.dumps(result,indent=2)+'\n');(EVIDENCE/'deduplication_receipt.json').write_text(json.dumps({'status':'COMPLETE','events':events},indent=2)+'\n');print(json.dumps(result,indent=2),flush=True)
if __name__=='__main__':main()
# Purpose: exact-byte physical duplicate removal with complete historical package preservation; no loss of model/evidence/audio and no model math change.
# Upstream old dynamic/shape/single-function exports; current frozen/Q4/activeVox trees excluded. Python3/macOS/APFS,2026-10-06 America/New_York; new cleanup receipt tool.
