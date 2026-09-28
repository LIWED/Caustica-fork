"""Audit actual FP32 GGX vector sampling against independent double integrals.

This is a CPU probability/weight test, not a GPU rendering or scene convergence
test. Production function bodies are extracted on every run. Null below-surface
samples retain zero contribution; they are never resampled or renormalized.
"""
from pathlib import Path
import ast
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
world = (ROOT / 'shaders/world/world.rgen.slang').read_text(encoding='utf-8')
energy = (ROOT / 'shaders/world/surface_energy.slang').read_text(encoding='utf-8')


def extract(source, name):
    match = re.search(r'(?:public\s+)?(?:float3|float|uint)\s+' + name + r'\([^)]*\)\s*\{', source)
    assert match, name
    end, depth = match.end(), 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end].replace('public ', '').replace('inout uint ', 'uint& ')


# Reuse only the FP32 vector shim, without executing the water test contracts.
tree = ast.parse((ROOT / 'scripts/test_water_celestial.py').read_text(encoding='utf-8'))
preamble = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == 'preamble' for t in node.targets))
preamble = preamble.replace('float x,y,z;', 'union {struct {float x,y,z;}; struct {float r,g,b;};};')
preamble = preamble.replace('constexpr double PI=', 'constexpr float PI=')
preamble += r'''
#include <cstdint>
#include <iomanip>
using uint=uint32_t;
float3 operator*(float3 a,float3 b){return {a.x*b.x,a.y*b.y,a.z*b.z};}
float3& operator*=(float3& a,float3 b){a=a*b;return a;}
float3& operator+=(float3& a,float3 b){a=a+b;return a;}
float rsqrt(float a){return 1.f/std::sqrt(a);}
float sin(float a){return std::sin(a);}
float cos(float a){return std::cos(a);}
float3 reflect(float3 i,float3 n){return i-2.f*dot(i,n)*n;}
#define CAUSTICA_OFFLINE_FP32
'''
production = '\n'.join(extract(energy, n) for n in [
    'surfaceDiffuseTransmission', 'surfaceDiffuseEnergyBudget'])
production += '\n' + '\n'.join(extract(world, n) for n in [
    'pcg', 'rndf', 'luminance', 'ggxD', 'ggxG1', 'fresnelSchlick',
    'cosineDir', 'sampleGGXVNDF', 'surfaceSpecularProbability', 'evaluateSurfaceBrdf', 'surfaceBsdfPdf',
    'surfaceSpecularPosterior'])
production = re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])', r'\1f', production)

