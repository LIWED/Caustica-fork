"""Cross-language integration checks plus real accumulation-reset behavior."""
from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
def read(path):
    return (ROOT / path).read_text(encoding='utf-8')
def block(text, anchor):
    assert anchor in text, 'FAIL missing: ' + anchor
    start = text.index('{', text.index(anchor)) + 1
    end, depth = start, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end - 1]

shader = read('shaders/world/world.rgen.slang')
assert 'import indirect_regularization;' in shader, 'FAIL: regularization is not connected to renderer'
path = block(shader, 'float3 tracePath(')
assert 'bool hasNonDeltaBounce = false;' in path
assert path.count('hasNonDeltaBounce = true;') == 2, 'ordinary and particle scattering set history'
for kind in ['MATERIAL_GLASS', 'MATERIAL_WATER']:
    body = block(path, 'if (material == ' + kind + ')')
    assert 'hasNonDeltaBounce' not in body, 'ideal interface must preserve history'
anchor = 'rough = regularizedPathRoughness(rough, hasNonDeltaBounce, (pc.flags >> 7u) & 3u);'
assert '#ifdef CAUSTICA_OFFLINE_FP32\n        ' + anchor + '\n#endif' in path
ordinary = path[path.index('float rough = pbr ?'):]
assert ordinary.index(anchor) < ordinary.index('if (bounce == 0)') < ordinary.index('sampleStaticDirect(')
assert ordinary.index('hasNonDeltaBounce = true;') > ordinary.index('throughput *= evaluateSurfaceBrdf(')
assert ordinary.count('regularizedPathRoughness(') == 1
for expected in ['F0, rough, pbr,', 'F0, rough, pbr)', 'sampleGGXVNDF(n, v, rough, seed)',
                 'surfaceSpecularPosterior(n, v, nextDir, diffAlb, F0, rough)']:
    assert expected in ordinary, 'all sampling/evaluation consumers share effective roughness: ' + expected
config = read('src/main/java/dev/comfyfluffy/caustica/CausticaConfig.java')
assert 'clampedInt("caustica.rt.offline.regularization", "offline.regularization", 0, 0, 2)' in config
host = read('src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java')
assert 'featureFlags |= OfflineRegularizationPolicy.flags(CausticaConfig.Rt.Offline.REGULARIZATION.value(), true);' in host
assert 'flags |= OfflineRegularizationPolicy.flags(CausticaConfig.Rt.Offline.REGULARIZATION.value(), offlineAccumulating);' in host
ui = read('src/main/java/dev/comfyfluffy/caustica/client/RtVideoOptions.java')
assert 'offlineRegularization(),' in ui and 'List.of(0, 1, 2)' in ui
for lang in ['en_us', 'zh_cn']:
    data = json.loads(read('src/main/resources/assets/caustica/lang/' + lang + '.json'))
    for suffix in ['', '.tooltip', '.0', '.1', '.2']:
        assert data['caustica.options.rt.offlineRegularization' + suffix]

out = ROOT / 'build/indirect-regularization'
out.mkdir(parents=True, exist_ok=True)
test = out / 'RegularizationResetTest.java'
test.write_text('''
import dev.comfyfluffy.caustica.rt.offline.*;
public class RegularizationResetTest {
 public static void main(String[] args) {
  for (int mode=-2;mode<=4;mode++) {
   int flags=OfflineRegularizationPolicy.flags(mode,true);
   if(flags!=(Math.clamp(mode,0,2)<<7)||OfflineRegularizationPolicy.flags(mode,false)!=0)
    throw new AssertionError("mode encoding/offline isolation");
   if((flags&127)!=0)throw new AssertionError("existing flags overwritten");
  }
  for(int a=0;a<3;a++)for(int b=0;b<3;b++) {
   long sa=OfflineRenderSignature.create(800,600,1,2,0,8,15|OfflineRegularizationPolicy.flags(a,true),1,2,3);
   long sb=OfflineRenderSignature.create(800,600,1,2,0,8,15|OfflineRegularizationPolicy.flags(b,true),1,2,3);
   if((sa==sb)!=(a==b))throw new AssertionError("signature collision");
   OfflineAccumulationState state=new OfflineAccumulationState();
   state.observe(true,false,0,sa,false,true,1);
   state.observe(true,false,3000000000L,sa,false,true,1);
   var result=state.observe(true,false,4000000000L,sb,false,true,1);
   if(a!=b&&!result.resetHistory())throw new AssertionError("mode change mixes histories");
  }
  System.out.println("PASS mode flags and all nine accumulation transitions");
 }
}
''', encoding='utf-8')
java = 'D:/program/java25/bin/'
sources = [ROOT / ('src/main/java/dev/comfyfluffy/caustica/rt/offline/' + name + '.java')
           for name in ['OfflineRegularizationPolicy', 'OfflineRenderSignature', 'OfflineAccumulationState']]
subprocess.run([java+'javac.exe', '-d', str(out), str(test), *map(str, sources)], check=True)
subprocess.run([java+'java.exe', '-ea', '-cp', str(out), 'RegularizationResetTest'], check=True)
print('PASS shader history, effective BSDF/PDF wiring, settings, locales, offline-only flags')
