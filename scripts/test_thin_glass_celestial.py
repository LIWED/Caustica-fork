"""Compile production visibility walker against a grayscale mock trace scene.

This exercises CPU routing/weights, not Vulkan traversal or textured GPU rendering.
"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
world = (ROOT / 'shaders/world/world.rgen.slang').read_text(encoding='utf-8')
celestial = (ROOT / 'shaders/world/celestial.slang').read_text(encoding='utf-8')

def extract(source, name):
    match = re.search(r'(?:public\s+)?(?:float3|float)\s+' + name + r'\([^)]*\)\s*\{', source)
    assert match, name
    end, depth = match.end(), 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end].replace('public ', '')

walker = extract(world, 'celestialVisibility')
assert 'Payload savedPayload = payload;' in walker, 'missing full payload preservation and thin-glass walker'
assert 'payload = savedPayload;' in walker
glass = world[world.index('if (material == MATERIAL_GLASS) {', world.index('float3 tracePath')):]
glass = glass[:glass.index('// Particles')]
assert glass.index('previousCelestialDelta = true;') > glass.index('if (rndf(seed) < F)'), 'transmission incorrectly clears competing BSDF strategy'
assert glass.index('previousCelestialBsdfPdf = 0.0;') > glass.index('if (rndf(seed) < F)')
source = r'''
#include <algorithm>
#include <cmath>
#include <cassert>
#include <iostream>
#include <random>
#include <vector>
#undef assert
#define assert(condition) do { if (!(condition)) {std::cerr << "Assertion failed: " << #condition; std::exit(1);} } while(false)
using uint = unsigned int;
using float3 = double;
double max(double a,double b){return std::max(a,b);}
double clamp(double a,double b,double c){return std::clamp(a,b,c);}
double dot(double a,double b){return a*b;}
constexpr uint CULL_SECONDARY=1, MATERIAL_GLASS=3;
constexpr double GLASS_IOR=1.52, GLASS_TRANSMIT_BIAS=1e-4, RAY_CONE_MIN_WIDTH=1e-5;
struct Payload { double albedo=0.3, normal=1, hitT=37; uint flags=127; double extra=93; } payload;
struct PC {uint maxBounces=8;} pc;
struct Hit {uint material; double tint; double cosine;};
std::vector<Hit> scene; size_t cursor=0;
void payloadSetTraceState(bool, double, double) {payload.flags=0;payload.extra=0;}
uint payloadMaterial(){return payload.flags;}
void traceRadianceReordered(uint,double,double,double,double){
 if(cursor==scene.size()){payload.hitT=-1;return;}
 auto h=scene[cursor++];payload.hitT=1;payload.normal=h.cosine;payload.albedo=h.tint;payload.flags=h.material;
}
#define CAUSTICA_OFFLINE_FP32
'''
source += extract(world, 'fresnelDielectric') + '\n' + walker + '\n'
source += extract(celestial, 'celestialPowerHeuristic') + '\n'
source += extract(celestial, 'celestialDirectMisWeight') + '\n'
source += extract(celestial, 'celestialEscapeMisWeight') + '\n'
source += r'''
double run(uint bounce){
 payload=Payload{};auto saved=payload;cursor=0;
 double result=celestialVisibility(0,-1,10000,bounce,0,0.1);
 assert(payload.hitT==saved.hitT && payload.flags==saved.flags && payload.extra==saved.extra && payload.albedo==saved.albedo && payload.normal==saved.normal);
 return result;
}
int main(){
 for(uint k=0;k<8;k++){
  scene.assign(k,Hit{3,0.64,1});double f=std::pow((1.52-1)/(1.52+1),2);
  double expected=std::pow((1-f)*0.8,k);
  for(uint b=0;b<=8;b++){
   double actual=run(b);double oracle=(k==0 || b+k+1<=8)?expected:0;
   assert(std::abs(actual-oracle)<2e-6);
  }
 }
 scene={{3,0.64,1},{0,1,1}}; assert(run(0)==0);
 scene={{3,0.64,1},{1,1,1}}; assert(run(0)==0); // water is not a thin pane
 scene={{3,0.64,0}}; assert(run(0)==0); // grazing Fresnel reflection
 std::mt19937 rng(1317);std::uniform_real_distribution<double> u(0,1);
 const int count=1000000; const double hitProbability=.002, radiance=1/hitProbability;
 for(int k: {1,2,4}){
  scene.assign(k,Hit{3,0.64,1});double transmission=run(0);
  double survival=std::pow(1-std::pow((1.52-1)/(1.52+1),2),k),tint=std::pow(.8,k);
  double wl=celestialDirectMisWeight(radiance,1,true), wb=celestialEscapeMisWeight(1,radiance,false);
  double sum=0,sq=0,oldSum=0,oldSq=0;
  for(int i=0;i<count;i++){
   double camera=(u(rng)<hitProbability && u(rng)<survival)?tint*radiance:0;
   double paired=transmission*wl+camera*wb;
   sum+=paired;sq+=paired*paired;oldSum+=camera;oldSq+=camera*camera;
  }
  double mean=sum/count,variance=sq/count-mean*mean,oldVar=oldSq/count-std::pow(oldSum/count,2);
  assert(std::abs(mean-transmission)<1e-5);assert(variance<oldVar*.001);
  std::cout<<"interfaces="<<k<<" mean="<<mean<<" reference="<<transmission<<" variance="<<variance<<" old="<<oldVar<<"\n";
 }
 std::cout<<"PASS production walker: budget, blockers, payload restore, paired multi-interface estimator\n";
}
'''
out = ROOT / 'build/thin-glass-celestial'
out.mkdir(parents=True, exist_ok=True)
(out / 'test.cpp').write_text(source, encoding='utf-8')
subprocess.run(['D:/program/mingw64/bin/g++.exe','-std=c++17','-O2',str(out/'test.cpp'),'-o',str(out/'test.exe')],check=True)
subprocess.run([str(out/'test.exe')],check=True)
for label, old, new in [
    ('missing_fresnel', '(1.0 - F) * sqrt', '1.0 * sqrt'),
    ('missing_restore', 'payload = savedPayload;', ''),
    ('unbounded_interfaces', 'bounce + crossed + 1u >= pc.maxBounces', 'false'),
    ('water_transmission', 'payloadMaterial() != MATERIAL_GLASS', 'false'),
]:
    assert old in source, label
    mutant = source.replace(old, new)
    (out / 'mutant.cpp').write_text(mutant, encoding='utf-8')
    subprocess.run(['D:/program/mingw64/bin/g++.exe','-std=c++17','-O2',str(out/'mutant.cpp'),'-o',str(out/'mutant.exe')],check=True)
    result = subprocess.run([str(out/'mutant.exe')],capture_output=True,text=True)
    assert result.returncode != 0 and 'Assertion' in result.stderr, (label, result.stderr)
    print('PASS behavioral negative control:', label)
