"""Execute extracted incident-medium/IOR decisions against a captured false water exit."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'shaders/world/world.rgen.slang').read_text(encoding='utf-8')


def block(source, anchor):
    start = source.index('{', source.index(anchor))
    end, depth = start + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start + 1:end - 1]


def policies(source):
    guide = block(source, 'void transmissionGuideHit(')
    trace = block(source, 'float3 tracePath(')
    sections = [
        ('radiance', block(trace, 'if (material == MATERIAL_WATER)'), 'inWater', 'waterEntering'),
        ('initialGuide', block(guide, 'else if (surfaceMaterial == MATERIAL_WATER)'), 'guideInWater', 'waterEnteringAtSurface'),
        ('nestedGuide', block(guide, 'if (material == MATERIAL_WATER)'), 'guideInWater', 'waterEntering'),
    ]
    bodies = []
    for name, section, medium, entering in sections:
        eta_start = section.index('float etaI =')
        prefix = section[:eta_start]
        # Run the actual correction (if present) and both IOR selection expressions.
        correction = re.findall(r'\b' + medium + r'\s*=\s*!\s*' + entering + r'\s*;', prefix)
        eta = re.search(r'float etaI =[^;]+;\s*float etaT =[^;]+;', section).group()
        bodies.append('std::pair<float,bool> ' + name + '(bool ' + medium + ', bool ' + entering + ') {'
                      + '\n'.join(correction) + eta + 'return {etaI / etaT, ' + medium + '};}')
    return '\n'.join(bodies)


PREAMBLE = r'''
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <utility>
constexpr float WATER_IOR = 1.333f;
void require(bool ok,const char* message) {if(!ok){std::cerr<<"FAIL "<<message<<"\n";std::exit(1);}}
'''
TEST = r'''
int main() {
 for(auto decide : {radiance, initialGuide, nestedGuide}) {
  // Captured pixel487,316/sample4259: historical air state but an outward water-top hit.
  // Correct water->air incidence must TIR; old air->water ratio reproduces its false exit.
  float dx=-.8130612969398499f,dy=.22701840102672577f,dz=.5360912084579468f;
  float nx=0.f,ny=-.99997878074646f,nz=.006516795139759779f;
  float cosine=-(dx*nx+dy*ny+dz*nz);
  auto [eta, reflectedMedium]=decide(false,false);
  float k=1.f-eta*eta*(1.f-cosine*cosine);
  require(k<0.f,"captured exiting-water ray must totally internally reflect");
  require(reflectedMedium,"reflected ray must remain in incident water");
  for(bool entering:{false,true})for(bool historicalWater:{false,true}) {
   auto [ratio, medium]=decide(historicalWater,entering);
   float expected=entering?1.f/WATER_IOR:WATER_IOR;
   require(std::abs(ratio-expected)<1e-7f,"interface orientation controls relative IOR");
   require(medium==!entering,"both stale histories corrected at the interface");
   for(float cosI:{.1f,.5f,.8f,1.f}) {
    float discriminant=1.f-ratio*ratio*(1.f-cosI*cosI);
    float reference=1.f-expected*expected*(1.f-cosI*cosI);
    require((discriminant<0.f)==(reference<0.f),"entry/exit TIR classification");
   }
  }
 }
 std::cout<<"PASS captured false exit, TIR, reflected medium and all three consumer policies\n";
}
'''
out = ROOT / 'build/water-incident-medium'
out.mkdir(parents=True, exist_ok=True)


def run(source, stem):
    cpp, exe = out/(stem+'.cpp'), out/(stem+'.exe')
    cpp.write_text(PREAMBLE + policies(source) + TEST)
    subprocess.run(['D:/program/mingw64/bin/g++.exe', '-std=c++17', '-O2', str(cpp), '-o', str(exe)], check=True)
    return subprocess.run([str(exe)], capture_output=True, text=True)


result = run(SOURCE, 'test')
print(result.stdout, end='')
assert result.returncode == 0, result.stderr
for name, statement in [
    ('radiance', 'inWater = !waterEntering;'),
    ('initial-guide', 'guideInWater = !waterEnteringAtSurface;'),
    ('nested-guide', 'guideInWater = !waterEntering;'),
]:
    assert statement in SOURCE
    mutant = run(SOURCE.replace(statement, ''), 'missing-'+name)
    assert mutant.returncode != 0 and 'captured exiting-water' in mutant.stderr
print('PASS three independently removed incident-state corrections are rejected')
