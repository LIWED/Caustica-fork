"""Numerically check energy-aware mixture allocation without changing the BRDF."""
import ast
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
world = (ROOT/'shaders/world/world.rgen.slang').read_text(encoding='utf-8')
assert 'float surfaceSpecularProbability(' in world, 'FAIL: missing energy-aware lobe probability'
assert world.count('float ps = surfaceSpecularProbability(n, v, diffAlb,') == 3, 'sampler, PDF, posterior must share one probability'
audit = ast.parse((ROOT/'scripts/test_bsdf_vector_sampling.py').read_text(encoding='utf-8'))
prefix = []
for node in audit.body:
    if isinstance(node, ast.Assign) and any(isinstance(t,ast.Name) and t.id=='tests' for t in node.targets):
        old_tests = ast.literal_eval(node.value)
        break
    prefix.append(node)
ctx = {'__file__':str(ROOT/'scripts/test_bsdf_vector_sampling.py')}
exec(compile(ast.Module(body=prefix,type_ignores=[]),str(__file__),'exec'),ctx)
reference = old_tests[old_tests.index('struct Reference'):old_tests.index('void frame')]
tests = r'''
struct Stats {double sum=0,sq=0,peak=0;int count=0;
 void add(double x){require(std::isfinite(x)&&x>=0,"finite weight");sum+=x;sq+=x*x;peak=std::max(peak,x);count++;}
 double mean()const{return sum/count;} double var()const{return std::max(0.,sq/count-mean()*mean());}
 double se()const{return std::sqrt(var()/count);}
};
float oldProbability(float3 d,float3 f){return clamp(luminance(f)/(luminance(f)+luminance(d)+1e-4f),.1f,.9f);}
double scalarPdf(float3 n,float3 v,float3 l,float rough,double ps){
 if(l.z<=0)return 0;float3 h=normalize(v+l);
 return (1-ps)*l.z/DOUBLE_PI+ps*ggxD(dot(n,h),rough)*ggxG1(v.z,rough)/(4*v.z);
}
int main(){
 std::cout<<std::setprecision(10);
 const float3 n(0,0,1);constexpr int samples=200000;
 float3 capturedView(std::sqrt(1-.55f*.55f),0,.55f);
 require(surfaceSpecularProbability(n,capturedView,float3(.2f,.9f,.8f),float3(.85882354f))>.8f,
         "captured high-F0 allocation must avoid old near-half specular selection");
 // High-F0 dielectric with colored diffuse from the captured room, metals,
 // ordinary/zero-F0 surfaces, and distinct colored lobes test RGB support.
 const float3 albs[]={float3(.2f,.9f,.8f),float3(0),float3(1),float3(1),float3(.2f,.9f,.8f)};
 const float3 f0s[]={float3(.85882354f),float3(.9f),float3(.04f),float3(0),float3(.95f,.04f,.3f)};
 for(float nv:{.01f,.55f,.85f})for(float rough:{.1f,.31622777f,1.f}){
  float3 v(std::sqrt(1-nv*nv),0,nv);Reference ref=reference(rough,nv);
  for(int mat=0;mat<5;mat++){
   float3 alb=albs[mat],f0=f0s[mat];double a=transmission(nv),u=0,d=0;
   for(int c=0;c<3;c++){double f=(&f0.x)[c],al=(&alb.x)[c];u=std::max(u,1-(1-f)*a);d=std::max(d,al*(1-f)*a/.8411881);}
   float ps=surfaceSpecularProbability(n,v,alb,f0),old=oldProbability(alb,f0);
   require(ps>0&&ps<=1,"valid specular support");
   if(d>0)require(ps<1,"nonzero diffuse support");else require(ps==1,"no wasted diffuse draw for pure metal");
   double bound=std::max(u/ps,d>0?d/(1-ps):0.);
   if(mat==0&&nv>=.55f)require(ps>.8f&&bound<1.05,"captured high-F0 state avoids doubled path weights");
   Stats stats[2][3];
   for(int which=0;which<2;which++){
    uint seed=994359u;float prob=which==0?old:ps;
    for(int i=0;i<samples;i++){
     float3 l=rndf(seed)<prob?reflect(v*-1.f,sampleGGXVNDF(n,v,rough,seed)):cosineDir(n,seed);
     float3 weight(0);
     if(l.z>0){
      double pdf=which==0?scalarPdf(n,v,l,rough,old):surfaceBsdfPdf(n,v,l,alb,f0,rough,true);
      require(pdf>0,"positive sampled density");
      weight=evaluateSurfaceBrdf(n,v,l,alb,f0,rough,true)*float(l.z/pdf);
      if(which==1){
       require(std::max({weight.x,weight.y,weight.z})<=bound*(1+4e-5),"new sample obeys component bound");
       double expected=1-(1-ps)*l.z/DOUBLE_PI/pdf;
       near(surfaceSpecularPosterior(n,v,l,alb,f0,rough),expected,5e-6,"posterior matched to mixture");
      }
     }
     for(int c=0;c<3;c++)stats[which][c].add((&weight.x)[c]);
    }
    for(int c=0;c<3;c++){
     double f=(&f0.x)[c],al=(&alb.x)[c];
     // GGX reflection is affine in F0; independently integrated F0=.04 and1.
     double spec=ref.spec[0]+(f-.04)/.96*(ref.spec[2]-ref.spec[0]);
     double expected=spec+al*(1-f)*a*.841187953129277792/.8411881;
     near(stats[which][c].mean(),expected,7*stats[which][c].se()+.002,"unchanged independent RGB mean");
    }
   }
   if(mat==0&&nv>=.55f&&rough<.4f){
    require(stats[1][1].var()<stats[0][1].var()*.35,"variance reduced on captured reflective material");
   }
   std::cout<<nv<<","<<rough<<","<<mat<<","<<old<<","<<ps<<","<<stats[0][1].mean()<<","<<stats[1][1].mean()<<","<<stats[0][1].var()<<","<<stats[1][1].var()<<","<<stats[0][1].peak<<","<<stats[1][1].peak<<"\n";
  }
 }
}
'''
out=ROOT/'build/surface-lobe-sampling';out.mkdir(parents=True,exist_ok=True)
source,exe=out/'test.cpp',out/'test.exe'
source.write_text(ctx['preamble']+ctx['production']+reference+tests,encoding='utf-8')
compiler='D:/program/mingw64/bin/g++.exe'
subprocess.run([compiler,'-std=c++17','-O2','-ffp-contract=off',str(source),'-o',str(exe)],check=True)
run=subprocess.run([str(exe)],capture_output=True,text=True)
assert run.returncode==0,(run.stdout,run.stderr)
rows=[dict(zip(['NoV','roughness','material','oldProbability','newProbability','oldMeanG','newMeanG','oldVarianceG','newVarianceG','oldPeakG','newPeakG'],map(float,line.split(',')))) for line in run.stdout.splitlines()]
assert len(rows)==45
(out/'results.json').write_text(json.dumps({'samples_per_proposal_case':200000,'cases':rows},indent=2),encoding='utf-8')
for r in rows:
    if r['material']==0 and r['NoV']>.5 and r['roughness']<.4:print(r)
print('PASS 45 RGB cases, old/new independent means, component bounds and variance checks')

# Keep the PDF and sampler matched, but restore the old allocation: the targeted
# regression must reject its large per-step amplification, not a syntax error.
fn=ctx['extract'](world,'surfaceSpecularProbability')
import re
fn=re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])',r'\1f',fn)
legacy='float surfaceSpecularProbability(float3 n,float3 v,float3 diffAlb,float3 f0){ return clamp(luminance(f0)/(luminance(f0)+luminance(diffAlb)+1e-4f),.1f,.9f); }'
broken=ctx['production'].replace(fn,legacy);assert broken!=ctx['production']
source=out/'old_allocation.cpp';exe=out/'old_allocation.exe'
source.write_text(ctx['preamble']+broken+reference+tests,encoding='utf-8')
subprocess.run([compiler,'-std=c++17','-O2',str(source),'-o',str(exe)],check=True)
bad=subprocess.run([str(exe)],capture_output=True,text=True)
assert bad.returncode!=0 and 'captured high-F0 allocation' in bad.stderr,(bad.stdout,bad.stderr)
print('PASS old allocation negative control:',bad.stderr.strip())
