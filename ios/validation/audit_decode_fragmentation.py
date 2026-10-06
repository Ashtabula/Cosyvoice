# audit_decode_fragmentation.py
# Requirement: audit existing physical FP16/Q8 decode intervals without changing assets or running inference.
import argparse
import csv
import hashlib
import json
import re
import statistics
from pathlib import Path

from analyze_quantized_llm_trace import Table


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def interval_metrics(start, end, intervals):
    """Union overlapping/nested records; exclude pre/post accelerator boundary time from internal gaps."""
    assert end > start
    ordered = sorted(intervals)
    assert all(start <= a < b <= end for a, b in ordered)
    merged = []
    for a, b in ordered:
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(b, merged[-1][1])
        else:
            merged.append([a, b])
    gaps = [b[0] - a[1] for a, b in zip(merged, merged[1:])]
    durations = [b - a for a, b in merged]
    wall = end - start
    total = sum(durations)
    longest = max(durations, default=0)
    return dict(aneIntervalCount=len(ordered), mergedANEIntervalCount=len(merged),
                totalANEIntervalMilliseconds=total / 1e6,
                longestANEIntervalMilliseconds=longest / 1e6,
                internalGapCount=len(gaps), internalGapMilliseconds=sum(gaps) / 1e6,
                maxInternalGapMilliseconds=max(gaps, default=0) / 1e6,
                predictionWallMilliseconds=wall / 1e6,
                aneIntervalCoverage=total / wall, contiguousANEFraction=longest / wall,
                fragmentationRatio=sum(gaps) / wall,
                preANEBoundaryMilliseconds=(merged[0][0] - start) / 1e6 if merged else None,
                postANEBoundaryMilliseconds=(end - merged[-1][1]) / 1e6 if merged else None)


def summary(rows):
    keys = list(interval_metrics(0, 10, [(2, 8)]))
    result = dict(count=len(rows))
    for key in keys:
        values = [r[key] for r in rows if r[key] is not None]
        result[key] = dict(min=min(values), median=statistics.median(values),
                           mean=statistics.mean(values), max=max(values)) if values else None
    return result