tests = r'''
struct Stats {
 double sum=0,sq=0,largest=0;int count=0;
 void add(double x){require(std::isfinite(x)&&x>=0,"finite nonnegative sample");sum+=x;sq+=x*x;largest=std::max(largest,x);count++;}
 double mean()const{return sum/count;}
 double se()const{return std::sqrt(std::max(0.,sq/count-mean()*mean())/count);}
};
struct Reference {double accept=0,moment=0,spec[3]={0,0,0};};
constexpr double DOUBLE_PI=3.14159265358979323846;
// Independent double quadrature: sample the projected NDF using slope radius
// alpha*sqrt(t/(1-t)). Multiply by G1(V)*max(V.H,0)/(NoV*NoH) for the VNDF.
// t=1-(1-u)^2 resolves the NDF tail; no production PDF/BRDF/sampler is used.
double g1(double c,double alpha){return 2*c/(c+std::sqrt(alpha*alpha+(1-alpha*alpha)*c*c));}
Reference reference(double rough,double nv){
 Reference q;double a=rough*rough,vx=std::sqrt(1-nv*nv),gv=g1(nv,a);
 constexpr int nt=768,np=768;
 for(int i=0;i<nt;i++){
  double u=(i+.5)/nt,t=1-(1-u)*(1-u),slope=a*std::sqrt(t/(1-t));
  double hz=1/std::sqrt(1+slope*slope),hr=slope*hz;
  for(int j=0;j<np;j++){
   double hx=hr*std::cos(2*DOUBLE_PI*(j+.5)/np),vh=vx*hx+nv*hz;
   double nl=2*vh*hz-nv;
   if(vh<=0||nl<=0)continue;
   double mass=gv*vh/(nv*hz)*2*(1-u)/(nt*np);
   q.accept+=mass;q.moment+=mass*nl;
   double m=1-vh,schlick=m*m*m*m*m,gl=g1(nl,a);
   for(int k=0;k<3;k++){
    double f0=k==0?.04:(k==1?.9:1.);
    q.spec[k]+=mass*gl*(f0+(1-f0)*schlick);
   }
  }
 }
 return q;
}
double transmission(double c){c=std::clamp(c,0.,1.);double m=c/std::sqrt(2*(1+std::sqrt((1-c)*(1+c))));return 1-std::pow(1-m,5);}
void frame(float3 n,float3& t,float3& b){t=std::abs(n.x)>.9f?float3(0,1,0):float3(1,0,0);b=normalize(cross(n,t));t=cross(b,n);}
int main(){
 std::cout<<std::setprecision(8);
 const float roughness[]={.045f,.08f,.2f,.4f,.7f,1.f};
 const float views[]={.0001f,.005f,.05f,.3f,.8f,1.f};
 const float3 normals[]={float3(0,0,1),normalize(float3(.36f,.8f,-.48f)),normalize(float3(.96f,.2f,.19f))};
 uint seed=713579u;int cases=0;double largestWeight=0,largestMean=0,largestRefError=0;
 constexpr int count=120000;
 for(float rough:roughness)for(float nv:views){
  Reference ref=reference(rough,nv);
  require(ref.accept<=1.0001,"independent VNDF integral mass <= 1");
  for(float3 n:normals){
   float3 t,b;frame(n,t,b);float3 v=normalize(t*std::sqrt(1-nv*nv)+n*nv);
   float actualNv=dot(n,v);require(actualNv>0,"valid incoming test direction");
   // Test actual vector sampler separately from the surface mixture. Frequencies
   // and first direction moments include the null mass below the surface.
   Stats accepted,moment;
   for(int i=0;i<count;i++){
    float3 h=sampleGGXVNDF(n,v,rough,seed),l=reflect(v*-1.f,h);
    require(std::isfinite(dot(h,h)),"finite VNDF half vector");
    near(dot(h,h),1,8e-7,"unit half vector");near(dot(l,l),1,2e-6,"unit reflected vector");
    require(dot(n,h)>=-2e-7f&&dot(v,h)>=-2e-7f,"visible upper microfacet");
    float nl=dot(n,l);accepted.add(nl>0?1:0);moment.add(std::max(0.f,nl));
   }
   near(accepted.mean(),ref.accept,7*accepted.se()+.001,"VNDF accepted mass versus double NDF quadrature");
   near(moment.mean(),ref.moment,7*moment.se()+.001,"VNDF direction moment versus double NDF quadrature");
   for(int material=0;material<3;material++){
    float f0=material==0?.04f:(material==1?.9f:1.f),diff=material==0?1.f:0.f;
    float3 alb(diff),f(f0);float ps=surfaceSpecularProbability(n,v,alb,f);
    Stats weights;
    for(int i=0;i<count;i++){
     bool specular=rndf(seed)<ps;
     float3 l=specular?reflect(v*-1.f,sampleGGXVNDF(n,v,rough,seed)):cosineDir(n,seed);
     float nl=dot(n,l);if(nl<=0){weights.add(0);continue;}
     float pdf=surfaceBsdfPdf(n,v,l,alb,f,rough,true);
     require(std::isfinite(pdf)&&pdf>0,"sampled direction has finite positive mixture PDF");
     float3 brdf=evaluateSurfaceBrdf(n,v,l,alb,f,rough,true);
     float w=brdf.x*nl/pdf;
     // Independent algebraic bound: each component f*cos/p_i is bounded,
     // then divided by its mixture selection probability. A rare spike above
     // this bound is a weight/probability error, not ordinary Monte Carlo noise.
     double bound=std::max(1./ps,ps<1?double(diff*(1-f0)*transmission(actualNv)/(.8411881f*(1-ps))):0.);
     require(w<=bound*(1+2e-5),"sample weight obeys analytic mixture bound");
     near(surfaceSpecularPosterior(n,v,l,alb,f,rough),
          1-(1-ps)*nl*INV_PI/pdf,2e-6,"ray-cone lobe posterior uses same mixture density");
     weights.add(w);
    }
    double expected=ref.spec[material]+diff*(1-f0)*transmission(actualNv)*(.841187953129277792/.8411881f);
    double error=std::abs(weights.mean()-expected);
    if(error>=7*weights.se()+.002)std::cerr<<"case rough="<<rough<<" NoV="<<nv<<" normal="<<n.x<<","<<n.y<<","<<n.z<<" material="<<material<<" mean="<<weights.mean()<<" expected="<<expected<<" se="<<weights.se()<<"\n";
    near(weights.mean(),expected,7*weights.se()+.002,"white furnace mean versus independent double integral");
    require(weights.mean()<=1+7*weights.se()+.002,"white furnace expected energy <= 1");
    largestWeight=std::max(largestWeight,weights.largest);largestMean=std::max(largestMean,weights.mean());largestRefError=std::max(largestRefError,error);
    cases++;
   }
  }
  std::cout<<"rough="<<rough<<" NoV="<<nv<<" acceptedReference="<<ref.accept<<" whiteMetalReference="<<ref.spec[2]<<"\n";
 }
 // Nonpositive incoming cosines must never produce a valid PBR weight.
 for(float3 n:normals)for(float side:{-1.f,0.f}){
  float3 t,b;frame(n,t,b);float3 v=side<0?n*-1.f:t;
  if(side==0&&dot(n,v)>0)v=v-n*(dot(n,v)+1e-7f);
  for(float rough:roughness){
   require(surfaceBsdfPdf(n,v,n,float3(1),float3(.04f),rough,true)==0,"invalid incoming cosine PDF gate");
   require(evaluateSurfaceBrdf(n,v,n,float3(1),float3(.04f),rough,true).x==0,"invalid incoming cosine BRDF gate");
  }
 }
 std::cout<<"PASS "<<cases<<" FP32 vector-mixture cases; maximum sample weight="<<largestWeight
          <<" maximum furnace mean="<<largestMean<<" maximum independent reference error="<<largestRefError<<"\n";
}
'''

