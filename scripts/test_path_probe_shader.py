"""Probe ABI and observer/replay isolation source contracts (not a GPU test)."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
module = root / 'shaders/world/path_probe.slang'
assert module.exists(), 'expected RED: no actual-path probe'
source = module.read_text(encoding='utf-8')
world = (root/'shaders/world/world.rgen.slang').read_text(encoding='utf-8')
common = (root/'shaders/world/world_common.slang').read_text(encoding='utf-8')
assert 'uint64_t pathProbeAddr;' in common and 'float pathProbeThreshold;' in common

def block(text, anchor):
    start=text.index('{',text.index(anchor)); end=start+1;depth=1
    while depth:
        depth+=(text[end]=='{')-(text[end]=='}');end+=1
    return text[start+1:end-1]

step=block(source,'struct PathProbeStep')
record=block(source,'struct PathProbeRecord')
assert len(re.findall(r'float4\s+\w+;',step))==10, 'step stride160'
assert len(re.findall(r'(?:float4|uint4)\s+\w+;',record))==4, 'record header64'
assert 'PathProbeStep steps[33];' in record, 'record stride5344'
assert 'Access.ReadWrite' in source

def check_wiring(text):
    observe=block(text,'void pathProbeObserve(')
    assert 'pathProbeEligible(category, bounce)' in observe, 'observe general lighting before filtering'
    eligible=block(text,'bool pathProbeEligible(')
    assert 'category == 8u || category == 10u' in eligible, 'direct surface lighting at all depths'
    assert 'bounce > 0' in eligible and 'category == 9u || category == 13u || category == 14u' in eligible
    assert 'pathFlags' not in eligible, 'ordinary paths must not require water/glass history'
    assert 'rndf' not in observe and 'seed' not in observe
    contribution=block(text,'float3 offlineContribution(')
    assert contribution.index('pathProbeObserve(value, category, bounce, pathFlags);') < contribution.index('offlineContributionVisible')
    replay=block(text,'void replayPathProbe(')
    assert 'uint replaySeed = initialSeed;' in replay
    assert 'tracePath(origin, direction, spread, replaySeed);' in replay
    assert 'frameRadiance' not in replay and 'InterlockedAdd' in replay
    assert 'savedGuides.restore();' in replay
    assert replay.index('record[0].state.w = 1u;') > replay.index('tracePath(origin, direction, spread, replaySeed);')
    assert 'uint initialSeed = seed;' in text
    assert text.index('frameRadiance += tracePath(origin, dir, rayConeSpread, seed);') < text.index('replayPathProbe(origin, dir, rayConeSpread, initialSeed, pix, globalSampleIndex);')
    assert text.count('pathProbeEnd(bounce,') >= 7, 'surface/glass/water pre/post roulette and miss'

check_wiring(world)
for old,new in [('uint replaySeed = initialSeed;','uint replaySeed = 0u;'),
                ('savedGuides.restore();',''),
                ('pathProbeObserve(value, category, bounce, pathFlags);',''),
                ('pathProbeEligible(category, bounce)','category == 14u && (pathFlags & 12u) != 0u')]:
    try: check_wiring(world.replace(old,new))
    except (AssertionError,ValueError): pass
    else: raise AssertionError('undetected replay/observer bypass '+old)
print('PASS: probe record ABI, pre-filter observer, same-seed discarded replay, guide restoration, completion and four bypass controls')