def audit(attribution_path, receipt_path, output, variant, diagnostics_path=None):
    attribution = json.loads(Path(attribution_path).read_text())
    receipt = json.loads(Path(receipt_path).read_text())
    assert attribution['sourceCommit'] == receipt['sourceCommit']
    assert attribution['processID'] == receipt['processID']
    assert attribution['requestReceiptSHA256'] == digest(receipt_path)
    assert receipt['SHARDS'] == 2 and receipt['flowSteps'] == 6
    model = next(m for m in attribution['models'] if m['role'] == 'llmDecode')
    compiled = model['compiledName']
    tables = {}
    for binding in attribution['rawEvidence']:
        path = Path(binding['path'])
        assert digest(path) == binding['sha256'], str(path)
        tables[path.name] = Table(path)
    core = next(t for name, t in tables.items() if name.endswith('coreml-os-signpost.xml'))
    hardware = next(t for name, t in tables.items() if name.endswith('ane-hw-intervals.xml'))
    stages = sorted((s for s in attribution['stageIntervals'] if s['stage'] == 'llm.decode.prediction'),
                    key=lambda s: s['startNanoseconds'])
    predictions, backend, ane = [], [], []
    for row in core.rows:
        name = re.sub(r'-[0-9]+$', '', core.text(row.find('coreml-model-name')))
        if name != compiled:
            continue
        a, b = core.interval(row)
        event = core.text(row.find('coreml-model-event'))
        record = dict(start=a, end=b, event=event)
        if event == 'Prediction':
            predictions.append(record)
        elif event in ('CPU', 'GPU Request', 'Prepare GPU Request'):
            backend.append(record)
    for row in hardware.rows:
        label = hardware.text(row.find('formatted-label'))
        if label.startswith(compiled + '_') and label.endswith(' Prediction'):
            a, b = hardware.interval(row)
            ane.append(dict(start=a, end=b, label=label))
    predictions.sort(key=lambda x: x['start'])
    assert len(predictions) == len(stages) == 5 * 259
    assert all(a['end'] <= b['start'] for a, b in zip(predictions, predictions[1:]))
    diagnostics = json.loads(Path(diagnostics_path).read_text()) if diagnostics_path else []
    if diagnostics:
        assert len(diagnostics) == len(predictions)
    rows = []
    used = set()
    for i, (prediction, stage) in enumerate(zip(predictions, stages)):
        start, end = prediction['start'], prediction['end']
        assert stage['startNanoseconds'] <= start < end <= stage['endNanoseconds']
        matched = [(j, event) for j, event in enumerate(ane)
                   if start <= event['start'] and event['end'] <= end]
        intersecting = [event for event in ane if event['start'] < end and start < event['end']]
        assert len(intersecting) == len(matched), 'cross-boundary ANE event'
        assert not used.intersection(j for j, _ in matched)
        used.update(j for j, _ in matched)
        request, index = i // 259 + 1, i % 259 + 1
        physical_row = receipt['rows'][request - 1]
        diagnostic = diagnostics[i] if diagnostics else None
        if diagnostic:
            assert diagnostic['request'] == request and diagnostic['index'] == index
        row = dict(request=request, predictionIndex=index,
                   validContextBefore=diagnostic['validContextBefore'] if diagnostic else 54 + index - 1,
                   validContextAfter=diagnostic['validContextAfter'] if diagnostic else 54 + index,
                   contextEvidence='receipt-bound per-token diagnostic' if diagnostic else
                       'derived from frozen logical prefix54, ordered synchronous259 calls; not separately sampled',
                   thermal=diagnostic['thermalEnd'] if diagnostic else physical_row['thermalEnd'],
                   thermalEvidence='per-prediction diagnostic' if diagnostic else 'request boundary; intra-request unknown',
                   coreMLStartNanoseconds=start, coreMLEndNanoseconds=end,
                   nativeSignpostWallMilliseconds=stage['wallMilliseconds'],
                   coreMLBackendEvents=[e for e in backend if start <= e['start'] and e['end'] <= end],
                   CPUActivityInsideInternalGaps=None,
                   intervals=[dict(e, relativeStartMilliseconds=(e['start'] - start) / 1e6,
                                   relativeEndMilliseconds=(e['end'] - start) / 1e6,
                                   durationMilliseconds=(e['end'] - e['start']) / 1e6) for _, e in matched])
        row.update(interval_metrics(start, end, [(e['start'], e['end']) for _, e in matched]))
        rows.append(row)
    assert len(used) == len(ane), 'unattributed hardware records'
    warm = [r for r in rows if r['request'] >= 3]
    groups = {}
    for label, low, high in [('early', 1, 20), ('middle', 120, 139), ('late', 240, 259)]:
        groups[label] = summary([r for r in warm if low <= r['predictionIndex'] <= high])
    context_groups = {f'{lo}...{hi}': summary([r for r in warm if lo <= r['validContextAfter'] <= hi])
                      for lo, hi in [(55, 64), (65, 128), (129, 192), (193, 256), (257, 313)]}
    classification = 'MOSTLY_CONTIGUOUS_ANE' if all(r['aneIntervalCount'] == 1 for r in rows) and not backend else 'INSUFFICIENT_TRACE_EVIDENCE'
    result = dict(schemaVersion=1, variant=variant, sourceCommit=receipt['sourceCommit'],
                  processID=receipt['processID'], device=receipt['device'], iOS=receipt['iOS'],
                  modelIdentity=model['identity'], compiledName=compiled,
                  actualResidency='UNKNOWN_RESIDENCY', topologyClassification=classification,
                  meaning='One observed contiguous program-level ANE interval; not proof of uninterrupted kernel activity or full per-op residency.',
                  recordCount=len(rows), hardwareRecordCount=len(ane), backendEventCount=len(backend),
                  allPredictions=summary(rows), warmPredictions=summary(warm), earlyMiddleLate=groups,
                  contextGroups=context_groups, perRequest={str(n): summary([r for r in rows if r['request'] == n]) for n in range(1, 6)},
                  inputs=dict(attribution=str(attribution_path), attributionSHA256=digest(attribution_path),
                              receipt=str(receipt_path), receiptSHA256=digest(receipt_path),
                              diagnostics=str(diagnostics_path) if diagnostics_path else None,
                              diagnosticsSHA256=digest(diagnostics_path) if diagnostics_path else None,
                              exportedTables=attribution['rawEvidence']),
                  limitations=['ANE table resolves model/program intervals, not internal kernels/micro-gaps.',
                               'Hardware table lacks PID: exact compiled hash plus PID-native containment and one-to-one match required.',
                               'CPU/process activity inside hidden gaps UNKNOWN; no exclusive op attribution.',
                               'Historical traces have different instrument sets/source dates; compare topology, not controlled speed or energy.',
                               'Coverage is temporal coverage, not utilization; zero recorded internal gap is not proof of zero hidden synchronization.'])
    output.mkdir(parents=True, exist_ok=True)
    (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    (output / 'predictions.json').write_text(json.dumps(rows, indent=2) + '\n')
    columns = ['request', 'predictionIndex', 'validContextBefore', 'validContextAfter', 'thermal'] + list(interval_metrics(0, 10, [(2, 8)]))
    with (output / 'predictions.csv').open('w') as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)
    print(variant, classification, 'predictions', len(rows), 'warm', result['warmPredictions'], flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('attribution', 'receipt', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--variant', required=True)
    parser.add_argument('--diagnostics', type=Path)
    arguments = parser.parse_args()
    audit(arguments.attribution, arguments.receipt, arguments.output, arguments.variant, arguments.diagnostics)
# Purpose: reproducible read-only topology audit. Upstream SHA-bound Instruments XML/native receipts and Table parser.
# Environment Python3/macOS; generated2026-10-06 America/New_York. New file; no production/model changes.
