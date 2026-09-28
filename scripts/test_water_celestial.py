"""Production FP32 proposal regression and independent planar-water transport integral.

Runs extracted Slang functions as C++; geometry is analytic, not a Vulkan/game test.
"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
proposal_path = ROOT / 'shaders/world/water_celestial.slang'
assert proposal_path.exists(), 'missing refracted-water celestial proposal (expected RED on 0.3.6)'
proposal = proposal_path.read_text(encoding='utf-8')
celestial = (ROOT / 'shaders/world/celestial.slang').read_text(encoding='utf-8')
world = (ROOT / 'shaders/world/world.rgen.slang').read_text(encoding='utf-8')

def extract(source, name):
    m = re.search(r'(?:public\s+)?(?:float3|float|bool|void)\s+' + name + r'\([^)]*\)\s*\{', source)
    assert m, name
    end, depth = m.end(), 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    body = source[m.start():end].replace('public ', '').replace('out float3 ', 'float3& ')
    return body

def contracts(source):
    assert 'import water_celestial;' in source
    assert source.count('if (bounce >= rrStart && !waterCelestialGuidedLeg)') == 3, 'guide must survive ordinary/water/glass roulette'
    assert 'waterCelestialGuidedLeg = waterCelestialProtectLeg(chooseWaterGuide, waterGuideMix, nextGuidePdf);' in source, 'protect supported BSDF directions too, and reset at each ordinary scattering'
    assert source.index('float nextGuidePdf = 0.0;', source.index('bool chooseWaterGuide')) > source.index('nextDir = cosineDir(n, seed);', source.index('bool chooseWaterGuide'))
    assert 'nextGuidePdf = interfaceCelestialPdf(pc.lightDir.xyz, pc.celestial.xyz,' in source
    assert 'pc.lightDir.w, nextDir, waterGuideNormal, WATER_IOR, waterGuideReflection);' in source
    assert 'float waterGuideMix = offlineInterfaceGuide(p, n, inWater, bounce, maxBounces,' in source
    assert 'float guideHalfAngle = waterCelestialGuideHalfAngle(pc.lightDir.w);' in source
    assert 'float3 guidedAirDir = sampleSquare(pc.lightDir.xyz, guideHalfAngle, seed);' in source
    assert 'nextDir = interfaceCelestialDirection(guidedAirDir, waterGuideNormal, WATER_IOR, waterGuideReflection);' in source
    assert 'float glossyChance = surfaceSpecularPosterior(n, v, nextDir, diffAlb, F0, rough);' in source
    assert 'guidedGlossyCone = rndf(seed) < glossyChance;' in source
    assert 'previousBsdfPdf = surfaceContinuationPdf(n, v, nextDir, diffAlb, F0, rough, pbr, waterGuideMix, waterGuideNormal, waterGuideReflection);' in source
    assert '* max(0.0, dot(n, nextDir)) / previousBsdfPdf;' in source
    assert 'surfaceContinuationPdf(n, v, lightDir, diffAlb, F0, rough, pbr, waterGuideMix, waterGuideNormal, waterGuideReflection)' in source, 'celestial NEE competitor'
    assert 'surfaceContinuationPdf(n, v, l, diffAlb, f0, rough, pbr, waterGuideMix, waterGuideNormal, waterGuideReflection)' in source, 'area-light NEE competitor'
    assert 'payloadSectionSlot(), waterGuideMix, waterGuideNormal, waterGuideReflection, seed)' in source, 'area-light caller must pass mixture'
    assert 'previousCelestialBsdfPdf = previousBsdfPdf;' in source
    assert 'previousCelestialDelta = true;' in source and 'pathFlags |= 4u;' in source
    eligibility = extract(source, 'offlineWaterGuideMix')
    assert '#ifdef CAUSTICA_OFFLINE_FP32' in eligibility and '#else' in eligibility and 'return 0.0;' in eligibility

contracts(world)
for old, new in [
    ('waterCelestialGuidedLeg = waterCelestialProtectLeg(chooseWaterGuide, waterGuideMix, nextGuidePdf);', 'waterCelestialGuidedLeg = chooseWaterGuide;'),
    ('surfaceContinuationPdf(n, v, lightDir, diffAlb, F0, rough, pbr, waterGuideMix, waterGuideNormal, waterGuideReflection)', 'surfaceBsdfPdf(n, v, lightDir, diffAlb, F0, rough, pbr)'),
    ('surfaceContinuationPdf(n, v, l, diffAlb, f0, rough, pbr, waterGuideMix, waterGuideNormal, waterGuideReflection)', 'surfaceBsdfPdf(n, v, l, diffAlb, f0, rough, pbr)'),
    ('payloadSectionSlot(), waterGuideMix, waterGuideNormal, waterGuideReflection, seed)', 'payloadSectionSlot(), 0.0, waterGuideNormal, waterGuideReflection, seed)'),
    ('if (bounce >= rrStart && !waterCelestialGuidedLeg)', 'if (bounce >= rrStart)'),
]:
    try:
        contracts(world.replace(old, new))
    except AssertionError:
        pass
    else:
        raise AssertionError('undetected integration bypass: ' + old)

preamble = r'''
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <random>
struct float2 {float x,y; float2(float a,float b):x(a),y(b){} };
struct float3 {float x,y,z; float3(float a=0):x(a),y(a),z(a){} float3(float a,float b,float c):x(a),y(b),z(c){} };
float3 operator+(float3 a,float3 b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
float3 operator-(float3 a,float3 b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
float3 operator*(float3 a,float b){return {a.x*b,a.y*b,a.z*b};}
float3 operator*(float b,float3 a){return a*b;}
float3 operator/(float3 a,float b){return a*(1/b);}
float2 operator*(float2 a,float b){return {a.x*b,a.y*b};}
float2 operator-(float2 a,float b){return {a.x-b,a.y-b};}
float dot(float3 a,float3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
float3 cross(float3 a,float3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
float3 normalize(float3 a){return a/std::sqrt(dot(a,a));}
float max(float a,float b){return std::max(a,b);}
float min(float a,float b){return std::min(a,b);}
float clamp(float x,float a,float b){return std::clamp(x,a,b);}
float abs(float x){return std::abs(x);}
float sqrt(float x){return std::sqrt(x);}
float tan(float x){return std::tan(x);}
void require(bool b,const char* msg){if(!b){std::cerr<<"FAIL "<<msg<<"\n";std::exit(1);}}
void near(double a,double b,double tol,const char* msg){require(std::isfinite(a)&&std::abs(a-b)<tol,msg);}
constexpr double PI=3.14159265358979323846;
constexpr float INV_PI=1/PI, WATER_IOR=1.333f;
struct PC {float3 lightDir,celestial;float halfAngle;} pc;
'''
energy = (ROOT / 'shaders/world/surface_energy.slang').read_text(encoding='utf-8')
production = '#define CAUSTICA_OFFLINE_FP32\n' + extract(energy, 'surfaceDiffuseTransmission') + '\n'
production += '\n'.join(extract(celestial, n) for n in [
    'celestialTangentHalfAngle', 'celestialPlanePdf', 'celestialFrame',
    'sampleCelestialSquare', 'celestialDirectionPdf'])
production += '\n' + '\n'.join(extract(proposal, n) for n in [
    'waterCelestialGuideHalfAngle', 'waterCelestialDirection', 'waterCelestialAirDirection', 'waterCelestialJacobian',
    'waterCelestialPdf', 'waterCelestialMixturePdf', 'waterCelestialGuideMix', 'waterCelestialProtectLeg'])
interface = (ROOT / 'shaders/world/interface_celestial.slang').read_text(encoding='utf-8')
production += '\n' + '\n'.join(extract(interface, n) for n in [
    'interfaceCelestialDirection', 'interfaceCelestialAirDirection', 'interfaceCelestialPdf'])
production += '\n' + '\n'.join(extract(world, n) for n in [
    'luminance', 'ggxD', 'ggxG1', 'surfaceSpecularProbability', 'surfaceBsdfPdf', 'surfaceSpecularPosterior', 'surfaceContinuationPdf'])
# These older planar-water cases supply the horizontal refraction context explicitly.
# The new actual-interface regression covers reflection and tilted contexts.
production += '''
float surfaceContinuationPdf(float3 n, float3 v, float3 l, float3 diffAlb,
                             float3 f0, float rough, bool pbr, float waterGuideMix) {
    return surfaceContinuationPdf(n,v,l,diffAlb,f0,rough,pbr,waterGuideMix,float3(0,1,0),false);
}
'''
production = production.replace('pc.lightDir.xyz', 'pc.lightDir').replace('pc.celestial.xyz', 'pc.celestial').replace('pc.lightDir.w', 'pc.halfAngle')
# Match Slang's float intermediates, not C++'s default double decimal literals.
production = re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])', r'\1f', production)
tests = r'''
float3 tracedWaterExit(float3 w,float eta){
 // HLSL/Slang refract(w,(0,-1,0),eta): use the incident cosine, as production does.
 float k=1.f-eta*eta*(1.f-w.y*w.y);
 return k>=0?float3(eta*w.x,std::sqrt(k),eta*w.z):float3(0);
}
double transmission(double cw,double eta) {
 double sa2=eta*eta*(1-cw*cw);if(sa2>=1)return 0;
 double ca=std::sqrt(1-sa2),rp=(cw-eta*ca)/(cw+eta*ca),rs=(eta*cw-ca)/(eta*cw+ca);
 return 1-(rp*rp+rs*rs)*.5;
}
int main(){
 const float eta=1.333f;float3 pole(0,0,1);
 near(waterCelestialGuideMix(false,.01f,.8f,1),0,1e-9,"dry gate");
 near(waterCelestialGuideMix(true,.01f,.8f,1),.5,1e-9,"wet gate");
 require(waterCelestialGuideMix(true,0,.8f,1)==0 && waterCelestialGuideMix(true,.01f,0,1)==0 && waterCelestialGuideMix(true,.01f,.8f,0)==0,"inactive/horizon gate");
 require(waterCelestialGuideMix(true,.01f,.05f,1)==0,"near-horizon FP32 gate");
 require(waterCelestialProtectLeg(true,.5f,0),"selected guide stays protected");
 require(waterCelestialProtectLeg(false,.5f,2000),"BSDF sample inside guide cone must be protected");
 require(!waterCelestialProtectLeg(false,.5f,0),"outside cone keeps old roulette");
 require(!waterCelestialProtectLeg(false,0,2000),"inactive guide keeps old roulette");
 // Enumerate two roulette steps rather than relying on a very rare MC survivor.
 // beta~8.49e-5: prior implementation multiplies a survivor by 2500, then hits bright sun.
 double beta=8.4902484e-5,le=47870.76;
 double oldBeta=beta,oldSurvival=1;
 for(int step=0;step<2;step++){double q=std::clamp(oldBeta,.02,1.);oldSurvival*=q;oldBeta/=q;}
 double newBeta=beta,newSurvival=1;
 for(int step=0;step<2;step++)if(!waterCelestialProtectLeg(false,.5f,2000)) {
  double q=std::clamp(newBeta,.02,1.);newSurvival*=q;newBeta/=q;
 }
 near(oldSurvival*oldBeta,beta,1e-12,"old roulette mean");
 near(newSurvival*newBeta,beta,1e-12,"new roulette mean");
 require(oldBeta/newBeta>2000,"remove repeated roulette amplification on supported base samples");
 near(newSurvival*newBeta*newBeta,std::pow(beta,2),1e-15,"zero conditional roulette variance");
 std::cout<<"supported BSDF solar leg: old survivor="<<oldBeta*le<<" new="<<newBeta*le<<" unchanged mean="<<beta*le<<"\n";
 require(dot(waterCelestialDirection({1,-.1f,0},eta),waterCelestialDirection({1,-.1f,0},eta))==0,"below horizon is null");
 require(dot(waterCelestialAirDirection({1,0,0},eta),waterCelestialAirDirection({1,0,0},eta))==0,"outside escape cone");
 for(float ca:{.05f,.3f,.8f,1.f}){
  float3 a(std::sqrt(1-ca*ca),ca,0),w=waterCelestialDirection(a,eta),back=waterCelestialAirDirection(w,eta);
  near(dot(w,w),1,2e-6,"unit refracted vector");
  near(back.x,a.x,3e-6,"Snell inverse x");near(back.y,a.y,3e-5,"Snell inverse y");
  double h=1e-4,theta=std::acos((double)ca);
  // Independent finite-difference area derivative sin(thetaW)dthetaW / sin(thetaA)dthetaA.
  if(ca<1){double twp=std::asin(std::sin(theta+h)/eta),twm=std::asin(std::sin(theta-h)/eta);
   double area=std::sin((twp+twm)*.5)*(twp-twm)/(2*h*std::sin(theta));
   near(1/waterCelestialJacobian(ca,w.y,eta),area,2e-6,"solid-angle Jacobian");}
 }
 // The full upper-hemisphere map covers the water escape cone; density integrates to one.
 double norm=0;int bins=500000;
 double critical=std::sqrt(1-1/((double)eta*eta));
 for(int i=0;i<bins;i++) {double t=(i+.5)/bins,cw=critical+(1-critical)*t*t;
  double ca=std::sqrt(std::max(0.,1-eta*eta*(1-cw*cw)));
  norm+=waterCelestialJacobian(ca,cw,eta)*2*(1-critical)*t/bins;}
 near(norm,1,2e-4,"normalized mapped hemisphere");
 std::mt19937 rng(314159);std::uniform_real_distribution<float> u(0,1);
 // Sample emitter boundaries deliberately, rather than waiting for rare bad edge samples.
 for(float ca:{.25f,.7f,.98f})for(float half:{.0001f,.010471976f,.15f}) {
  float3 axis(std::sqrt(1-ca*ca),ca,0);
  if(waterCelestialGuideMix(true,half,ca,1)==0)continue;
  for(int i=0;i<30000;i++){
   float edge=(i&1)?0.9999999f:0.0000001f,other=u(rng);
   float2 uv=(i&2)?float2(edge,other):float2(other,edge);
   float3 w=waterCelestialDirection(sampleCelestialSquare(axis,pole,half,uv),eta);
   float3 escaped=tracedWaterExit(w,eta);
   float radiance=celestialDirectionPdf(axis,pole,half,escaped);
   if(radiance>0)require(waterCelestialPdf(axis,pole,half,w,eta)>0,"actual traced solar hit must stay inside guide support");
  }
 }
 for(float ca:{.25f,.7f,.98f})for(int blocked:{0,1}) {
  float3 axis(std::sqrt(1-ca*ca),ca,0);float angle=.010471976f;
  double reference=0;int grid=240;
  // Independent double-precision quadrature over the solar tangent plane.
  // pole=(0,0,1), right=(ca,-axis.x,0), up=(0,0,-1).
  double t=std::tan((double)angle);
  for(int i=0;i<grid;i++)for(int j=0;j<grid;j++) {
   double x=(2*(i+.5)/grid-1)*t,z=(2*(j+.5)/grid-1)*t;
   double len=std::sqrt(1+x*x+z*z),ay=(ca-x*axis.x)/len;
   double ax=(axis.x+x*ca)/len,az=-z/len;
   if(ay<=0)continue;
   double wy=std::sqrt(1-(ax*ax+az*az)/(eta*eta));
   double jac=eta*eta*wy/ay;
   // Receiver albedo .7, solar integrated strength 1, Beer extinction .1 over depth 2.
   double visibility=(!blocked || az>0)?1:0;
   reference+=.7/PI*wy*transmission(wy,eta)*std::exp(-.2/wy)*visibility/jac/(grid*grid);
  }
  int count=600000;double sum=0,sq=0,oldSum=0,oldSq=0;
  for(int i=0;i<count;i++) {
   bool guided=u(rng)<.5;float3 w;
   if(guided) {float r1=u(rng),r2=u(rng);w=waterCelestialDirection(sampleCelestialSquare(axis,pole,waterCelestialGuideHalfAngle(angle),{r1,r2}),eta);}
   else {float r=std::sqrt(u(rng)),phi=2*PI*u(rng);w={r*std::cos(phi),std::sqrt(1-r*r),r*std::sin(phi)};}
   auto evaluate=[&](float3 d,bool mixed){
    float3 a=tracedWaterExit(d,eta);if(a.y<=0)return 0.;
    float light=celestialDirectionPdf(axis,pole,angle,a);if(light<=0 || (blocked && a.z<=0))return 0.;
    float base=d.y/PI,p=mixed?waterCelestialMixturePdf(base,waterCelestialPdf(axis,pole,angle,d,eta),.5f):base;
    if(u(rng)>transmission(d.y,eta))return 0.;
    return .7/PI*d.y*light*std::exp(-.2/d.y)/p;
   };
   double value=evaluate(w,true);sum+=value;sq+=value*value;
   float r=std::sqrt(u(rng)),phi=2*PI*u(rng);float3 old={r*std::cos(phi),std::sqrt(1-r*r),r*std::sin(phi)};
   double v=evaluate(old,false);oldSum+=v;oldSq+=v*v;
  }
  double mean=sum/count,var=sq/count-mean*mean,oldVar=oldSq/count-std::pow(oldSum/count,2);
  near(mean,reference,reference*.025,"guided mean versus independent integral");
  require(oldVar>var*100,"variance reduction for small sun");
  std::cout<<"sunCos="<<ca<<" halfBlocked="<<blocked<<" mean="<<mean<<" reference="<<reference<<" variance="<<var<<" oldVariance="<<oldVar<<"\n";
 }
 // Base support is retained away from the sun, including non-water/side-wall destinations.
 near(waterCelestialMixturePdf(.25f,0,.5f),.125,1e-7,"base support");
 near(waterCelestialMixturePdf(.25f,2,.5f),1.125,1e-7,"full mixture");
 near(waterCelestialMixturePdf(.25f,2,0),.25,1e-7,"unguided identity");
 pc.lightDir=normalize(float3(.5f,.8f,0));pc.celestial=pole;pc.halfAngle=.01f;
 float3 normal(0,1,0),view=normal,diff(.7f),f0(.04f);
 for(float rough:{.045f,.3f,1.f})for(float nl:{.1f,.8f,1.f}) {
  float3 d(std::sqrt(1-nl*nl),nl,0),h=normalize(view+d);
  double av=1-std::pow(1-1/std::sqrt(2.),5);
  double us=1-(1-f0.x)*av,ud=diff.x*(1-f0.x)*av/.8411881;
  double ps=us/(us+ud),alpha=(double)rough*rough,a2=alpha*alpha;
  double den=(1-h.y)*(1+h.y)+h.y*h.y*a2;
  double spec=ps*a2/(PI*den*den)/4;
  double diffuse=(1-ps)*nl/PI;
  near(surfaceSpecularPosterior(normal,view,d,diff,f0,rough),spec/(spec+diffuse),3e-6,"guided footprint preserves conditional old lobe distribution");
 }
 for(bool pbr:{false,true}) {
  float3 dir=waterCelestialDirection(pc.lightDir,eta);
  float base=surfaceBsdfPdf(normal,view,dir,diff,f0,.3f,pbr);
  float g=waterCelestialPdf(pc.lightDir,pole,.01f,dir,eta);
  near(surfaceContinuationPdf(normal,view,dir,diff,f0,.3f,pbr,.5f),.5*base+.5*g,.001,"actual PBR/Lambert continuation mixture");
  require(surfaceContinuationPdf(normal,view,{0,-1,0},diff,f0,.3f,pbr,.5f)==0,"receiver hemisphere");
 }
 // All non-solar directions retain the old support. Constant incident radiance integrates to albedo.
 double ambient=0,rrSum=0;int count=600000;
 for(int i=0;i<count;i++) {
  bool guided=u(rng)<.5;float3 d;
  if(guided){float u1=u(rng),u2=u(rng);d=waterCelestialDirection(sampleCelestialSquare(pc.lightDir,pole,waterCelestialGuideHalfAngle(.01f),{u1,u2}),eta);}
  else{float r=std::sqrt(u(rng)),phi=2*PI*u(rng);d={r*std::cos(phi),std::sqrt(1-r*r),r*std::sin(phi)};}
  double value=.7/PI*d.y/surfaceContinuationPdf(normal,view,d,diff,f0,1,false,.5f);
  ambient+=value;
  // Branch-dependent survival compensation: selected guides survive, base samples use RR.
  double survival=guided?1:.2;
  if(u(rng)<survival)rrSum+=value/survival;
 }
 near(ambient/count,.7,.004,"constant environment full support");
 near(rrSum/count,.7,.012,"branch-dependent compensated roulette mean");
 std::cout<<"PASS FP32 Snell/Jacobian, proposal normalization, six refracted-sun transport cases, source flow and five bypass controls\n";
}
'''
out = ROOT / 'build/water-celestial'
out.mkdir(parents=True, exist_ok=True)
compiler = 'D:/program/mingw64/bin/g++.exe'

def run(source, stem):
    cpp, exe = out / (stem + '.cpp'), out / (stem + '.exe')
    cpp.write_text(source, encoding='utf-8')
    subprocess.run([compiler, '-std=c++17', '-O2', str(cpp), '-o', str(exe)], check=True)
    return subprocess.run([str(exe)], capture_output=True, text=True)

source = preamble + production + tests
result = run(source, 'test')
print(result.stdout, end='')
assert result.returncode == 0, result.stderr
for label, old, new in [
    ('missing_jacobian', 'eta * eta * waterCos / airCos', '1.0f'),
    ('missing_mixture', '(1.0f - mix) * bsdfPdf + mix * guidePdf', 'bsdfPdf'),
    ('missing_edge_margin', '* 1.05f', '* 1.0f'),
    ('wrong_lobe_posterior', 'clamp(1.0f - diffuseMass / basePdf, 0.0f, 1.0f)', '0.0f'),
    ('selected_branch_only_roulette', 'selectedGuide || (mix > 0.0f && guidePdf > 0.0f)', 'selectedGuide'),
]:
    assert old in production, label
    mutant = run(preamble + production.replace(old, new) + tests, label)
    assert mutant.returncode != 0 and 'FAIL' in mutant.stderr, (label, mutant.stderr)
    print('PASS numerical negative control:', label)
