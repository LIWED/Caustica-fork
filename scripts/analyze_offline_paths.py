"""Summarize bounded diagnostic captures; counts are not unbiased path frequencies."""
import argparse
import collections
import hashlib
import json
import math
from pathlib import Path

import numpy as np


def analyze(path):
    rows = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]
    paths = [row for row in rows if row['type'] == 'path']
    result = {'input': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
              'session': rows[0], 'count': len(paths), 'groups': {}}
    if not paths:
        return result
    errors = []
    nonfinite = 0
    mismatches = 0
    for row in paths:
        replay = row['steps'][row['bounce']]['maxContribution_category']
        if replay[3] != row['category']:
            mismatches += 1
        values = [float(v) for s in row['steps'] for lane in s.values() for v in lane]
        values += [float(v) for v in row['sourceRGB']]
        if not all(math.isfinite(v) for v in values):
            nonfinite += 1
        source = [float(v) for v in row['sourceRGB']]
        got = [float(v) for v in replay[:3]]
        if all(math.isfinite(v) for v in source + got):
            errors.append(max(abs(a-b)/max(1.0, abs(b)) for a,b in zip(got, source)))
    result['maxReplayRelativeError'] = max(errors, default=None)
    result['replayCategoryMismatches'] = mismatches
    result['nonfiniteRecords'] = nonfinite
    result['categories'] = dict(collections.Counter(r['category'] for r in paths))
    result['captureGenerations'] = dict(collections.Counter(r.get('captureGeneration', 0) for r in paths))
    legacy_horizontal = rows[0].get('version') in ('0.3.9', '0.3.10', '0.3.11')
    result['horizontalEdgeAnalysisApplicable'] = legacy_horizontal
    result['sampleRange'] = [min(int(r['sampleIndex']) for r in paths), max(int(r['sampleIndex']) for r in paths)]
    result['flags'] = dict(collections.Counter(r['flags'] for r in paths))
    result['bounceSettings'] = dict(collections.Counter(r['maxBounces'] for r in paths))
    result['events'] = dict(collections.Counter(','.join(str(int(s['outgoing_event'][3])) for s in r['steps']) for r in paths))
    for protected in (0, 1):
        group = [r for r in paths if r['protected'] == protected]
        if not group:
            continue
        near_edge = 0
        max_tilt = 0.0
        for row in group:
            axis = np.array(row['lightDir'][:3], dtype=np.float64)
            axis /= np.linalg.norm(axis)
            right = np.cross(axis, row['celestial'][:3]); right /= np.linalg.norm(right)
            up = np.cross(right, axis)
            tangent = math.tan(row['lightDir'][3] * 1.05)  # 0.3.9 proposal definition
            at_edge = False
            for step in row['steps']:
                if step['geometricNormal_material'][3] == 1 and all(math.isfinite(float(v)) for v in step['geometricNormal_material'][:3]):
                    n = step['geometricNormal_material'][:3]
                    max_tilt = max(max_tilt, math.degrees(math.acos(min(1, abs(n[1])/np.linalg.norm(n)))))
                if not legacy_horizontal or step['outgoing_event'][3] != 0 or step['incoming_inWater'][3] != 1:
                    continue
                water = np.array(step['outgoing_event'][:3])
                air = water * 1.333
                cos_squared = 1-air[0]**2-air[2]**2
                if cos_squared <= 0:
                    continue
                air[1] = math.sqrt(cos_squared)
                cosine = np.dot(air, axis)
                edge = max(abs(np.dot(air, right)), abs(np.dot(air, up))) / cosine / tangent
                at_edge |= abs(edge-1) < 2e-4
            near_edge += int(at_edge)
        values = sorted(float(r['maxValue']) for r in group)
        result['groups'][str(protected)] = {
            'count': len(group), 'nearProposalEdge': near_edge if legacy_horizontal else None,
            'medianPeak': values[len(values)//2], 'maxPeak': values[-1],
            'maxWaterTiltDegrees': max_tilt,
            'largestPath': max(group, key=lambda r:float(r['maxValue']))}
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = analyze(args.log)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')
    summary = {k:v for k,v in result.items() if k != 'groups'}
    summary['groups'] = {k:{a:b for a,b in v.items() if a != 'largestPath'} for k,v in result.get('groups',{}).items()}
    print(json.dumps(summary, indent=2))
