"""Execute the production pilot-selection policy with controlled trace results.

Ray intersection is stubbed; mapping integrals are tested separately. Also check
that every estimator receives the same fixed vertex proposal context.
"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
world = (ROOT / 'shaders/world/world.rgen.slang').read_text(encoding='utf-8')


def extract(source, name):
    m = re.search(r'float\s+' + name + r'\([^)]*\)\s*\{', source)
    assert m, 'missing actual-interface pilot: ' + name
    end, depth = m.end(), 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[m.start():end]


pilot = extract(world, 'offlineInterfaceGuide')
assert 'rndf(' not in pilot and 'offlineContribution(' not in pilot
assert 'pathProbe' not in pilot, 'pilot must not become an observed path event'
assert pilot.count('traceRadianceReordered(') == 1, 'bounded single pilot'
assert '#ifdef CAUSTICA_OFFLINE_FP32' in pilot

preamble = r'''
#include <cmath>
#include <iostream>
#include <cstdlib>
using uint = unsigned;
struct float2 {float x,y; float2(float a=0):x(a),y(a){} float2(float a,float b):x(a),y(b){} };
struct float3 {float x,y,z; float3(float a=0):x(a),y(a),z(a){} float3(float a,float b,float c):x(a),y(b),z(c){} };
float3 operator+(float3 a,float3 b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
float3 operator-(float3 a){return {-a.x,-a.y,-a.z};}
float3 operator*(float3 a,float b){return {a.x*b,a.y*b,a.z*b};}
float2 operator+(float2 a,float2 b){return {a.x+b.x,a.y+b.y};}
float dot(float3 a,float3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
float3 normalize(float3 a){return a*(1/std::sqrt(dot(a,a)));}
float max(float a,float b){return a>b?a:b;}
constexpr float WATER_IOR=1.333f;
constexpr uint MATERIAL_WATER=1,CULL_SECONDARY=2;
struct Payload {float hitT; float3 normal; uint material,entering,sentinel;};
Payload payload{7,{.2f,.3f,.4f},0,0,12345}, original=payload, answer;
struct PC {float3 lightDir{.6f,.8f,0},lightRadiance{1};float halfAngle=.01047f;uint flags=0;float2 waterAnchor{3,4};float waveTime=5;} pc;
int traces=0,waves=0;float3 pilotOrigin,pilotDirection;
float waterCelestialGuideMix(bool submerged,float angle,float elevation,float strength){
 return submerged && angle>0 && elevation>.1f+2*std::tan(angle*1.05f) && strength>0?.5f:0;
}
float offlineWaterGuideMix(bool submerged){return waterCelestialGuideMix(submerged,pc.halfAngle,pc.lightDir.y,pc.lightRadiance.x);}
float3 interfaceCelestialDirection(float3 a,float3 n,float eta,bool reflection){
 float ca=dot(a,n);if(reflection)return a+n*(-2*ca);
 float3 tangent=a+n*(-ca);float3 t=tangent*(1/eta);return t+n*std::sqrt(1-dot(t,t));
}
uint payloadMaterial(){return payload.material;}
bool payloadWaterEntering(){return payload.entering!=0;}
void payloadSetTraceState(bool,float,float){payload.sentinel=0;}
void traceRadianceReordered(uint mask,float3 p,float tmin,float3 d,float tmax){
 if(mask!=CULL_SECONDARY || tmin!=0 || tmax!=10000)std::exit(2);
 traces++;pilotOrigin=p;pilotDirection=d;payload=answer;
}
float3 applyWaterWaves(float3 n,float2 pos,float time){waves++;return normalize(n+float3(.05f,0,0));}
void require(bool b,const char* msg){if(!b){std::cerr<<msg<<"\n";std::exit(1);}}
bool near(float3 a,float3 b){return std::abs(a.x-b.x)+std::abs(a.y-b.y)+std::abs(a.z-b.z)<1e-5f;}
void restored(){require(payload.hitT==original.hitT && near(payload.normal,original.normal) && payload.material==original.material && payload.entering==original.entering && payload.sentinel==original.sentinel,"full payload must survive pilot");}
'''
tests = r'''
int main(){
 float3 gn;bool reflection;float3 p(2,3,4),wall(1,0,0),up(0,1,0);
 answer={2,normalize(float3(-.003583809f,.99997234f,-.006516753f)),1,1,999};
 float mix=offlineInterfaceGuide(p,wall,false,0,8,.2f,.3f,gn,reflection);
#ifdef CAUSTICA_OFFLINE_FP32
 require(mix==.5f && reflection && near(gn,answer.normal),"dry wall must use measured reflection normal");
 require(traces==1 && near(pilotOrigin,p) && near(pilotDirection,float3(.6f,-.8f,0)),"one center-direction pilot from continuation origin");restored();
 pc.flags=16;
 mix=offlineInterfaceGuide(p,wall,false,0,8,.2f,.3f,gn,reflection);
 require(waves==1 && reflection && gn.x>.04f,"reflection must use actual wave normal");restored();
 answer.normal=-answer.normal;answer.entering=0;
 mix=offlineInterfaceGuide(p,up,true,0,8,.2f,.3f,gn,reflection);
 require(mix==.5f && !reflection && near(gn,-answer.normal) && waves==1,"exit uses geometric normal even with waves enabled");restored();
 answer.material=0;
 mix=offlineInterfaceGuide(p,up,true,0,8,.2f,.3f,gn,reflection);
 require(mix==.5f && !reflection && near(gn,up),"failed wet pilot keeps original horizontal support");restored();
 mix=offlineInterfaceGuide(p,wall,false,0,8,.2f,.3f,gn,reflection);
 require(mix==0,"failed dry pilot retains BSDF only");restored();
 answer.material=1;answer.entering=0;
 mix=offlineInterfaceGuide(p,wall,false,0,8,.2f,.3f,gn,reflection);
 require(mix==0,"wrong interface orientation must not activate reflection");restored();
 answer.entering=1;answer.hitT=-1;
 mix=offlineInterfaceGuide(p,wall,false,0,8,.2f,.3f,gn,reflection);
 require(mix==0,"miss must not reuse stale water material");restored();
 int previous=traces;
 mix=offlineInterfaceGuide(p,up,false,0,8,.2f,.3f,gn,reflection);
 require(mix==0 && traces==previous,"do not pilot below receiver hemisphere");
 mix=offlineInterfaceGuide(p,wall,false,8,8,.2f,.3f,gn,reflection);
 require(mix==0 && traces==previous,"no pilot at terminal vertex");
 pc.lightRadiance=float3(0);
 mix=offlineInterfaceGuide(p,wall,false,0,8,.2f,.3f,gn,reflection);
 require(mix==0 && traces==previous,"inactive celestial source must not pilot");
#else
 require(mix==0 && traces==0,"realtime keeps old BSDF and performs no pilot");restored();
#endif
 std::cout<<"PASS pilot selection, normal policy, fallback and payload isolation\n";
}
'''


def run(source, stem, offline=True):
    source = source.replace('out float3 ', 'float3& ').replace('out bool ', 'bool& ')
    source = source.replace('pc.lightDir.xyz', 'pc.lightDir').replace('pc.lightDir.w', 'pc.halfAngle')
    source = source.replace('pilotPos.xz', 'float2(pilotPos.x, pilotPos.z)').replace('pc.waterAnchor.xy', 'pc.waterAnchor').replace('pc.waterParams.w', 'pc.waveTime')
    out = ROOT / 'build/interface-celestial'
    out.mkdir(parents=True, exist_ok=True)
    cpp, exe = out / (stem + '.cpp'), out / (stem + '.exe')
    cpp.write_text(preamble + source + tests)
    subprocess.run(['D:/program/mingw64/bin/g++.exe', '-std=c++17', '-O2', *(['-DCAUSTICA_OFFLINE_FP32'] if offline else []), str(cpp), '-o', str(exe)], check=True)
    return subprocess.run([str(exe)], capture_output=True, text=True)


for offline in [True, False]:
    result = run(pilot, 'pilot-' + str(offline), offline)
    assert result.returncode == 0, result.stderr
    print(result.stdout, end='')
for old, new in [('payload = savedPayload;', ''), ('guideNormal = interfaceNormal;', 'guideNormal = float3(0.0, 1.0, 0.0);')]:
    assert old in pilot
    result = run(pilot.replace(old, new), 'pilot-mutant')
    assert result.returncode != 0, 'pilot regression missed mutation: ' + old

for direction, f0 in [('nextDir', 'F0'), ('lightDir', 'F0'), ('l', 'f0')]:
    assert f'surfaceContinuationPdf(n, v, {direction}, diffAlb, {f0}, rough, pbr, waterGuideMix, waterGuideNormal, waterGuideReflection)' in world
assert 'payloadSectionSlot(), waterGuideMix, waterGuideNormal, waterGuideReflection, seed)' in world
assert 'pc.lightDir.w, guidedAirDir, nextDir, waterGuideNormal, WATER_IOR, waterGuideReflection)' in world
assert 'pc.lightDir.w, nextDir, waterGuideNormal, WATER_IOR, waterGuideReflection)' in world
assert world.index('float waterGuideMix = offlineInterfaceGuide(') < world.index('p, n, v, diffAlb, F0, rough, pbr, payloadSectionSlot(), waterGuideMix')
print('PASS shared NEE/continuation context and generated-sample density binding')
