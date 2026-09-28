"""Actual GPU accumulation kernel executed via CPU image shim, with independent references."""
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
context={'__file__':str(ROOT/'scripts/test_offline_denoise.py')}
t=(ROOT/'scripts/test_offline_denoise.py').read_text(encoding='utf-8')
exec(compile(t[:t.index("r=execute(source,'kernel')")],context['__file__'],'exec'),context)
source=(ROOT/'shaders/display/offline_accumulate.comp').read_text(encoding='utf-8')
assert 'momentImage' in source,'FAIL: accumulation has no measured temporal moments'
source=source.replace('pc.', 'accumPc.')
context['shim']+=r'''
using uint=unsigned int;
bool greaterThanEqual(ivec2 a,ivec2 b){return a.x>=b.x||a.y>=b.y;}
bool any(bool b){return b;}
vec4 operator+(vec4 a,vec4 b){return {a.x+b.x,a.y+b.y,a.z+b.z,a.w+b.w};}
vec4 operator*(vec4 a,float b){return {a.x*b,a.y*b,a.z*b,a.w*b};}
vec4 operator/(vec4 a,float b){return {a.x/b,a.y/b,a.z/b,a.w/b};}
Image currentImage,historyImage;
struct AccumPush {uint previousSamples,currentSamples,resetHistory;} accumPc;
'''
context['fixtures']=r'''
void check(bool x,const char* m){if(!x)throw std::runtime_error(m);}
void init(){currentImage=Image(1,1);historyImage=Image(1,1);momentImage=Image(1,1);resolvedImage=Image(1,1);gl_GlobalInvocationID.p={0,0};}
void push(float value,uint w,uint total,bool reset){currentImage.data[0]=vec4(value,value*.5f,value*2,1);accumPc={total,w,uint(reset)};kernel();}
int main(){
 init();double sum=0,sum2=0;unsigned W=0;int K=0;float previousMean=0;
 for(int i=0;i<100;i++){
  unsigned w=1+i%7;float x=.7f+float(i%9)*.013f;
  float legacy=W==0?x:(previousMean*float(W)+x*float(w))/float(W+w);
  push(x,w,W,i==0);W+=w;K++;sum+=w*double(x);sum2+=w*double(x)*x;previousMean=legacy;
  check(historyImage.data[0].x==legacy,"raw mean must remain bit-exact to old formula");
  double reference=sum2-sum*sum/W;
  check(abs(momentImage.data[0].x-reference)<2e-5,"weighted M2 mismatch independent batch reference");
  check(momentImage.data[0].w==K,"frame count must count batches, not samples");
 }
 push(2,3,W,true);check(momentImage.data[0].x==0&&momentImage.data[0].w==1&&historyImage.data[0].x==2,"reset must clear moments and mean together");
 push(3,1,16777208,false);check(momentImage.data[0].w<0,"capped running mean must invalidate exact-mean statistics");
 init();push(1e30f,1,0,true);push(0,1,1,false);check(momentImage.data[0].w<0,"overflow statistics must disable reconstruction without contaminating history");
 init();push(NAN,1,0,true);check(momentImage.data[0].w<0,"nonfinite first sample must invalidate statistics");
 init();push(.5f,1,0,true);push(NAN,1,1,false);check(momentImage.data[0].w<0,"NaN update must not be hidden by clamp");
 init();push(-INFINITY,1,0,true);check(momentImage.data[0].w<0,"negative infinity must invalidate statistics");
 init();push(2e37f,32,0,true);push(2e37f,32,32,false);check(momentImage.data[0].w<0,"raw mean product overflow must invalidate statistics");
 // Repeated independent experiments with Var(batch mean)=sigma^2/w.
 std::mt19937 rng(721);std::normal_distribution<float> gaussian(0,1);
 double est=0,meanSum=0,meanSq=0;const int trials=4000;
 for(int trial=0;trial<trials;trial++){
  init();unsigned total=0;for(int k=0;k<64;k++){unsigned w=1+k%7;push(2.f+.5f*gaussian(rng)/sqrt(float(w)),w,total,k==0);total+=w;}
  float m=historyImage.data[0].x;meanSum+=m;meanSq+=double(m)*m;est+=momentImage.data[0].x/(63.f*total);
 }
 double empirical=(meanSq-meanSum*meanSum/trials)/(trials-1),estimate=est/trials;
 check(abs(estimate/empirical-1)<.06,"estimated mean variance must match independent repeated experiments");
 std::cout<<"PASS raw mean unchanged, weighted statistics/reset/cap/overflow; variance estimate="<<estimate<<", measured="<<empirical<<"\n";
}
'''
r=context['execute'](source,'moments')
print(r.stdout)
assert r.returncode==0,r.stderr
