"""Extract production FP32 policy/BSDF; test a two-stage indirect-light estimator.

Analytic geometry: a Lambert receiver sees a uniform metallic reflecting plane.
The plane sees a small uniform circular emitter, with no occlusion. This measures
ordinary indirect variance and brightness changes, NOT a Minecraft/GPU render.
"""
from pathlib import Path
import ast
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
policy_path = ROOT / 'shaders/world/indirect_regularization.slang'
assert policy_path.exists(), 'FAIL: missing production indirect regularization policy'

# Reuse the production extraction and FP32 shim, without executing the old audit.
audit = ast.parse((ROOT / 'scripts/test_bsdf_vector_sampling.py').read_text(encoding='utf-8'))
prefix = []
for node in audit.body:
    if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'tests' for t in node.targets):
        reference_tests = ast.literal_eval(node.value)
        break
    prefix.append(node)
context = {'__file__': str(ROOT / 'scripts/test_bsdf_vector_sampling.py')}
exec(compile(ast.Module(body=prefix, type_ignores=[]), str(__file__), 'exec'), context)
extract = context['extract']
policy = extract(policy_path.read_text(encoding='utf-8'), 'regularizedPathRoughness')
policy = re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])', r'\1f', policy)
reference = reference_tests[reference_tests.index('struct Reference'):reference_tests.index('double transmission')]
tests = r'''
struct Moments {
 double sum=0, sq=0, peak=0; int count=0;
 void add(double x){require(std::isfinite(x)&&x>=0,"finite contribution");sum+=x;sq+=x*x;peak=std::max(peak,x);count++;}
 double mean()const{return sum/count;}
 double var()const{return std::max(0.,sq/count-mean()*mean());}
};
float3 emitter(float c, uint& seed, double cosRadius){
 float3 axis(std::sqrt(1-c*c),0,c),t(c,0,-std::sqrt(1-c*c)),b(0,1,0);
 double z=1-(1-cosRadius)*rndf(seed),r=std::sqrt(1-z*z),phi=2*DOUBLE_PI*rndf(seed);
 return normalize(axis*float(z)+t*float(r*std::cos(phi))+b*float(r*std::sin(phi)));
}
double mis(double a,double b){return a*a/(a*a+b*b);}
int main(int argc,char** argv){
 for(float rough:{.045f,.08f,.2f,.4f,.7f,1.f})for(uint mode:{0u,1u,2u}){
  require(regularizedPathRoughness(rough,false,mode)==rough,"primary and ideal-only chain unchanged");
  require(regularizedPathRoughness(rough,true,0)==rough,"reference unchanged");
  float effective=regularizedPathRoughness(rough,true,mode);
  require(effective>=rough&&effective<=1,"bounded nondecreasing roughness");
  if(rough*rough>=.3f)require(effective==rough,"already rough unchanged");
 }
 require(std::abs(regularizedPathRoughness(.045f,true,1)-.2f)<1e-6f,"mild alpha floor");
 require(std::abs(regularizedPathRoughness(.045f,true,2)-std::sqrt(.1f))<1e-6f,"strong alpha floor");
 require(std::abs(regularizedPathRoughness(.4f,true,2)-std::sqrt(.3f))<1e-6f,"alpha ceiling");
 if(argc>1)return 0;
 std::cout<<std::setprecision(10);
 constexpr int samples=1500000;
 const double cosRadius=std::cos(.0025),lightPdf=1/(2*DOUBLE_PI*(1-cosRadius));
 float3 n(0,0,1),diff(0),f0(.9f);
 for(float authored:{.045f,.2f})for(float lightCos:{.8f,.15f})for(uint mode:{0u,1u,2u}){
  float rough=regularizedPathRoughness(authored,true,mode);
  Moments m;uint seed=937651u;
  float3 axis(std::sqrt(1-lightCos*lightCos),0,lightCos);
  for(int i=0;i<samples;i++){
   // The receiver's cosine sample is the view direction at the parallel mirror.
   float3 v=cosineDir(n,seed),l=emitter(lightCos,seed,cosRadius);
   float ps=surfaceSpecularProbability(n,v,diff,f0);
   float p=surfaceBsdfPdf(n,v,l,diff,f0,rough,true);
   double value=evaluateSurfaceBrdf(n,v,l,diff,f0,rough,true).x*l.z*mis(lightPdf,p);
   float3 direction;
   if(rndf(seed)<ps){float3 h=sampleGGXVNDF(n,v,rough,seed);direction=reflect(v*-1.f,h);}
   else direction=cosineDir(n,seed);
   float pdf=surfaceBsdfPdf(n,v,direction,diff,f0,rough,true);
   // Use double for the tiny emitter support test, to avoid float dot-rounding at its edge.
   double dotLight=double(direction.x)*axis.x+double(direction.y)*axis.y+double(direction.z)*axis.z;
   if(pdf>0&&dotLight>=cosRadius){
    double f=evaluateSurfaceBrdf(n,v,direction,diff,f0,rough,true).x;
    value+=f*direction.z/pdf*lightPdf*mis(pdf,lightPdf);
   }
   m.add(value);
  }
  // Independent double NDF quadrature. The central-direction approximation to
  // this tiny circular emitter has a small angular integration error; allow it
  // explicitly rather than calling this an exact finite-emitter ground truth.
  double ref=reference(rough,lightCos).spec[1]*lightCos/DOUBLE_PI;
  double se=std::sqrt(m.var()/samples);
  require(std::abs(m.mean()-ref)<8*se+.003*ref,"mean agrees with independent small-emitter reference");
  std::cout<<authored<<","<<lightCos<<","<<mode<<","<<rough<<","<<m.mean()<<","<<ref<<","<<m.var()<<","<<m.peak<<","<<se<<"\n";
 }
}
'''
output = ROOT / 'build/indirect-regularization'
output.mkdir(parents=True, exist_ok=True)
cpp, exe = output / 'experiment.cpp', output / 'experiment.exe'
cpp.write_text(context['preamble'] + context['production'] + policy + reference + tests, encoding='utf-8')
compiler = 'D:/program/mingw64/bin/g++.exe'
subprocess.run([compiler, '-std=c++17', '-O2', '-ffp-contract=off', str(cpp), '-o', str(exe)], check=True)
run = subprocess.run([str(exe)], text=True, capture_output=True)
assert run.returncode == 0, (run.stdout, run.stderr)
rows = []
for line in run.stdout.splitlines():
    values = list(map(float, line.split(',')))
    rows.append(dict(zip(['authored_roughness', 'light_cosine', 'mode', 'effective_roughness',
                          'mean', 'reference_approx', 'variance', 'peak', 'standard_error'], values)))
