"""Fine-detail regression missing from the first display-denoiser experiment."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
context = {'__file__': str(ROOT/'scripts/test_offline_denoise.py')}
test = (ROOT/'scripts/test_offline_denoise.py').read_text(encoding='utf-8')
exec(compile(test[:test.index("r=execute(source,'kernel')")], context['__file__'], 'exec'), context)
helpers = context['fixtures'][:context['fixtures'].index('int main()')]
context['fixtures'] = helpers + r'''
int main(){
 setup(41,35,vec4(.5,.5,.5,1));
 for(int y=0;y<35;y++)for(int x=0;x<41;x++){
  float v=((x+y)%2)==0?.45f:.55f;inputImage.data[y*41+x]=vec4(v,v,v,1);
 }
 Image original=inputImage;auto result=run();
 float contrast=0;int count=0;
 for(int y=8;y<27;y++)for(int x=8;x<33;x++){
  contrast+=(result.data[y*41+x].x-.5f)*(((x+y)%2)==0?-1:1);count++;
 }
 float ratio=contrast/count/.05f;
 std::cout<<"stable low-contrast fine detail retained="<<ratio<<std::endl;
 check(ratio>.98f,"noise-free fine reflection detail must survive; first-hit guides are identical");
 setup(31,31,vec4(.05,.05,.05,1));int center=15*31+15;
 inputImage.data[center]=vec4(5,5,5,1);auto point=run();
 check(point.data[center].x>4.95f,"stable tiny genuine highlight must survive without a guide boundary");
 // Temporal convergence should restore contrast even with small residual noise.
 setup(41,35,vec4(.5,.5,.5,1));std::mt19937 rng(927);std::normal_distribution<float> noise(0,.005);
 for(int y=0;y<35;y++)for(int x=0;x<41;x++){
  float v=(((x+y)%2)==0?.45f:.55f)+noise(rng);int i=y*41+x;
  inputImage.data[i]=vec4(v,v,v,1);varianceAt(i,vec3(.000025));
 }
 auto residual=run();contrast=0;count=0;
 for(int y=8;y<27;y++)for(int x=8;x<33;x++){
  contrast+=(residual.data[y*41+x].x-.5f)*(((x+y)%2)==0?-1:1);count++;
 }
 std::cout<<"fine detail with residual noise retained="<<contrast/count/.05f<<std::endl;
 check(contrast/count/.05f>.97f,"low-noise fine detail must not be smoothed as heavily as grain");
 // Noisy neighbors must not change a center known to be stable.
 setup(31,31,vec4(.2,.2,.2,1));center=15*31+15;inputImage.data[center]=vec4(.3,.3,.3,1);
 for(int i=0;i<inputImage.data.size();i++)if(i!=center)varianceAt(i,vec3(.1));
 auto stable=run();check(stable.data[center].x==.3f,"stable center bypasses both passes exactly");
 for(float frames:{31.f,-1.f}){
  setup(31,31,vec4(.05,.05,.05,1));inputImage.data[center]=vec4(5,5,5,1);
  for(int i=0;i<inputImage.data.size();i++)momentImage.data[i]=vec4(100000,100000,100000,frames);
  auto unknown=run();check(unknown.data[center].x==5.f,"insufficient or invalid statistics must not erase details");
 }
 setup(31,31,vec4(.05,.05,.05,1));inputImage.data[center]=vec4(5,5,5,1);
 momentImage.data[center]=vec4(25*31*64,25*31*64,25*31*64,32);
 auto enough=run();check(enough.data[center].x<.2f,"32 frames enable statistically uncertain peak rejection");
 std::cout<<"PASS stable fine detail and true point highlights\n";
}
'''
r=context['execute'](context['source'],'detail')
print(r.stdout)
assert r.returncode==0,r.stderr
mutated=re.sub(r'vec3 meanVariance\(.*?\n\}', 'vec3 meanVariance(ivec2 pixel) { return vec3(0.01);\n}',context['source'],count=1,flags=re.S)
assert mutated!=context['source']
r=context['execute'](mutated,'detail_fixed_strength')
assert r.returncode!=0,'fixed-strength smoothing must fail stable detail preservation'
print('PASS rejected fixed-strength noise assumption:',r.stderr.strip())
