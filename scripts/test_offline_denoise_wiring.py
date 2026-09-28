"""Display-only routing and resource contracts, including destructive mutations."""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
def read(name): return (ROOT/name).read_text(encoding='utf-8')
host=read('src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java')
pipeline=read('src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtOfflineDenoisePipeline.java')
shader=read('shaders/display/offline_denoise.comp')

def contracts(h,p,s):
    gate='if (offlineDone && debugView == 0 && CausticaConfig.Rt.Offline.DENOISE.value()'
    assert gate in h,'source-only offline gate and switch'
    assert h.index('exposure.record(ctx, cmd, stack, rrOutput);') < h.index(gate) < h.index('displayPipeline.dispatch(cmd, displayW'),'raw exposure before reconstruction before display'
    signature=h[h.index('private static long offlineRenderSignature'):h.index('private RtPipeline ensureWorld')]
    assert 'DENOISE' not in signature,'toggle must not reset history'
    assert 'new long' not in p[p.index('public void dispatch'):p.index('public void destroy')],'preallocated immutable descriptor sets'
    assert 'long[] inputs = {history, scratchA};' in p
    assert 'long[] outputs = {scratchA, scratchA};' in p,'history must never be writable'
    assert '.maxSets(2)' in p and 'descriptorCount(18)' in p
    dispatch=p[p.index('public void dispatch'):p.index('public void destroy')]
    assert 'vkUpdateDescriptorSets' not in dispatch
    assert 'VulkanCommandEncoder.memoryBarrier' in dispatch,'inter-pass memory dependencies'
    assert dispatch.index('vkCmdDispatch')<dispatch.index('VulkanCommandEncoder.memoryBarrier')
    assert 'pass < 2' in dispatch and 'pass == 1 ? 1 : 0' in dispatch
    assert 'push.putInt(12, weights.previousSamples() + weights.currentSamples());' in dispatch
    assert 'readonly image2D inputImage' in s
    assert set(re.findall(r'imageStore\((\w+)',s))=={'outputImage','resolvedImage'}
    for field in ['offlineDenoisePipeline','offlineDenoiseA','offlineMoments']:
        assert field+'.destroy();' in h and field+' = null;' in h
    assert h.index('destroyOfflineResources();',h.index('private void ensureOutput') if 'private void ensureOutput' in h else h.index('private boolean ensureOutput')) < h.index('offlineDenoiseA = ctx.createStorageImage')

assert 'readonly image2D rawImage' in shader and 'readonly image2D momentImage' in shader
assert 'imageLoad(rawImage, q).rgb' in shader
assert 'specular, moments, history};' in pipeline
accumulate=read('shaders/display/offline_accumulate.comp')
assert accumulate.index('imageStore(momentImage')<accumulate.index('imageStore(historyImage')
assert 'offlinePipeline.setImages(output.view, offlineHistory.view, rrOutput.view, offlineMoments.view);' in host
assert 'offline.denoise", true' not in read('src/main/java/dev/comfyfluffy/caustica/CausticaConfig.java')
contracts(host,pipeline,shader)
for before,after in [
    ('offlineDone && debugView == 0 &&','offlineDone &&'),
    ('long[] outputs = {scratchA, scratchA};','long[] outputs = {history, scratchA};'),
    ('VulkanCommandEncoder.memoryBarrier(cmd, stack);',''),
    ('readonly image2D inputImage','image2D inputImage'),
]:
    changed=[x.replace(before,after) for x in [host,pipeline,shader]]
    assert changed!=[host,pipeline,shader]
    try: contracts(*changed)
    except AssertionError: pass
    else: raise AssertionError('undetected destructive mutation: '+before)
config=read('src/main/java/dev/comfyfluffy/caustica/CausticaConfig.java')
assert 'bool("caustica.rt.offline.denoiseAdaptive", "offline.denoise-adaptive", false)' in config
ui=read('src/main/java/dev/comfyfluffy/caustica/client/RtVideoOptions.java')
assert 'offlineDenoise(),' in ui and 'CausticaConfig.Rt.Offline.DENOISE' in ui
for language in ['en_us','zh_cn']:
    data=json.loads(read('src/main/resources/assets/caustica/lang/'+language+'.json'))
    for suffix in ['', '.tooltip']: assert data['caustica.options.rt.offlineDenoise'+suffix]
print('PASS source-only routing, raw exposure/history, no-reset toggle, ping-pong barriers/lifecycle, four negative controls and UI')
