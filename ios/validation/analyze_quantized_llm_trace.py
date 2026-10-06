# analyze_quantized_llm_trace.py
# Requirement: join native PID/stage signposts, CoreML activity, hardware inference names and actual persistent package identity; keep missing per-op assignment UNKNOWN.
from pathlib import Path
import argparse,collections,hashlib,json,re,xml.etree.ElementTree as ET

class Table:
    def __init__(self,path):
        self.path=path;self.root=ET.parse(path).getroot()
        self.ids={x.get('id'):x for x in self.root.iter() if x.get('id')}
        self.rows=self.root.findall('.//row')
    def node(self,x):
        while x is not None and x.get('ref'):x=self.ids.get(x.get('ref'))
        return x
    def text(self,x):
        x=self.node(x)
        return '' if x is None else x.get('fmt',x.text or '')
    def number(self,x):
        x=self.node(x)
        return int(x.text) if x is not None and x.text else 0
    def interval(self,row):
        start=self.number(row.find('start-time'));return start,start+self.number(row.find('duration'))

def main():
    p=argparse.ArgumentParser();p.add_argument('--prefix',type=Path,required=True);p.add_argument('--request',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();receipt=json.loads(a.request.read_text());pid=str(receipt['processID'])
    graphs=json.loads((Path('/Volumes/WD/Codes/Cosyvoice/ios/validation/evidence/enumerated_ane_graph_audit.json')).read_text())['models']
    role_by_sha={v['identity']['treeSha256']:role for role,v in graphs.items()}
    quant=json.loads(Path('/Volumes/WD/Codes/Cosyvoice/ios/validation/evidence/llm_quantization_20261006/q8/conversion_receipt.json').read_text())
    role_by_sha.update({v['outputIdentity']['treeSha256']:'llm'+role.capitalize() for role,v in quant['models'].items()})
    models={}
    records={r['key']:r for r in receipt['persistentRuntime']['records'] if 'compiledArtifact' in r}
    for event in receipt['persistentRuntime']['processLoadEvents']:
        record=records.get(event.get('key'))
        if not record:continue
        identity=record.get('identity',{});key=record['compiledArtifact'].removesuffix('.mlmodelc')
        role=role_by_sha.get(identity.get('modelPackageSHA256'),'diagnostic-or-partition')
        models[key]=dict(role=role,identity=identity,compiledArtifact=record['compiledArtifact'],actualProcessLoadEvent=event)
    # Generic compiled archives are shared across placements/hints. Only this PID's
    # actual load events may select an identity; old persistent records are not evidence.
    names=['OSSignpostIntervals','coreml-os-signpost','ane-hw-intervals']
    tables={name:Table(Path(str(a.prefix)+'-'+name+'.xml')) for name in names}
    stages=[]
    for row in tables[names[0]].rows:
        t=tables[names[0]]
        if t.text(row.find('signpost-name'))!='CosyStage' or '('+pid+')' not in t.text(row.find('process')):continue
        stage=t.text(row.find('os-log-metadata'));start,end=t.interval(row)
        stages.append(dict(stage=stage,startNanoseconds=start,endNanoseconds=end,wallMilliseconds=(end-start)/1e6))
    core=tables['coreml-os-signpost'];hardware=tables['ane-hw-intervals'];by_model=collections.defaultdict(list)
    for row in core.rows:
        name=core.text(row.find('coreml-model-name'));base=re.sub(r'-[0-9]+$','',name)
        if base not in models:continue
        start,end=core.interval(row)
        by_model[base].append(dict(event=core.text(row.find('coreml-model-event')),start=start,end=end,durationMilliseconds=(end-start)/1e6))
    ane=[]
    for row in hardware.rows:
        start,end=hardware.interval(row)
        ane.append(dict(label=hardware.text(row.find('formatted-label')),start=start,end=end,durationMilliseconds=(end-start)/1e6))
    output=dict(schemaVersion=1,status='MODEL_AND_STAGE_ACTIVITY_OBSERVED_PER_OP_ASSIGNMENT_UNAVAILABLE',
                sourceCommit=receipt['sourceCommit'],processID=receipt['processID'],requestReceiptSHA256=hashlib.sha256(a.request.read_bytes()).hexdigest(),
                stageIntervals=stages,models=[],actualResidency='UNKNOWN_RESIDENCY',
                meaning='Measured activity joins do not turn MLComputePlan preferred devices into actual per-operation residency.',
                limitations=['CoreAIProfile per-model/op table unavailable; legacy CoreML activities are coarse','Hardware ANE rows lack PID; assignment uses exact compiled artifact hash plus native prediction containment',
                             'CPU event duration is a partition/event interval, not individual fallback op latency','Trace timings excluded from unprofiled performance comparison'])
    for name,model in models.items():
        events=by_model.get(name,[])
        if not events:continue
        predictions=[x for x in events if x['event']=='Prediction']
        exact_ane=[x for x in ane if x['label'].startswith(name+'_') and 'Prediction' in x['label']]
        contained=sum(any(p['start']<=x['start'] and x['end']<=p['end'] for p in predictions) for x in exact_ane)
        counters=collections.Counter(x['event'] for x in events)
        totals={kind:sum(x['durationMilliseconds'] for x in events if x['event']==kind) for kind in counters}
        row=dict(model,compiledName=name,activityCounts=dict(counters),summedActivityMilliseconds=totals,
                 aneHardwarePredictionCount=len(exact_ane),anePredictionsContainedInCoreMLPrediction=contained,
                 aneHardwarePredictionMilliseconds=sum(x['durationMilliseconds'] for x in exact_ane),
                 perOperationActualDevices=None,actualResidency='UNKNOWN_RESIDENCY')
        row['stageOverlapCounts']={stage:sum(any(s['stage']==stage and s['startNanoseconds']<=x['start'] and x['end']<=s['endNanoseconds'] for s in stages) for x in predictions) for stage in sorted({s['stage'] for s in stages})}
        output['models'].append(row)
    output['rawEvidence']=[dict(path=str(t.path),sha256=hashlib.sha256(t.path.read_bytes()).hexdigest(),rowCount=len(t.rows)) for t in tables.values()]
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(output,indent=2)+'\n')
    for row in output['models']:print('[RESIDENCY-TRACE]',row['role'],row['compiledName'],row['activityCounts'],'ANE',row['aneHardwarePredictionCount'],row['stageOverlapCounts'],flush=True)

if __name__=='__main__':main()
# Purpose: reproducible physical profiling attribution without source-only claims. Upstream Instruments XML and signed app receipts; Python3.11/macOS, generated2026-10-05 America/New_York. New file; UNKNOWN retained when per-op actual devices absent.