assert len(rows) == 12, run.stdout
for start in range(0, len(rows), 3):
    baseline = rows[start]
    for row in rows[start:start + 3]:
        row['variance_reduction'] = baseline['variance'] / row['variance']
        row['reference_mean_shift_percent'] = 100 * (row['reference_approx'] / baseline['reference_approx'] - 1)
(output / 'results.json').write_text(json.dumps({'samples_per_case': 1500000,
    'scope': 'CPU analytic two-stage planar scene; finite-emitter reference uses central-direction approximation',
    'cases': rows}, indent=2), encoding='utf-8')
print(run.stdout)

# Negative control: smoothing the first visible surface must fail even if it reduces variance.
broken = policy.replace('!hasNonDeltaBounce || ', '')
assert broken != policy
mutant_cpp, mutant_exe = output / 'global_roughening.cpp', output / 'global_roughening.exe'
mutant_cpp.write_text(context['preamble'] + context['production'] + broken + reference + tests, encoding='utf-8')
subprocess.run([compiler, '-std=c++17', '-O2', str(mutant_cpp), '-o', str(mutant_exe)], check=True)
mutant = subprocess.run([str(mutant_exe), 'policy-only'], text=True, capture_output=True)
assert mutant.returncode != 0 and 'primary and ideal-only chain unchanged' in mutant.stderr, mutant
print('PASS: extracted policy, 12 transport cases, and global-roughening negative control')