output = ROOT / 'build/bsdf-vector-sampling'
output.mkdir(parents=True, exist_ok=True)
source = output / 'test.cpp'
executable = output / 'test.exe'
source.write_text(preamble + production + tests, encoding='utf-8')
subprocess.run(['D:/program/mingw64/bin/g++.exe', '-std=c++17', '-O2', '-ffp-contract=off',
                str(source), '-o', str(executable)], check=True)
subprocess.run([str(executable)], check=True)

# Demonstrate that the numerical checks reject real sampler/PDF mismatches.
# Mutants exist only in generated CPU test files, never in production shaders.
sampler = extract(world, 'sampleGGXVNDF')
sampler = re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])', r'\1f', sampler)
for label, broken in [
    ('wrong_specular_pdf', production.replace('ps * specularPdf', '0.5f * ps * specularPdf')),
    ('wrong_sampler_alpha', production.replace(sampler, sampler.replace('float a = rough * rough;', 'float a = rough;'))),
]:
    assert broken != production, label
    mutant_source = output / (label + '.cpp')
    mutant_executable = output / (label + '.exe')
    mutant_source.write_text(preamble + broken + tests, encoding='utf-8')
    subprocess.run(['D:/program/mingw64/bin/g++.exe', '-std=c++17', '-O2', '-ffp-contract=off',
                    str(mutant_source), '-o', str(mutant_executable)], check=True)
    result = subprocess.run([str(mutant_executable)], capture_output=True, text=True)
    assert result.returncode != 0 and 'FAIL' in result.stderr, (label, result.stdout, result.stderr)
    print('PASS numerical negative control:', label, result.stderr.strip())
