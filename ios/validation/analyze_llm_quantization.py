# analyze_llm_quantization.py
# Requirement: measured physical memory/timing/token comparison, no inferred whole-device energy or human quality PASS.
import argparse,hashlib,json,statistics
from pathlib import Path

def summarize(path):
 r=json.loads(path.read_text());timeline=r['memoryThermalCPUCounterTimeline'];result={'variant':r['variant'],'sourceCommit':r['sourceCommit'],'RuntimeRoot':r['RuntimeRoot'],'manifestSHA256':r['manifestSHA256'],'payloadTreeSHA256':r['payloadTreeSHA256'],'conditions':r['environmentStart'],'WAV_SHA256':r['WAV_SHA256'],'rows':[],'boundarySamples':[x for x in timeline if x['boundary'] and x['stage'] in ['before_engine_creation','after_engine_creation','post_completion_idle_1s','post_completion_idle_3s','post_completion_idle_10s','post_completion_idle_35s']],'overallSampledPeakBytes':max(x['physicalFootprintBytes'] for x in timeline)}
 audits=r['persistentRuntime']['validationWarmPassRecords']
 for i,row in enumerate(r['rows']):
  start=next(x['uptimeNanoseconds'] for x in timeline if x['stage']==f'request_{i+1}_begin');end=next(x['uptimeNanoseconds'] for x in timeline if x['stage']==f'request_{i+1}_completion');window=[x for x in timeline if start<=x['uptimeNanoseconds']<=end];audit=audits[i]['audit'];predictions=audit['predictionRows'];latencies=[x['wallMilliseconds'] for x in predictions] if predictions and 'wallMilliseconds' in predictions[0] else []
  entry={'request':i+1,'thermalStart':row['thermalStart'],'thermalEnd':row['thermalEnd'],'N':row['N'],'function':row['function'],'totalMs':row['stageTimings']['totalMilliseconds'],'outerPublicMs':row['totalMilliseconds'],'RTF':row['stageTimings']['totalMilliseconds']/(row['audioSeconds']*1000),'llmLoadMs':row['stageTimings']['llmModelLoadMilliseconds'],'LLMms':row['stageTimings']['llmGenerationMilliseconds'],'acousticMs':row['stageTimings']['acousticSynthesisMilliseconds'],'CPUms':row['cpuMilliseconds'],'CPUOnlyEnergyPerAudioSecondMJ':row['CPUOnlyEnergyPerPlaybackSecondMillijoules'],'prefillMs':audit['milliseconds'].get('llm.prefill.prediction'),'decodeTotalMs':audit['milliseconds'].get('llm.decode.prediction'),'decodeCalls':audit['calls'].get('llm.decode.prediction'),'sampledPeakBytes':max(x['physicalFootprintBytes'] for x in window),'PCM_SHA256':row['PCM_SHA256'],'tokenSequenceSHA256':row['tokenSequenceSHA256'],'termination':audit['termination'],'memoryStages':{}}
  if entry['decodeCalls']:entry['decodeMeanMs']=entry['decodeTotalMs']/entry['decodeCalls']
  for stage,a,b in [('LLM','llm.load.begin','llm.generate.end:'),('generation','llm.generate.begin:','llm.generate.end:'),('prefill','llm.prefill.begin','llm.prefill.end'),('acoustic','acoustic.conditions.begin:','synthesis.end')]:
   begins=[x for x in window if x['boundary'] and x['stage'].startswith(a)];ends=[x for x in window if x['boundary'] and x['stage'].startswith(b)]
   if begins and ends:
    first,last=begins[0],ends[-1];samples=[x for x in window if first['uptimeNanoseconds']<=x['uptimeNanoseconds']<=last['uptimeNanoseconds']];entry['memoryStages'][stage]={'beforeBytes':first['physicalFootprintBytes'],'peakBytes':max(x['physicalFootprintBytes'] for x in samples),'afterBytes':last['physicalFootprintBytes']}
  entry['predictionRows']=predictions;result['rows'].append(entry)
 warm=[x for x in result['rows'][2:] if x['thermalStart']==x['thermalEnd']=='nominal'];result['warmNominalCount']=len(warm);result['warmMedian']={key:statistics.median(x[key] for x in warm) for key in ['totalMs','RTF','llmLoadMs','LLMms','acousticMs','CPUms','CPUOnlyEnergyPerAudioSecondMJ','prefillMs','decodeTotalMs','decodeMeanMs','sampledPeakBytes']};result['warmRanges']={key:[min(x[key] for x in warm),max(x[key] for x in warm)] for key in result['warmMedian']};result['post35sFootprintBytes']=next(x['physicalFootprintBytes'] for x in reversed(timeline) if x['stage']=='post_completion_idle_35s');result['wholeDeviceEnergyPerAudioSecond']=None;return result

def main():
 p=argparse.ArgumentParser();p.add_argument('--baseline',type=Path,required=True);p.add_argument('--q8',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();b=summarize(a.baseline);q=summarize(a.q8);br=json.loads(a.baseline.read_text());qr=json.loads(a.q8.read_text());bt=br['rows'][0]['tokens'];qt=qr['rows'][0]['tokens'];diff=[i for i,(x,y) in enumerate(zip(bt,qt)) if x!=y]
 def repetition(tokens):
  run=best=1
  for i in range(1,len(tokens)):
   run=run+1 if tokens[i]==tokens[i-1] else 1;best=max(best,run)
  return {'adjacentEqualFraction':sum(tokens[i]==tokens[i-1] for i in range(1,len(tokens)))/max(1,len(tokens)-1),'longestIdenticalTokenRun':best,'meaning':'speechcode tokenstatistic, NOT word/phrase repetition or intelligibility'}
 r={'baseline':b,'Q8':q,'tokenDivergence':{'exactMatch':bt==qt,'firstIndexZeroBased':diff[0] if diff else None,'positionalMismatchCount':len(diff),'positionalMismatchFraction':len(diff)/max(len(bt),len(qt)),'lengthDifference':len(qt)-len(bt),'baseline':repetition(bt),'Q8':repetition(qt),'durationRatio':qr['rows'][0]['audioSeconds']/br['rows'][0]['audioSeconds']},'sampledPeakReductionBytes':b['warmMedian']['sampledPeakBytes']-q['warmMedian']['sampledPeakBytes'],'sampledPeakReductionFraction':1-q['warmMedian']['sampledPeakBytes']/b['warmMedian']['sampledPeakBytes'],'humanListening':'PENDING_HUMAN','classification':'Q8_AWAITING_HUMAN_LISTENING','meaning':'physicalmemory/runtime benefitsdo notestablishwholedeviceenergy/thermal/audiblequality; 100ms sampledpeaknotexactinstantaneousmax'};a.output.write_text(json.dumps(r,indent=2)+'\n');print(json.dumps({k:v for k,v in r.items() if k not in ['baseline','Q8']},indent=2));print('baselinewarm',b['warmMedian']);print('Q8warm',q['warmMedian'])
if __name__=='__main__':main()
# Purpose: controlledinputprovenance/rawnominalselection, transparentNAenergy and tokenstats; no autoqualitypromotion.
# Upstream publicphysicalQ8 receipts, Python3, generated2026-10-06 America/New_York.
