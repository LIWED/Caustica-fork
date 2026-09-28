"""Execute the production GLSL kernel on CPU images; not a Vulkan quality claim."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
shader_path = ROOT / 'shaders/display/offline_denoise.comp'
assert shader_path.exists(), 'FAIL: offline display denoiser is missing'
source = shader_path.read_text(encoding='utf-8')
out = ROOT / 'build/offline-denoise'
out.mkdir(parents=True, exist_ok=True)

# Only API/type spelling changes; the complete algorithm and dispatch branch are production code.
def translate(s):
    s = re.sub(r'#version[^\n]*', '', s)
    s = re.sub(r'layout\(push_constant\) uniform Push \{.*?\} pc;', '', s, flags=re.S)
    s = re.sub(r'layout[^\n]*', '', s)
    s = s.replace('void main()', 'void kernel()')
    s = s.replace('.rgb', '.rgb()').replace('.xyz', '.xyz()').replace('.xy', '.xy()')
    # xyz() must not be rewritten by xy replacement.
    s = s.replace('.xy()z()', '.xyz()')
    return s

shim = r'''
#include <algorithm>
#include <cmath>
#include <iostream>
#include <random>
#include <vector>
#include <stdexcept>
using std::abs; using std::exp; using std::sqrt; using std::isnan; using std::isinf;
float max(float a,float b){return std::max(a,b);}
float min(float a,float b){return std::min(a,b);}
float clamp(float a,float b,float c){return std::clamp(a,b,c);}
struct ivec2 {int x,y; ivec2(int a=0):x(a),y(a){} ivec2(int a,int b):x(a),y(b){} };
ivec2 operator+(ivec2 a,ivec2 b){return {a.x+b.x,a.y+b.y};}
ivec2 operator*(ivec2 a,int b){return {a.x*b,a.y*b};}
struct vec3 {float x,y,z; vec3(float a=0):x(a),y(a),z(a){} vec3(float a,float b,float c):x(a),y(b),z(c){} };
vec3 operator+(vec3 a,vec3 b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
vec3 operator-(vec3 a,vec3 b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
vec3 operator*(vec3 a,float b){return {a.x*b,a.y*b,a.z*b};}
vec3 operator*(vec3 a,vec3 b){return {a.x*b.x,a.y*b.y,a.z*b.z};}
vec3 operator/(vec3 a,float b){return a*(1.f/b);}
vec3& operator+=(vec3& a,vec3 b){a=a+b;return a;}
vec3 max(vec3 a,vec3 b){return {max(a.x,b.x),max(a.y,b.y),max(a.z,b.z)};}
vec3 clamp(vec3 a,float b,float c){return {clamp(a.x,b,c),clamp(a.y,b,c),clamp(a.z,b,c)};}
float dot(vec3 a,vec3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
float length(vec3 a){return sqrt(dot(a,a));}
struct vec4 {float x,y,z,w; vec4(float a=0):x(a),y(a),z(a),w(a){} vec4(float a,float b,float c,float d):x(a),y(b),z(c),w(d){} vec4(vec3 a,float b):x(a.x),y(a.y),z(a.z),w(b){} vec3 rgb()const{return {x,y,z};} vec3 xyz()const{return rgb();} };
struct Invocation {ivec2 p; ivec2 xy(){return p;}} gl_GlobalInvocationID;
struct Push {int stage,stepWidth,finalPass,totalSamples;} pc;
struct Image {int w,h; std::vector<vec4> data; Image(int a=1,int b=1,vec4 c=vec4()):w(a),h(b),data(a*b,c){} };
Image inputImage, outputImage, resolvedImage, normalImage, albedoImage, depthImage, specularImage, momentImage, rawImage;
ivec2 imageSize(const Image& a){return {a.w,a.h};}
vec4 imageLoad(const Image& a,ivec2 p){if(p.x<0||p.y<0||p.x>=a.w||p.y>=a.h)throw std::runtime_error("out of bounds read");return a.data[p.y*a.w+p.x];}
void imageStore(Image& a,ivec2 p,vec4 v){if(p.x<0||p.y<0||p.x>=a.w||p.y>=a.h)throw std::runtime_error("out of bounds write");a.data[p.y*a.w+p.x]=v;}
'''
fixtures = r'''
void check(bool x,const char* m){if(!x)throw std::runtime_error(m);}
void setup(int w,int h,vec4 color){
 inputImage=Image(w,h,color);outputImage=Image(w,h);resolvedImage=Image(w,h);
 normalImage=Image(w,h,vec4(0,0,1,.5));albedoImage=Image(w,h,vec4(.4,.4,.4,1));
 specularImage=Image(w,h,vec4(.04,.04,.04,1));depthImage=Image(w,h,vec4(.05));
 momentImage=Image(w,h,vec4(0,0,0,64));
}
void dispatch(){for(int y=0;y<inputImage.h+2;y++)for(int x=0;x<inputImage.w+2;x++){gl_GlobalInvocationID.p={x,y};kernel();}}
Image run(){rawImage=inputImage;for(int s=0;s<2;s++){pc={s,1,s==1?1:0,64};dispatch();if(s==0)inputImage=outputImage;}return resolvedImage;}
void varianceAt(int i,vec3 v){momentImage.data[i]=vec4(v*(63.f*64.f),64);}
float error(Image a,Image b){float e=0;for(int i=0;i<a.data.size();i++){vec3 d=a.data[i].rgb()-b.data[i].rgb();e+=dot(d,d);}return e/(3*a.data.size());}
int main(){
 for(auto size:std::vector<ivec2>{{1,1},{2,3},{33,25}}){setup(size.x,size.y,vec4(20000,300,2,1));Image original=inputImage;Image result=run();check(error(result,original)<.0001f,"constant HDR and borders must be preserved");}
 setup(41,35,vec4(.5,.3,.1,1));Image truth=inputImage;
 std::mt19937 gen(1234);std::normal_distribution<float> noise(0,.15);
 for(auto& p:inputImage.data){float n=noise(gen);p=vec4(max(p.rgb()+vec3(n),vec3(0)),1);}
 for(int i=0;i<inputImage.data.size();i++)varianceAt(i,vec3(.15f*.15f));
 for(int i:{195,477,743,1001}){inputImage.data[i]=vec4(100,60,20,1);varianceAt(i,vec3(10000,3600,400));}
 Image noisy=inputImage;Image clean=run();float before=error(noisy,truth),after=error(clean,truth);
 check(after<.02f && after<before*.02f,"must suppress sparse fireflies and dense grain");
 float grainBefore=0,grainAfter=0;for(int i=0;i<clean.data.size();i++){if(noisy.data[i].x>5)continue;grainBefore+=std::pow(noisy.data[i].x-.5f,2);grainAfter+=std::pow(clean.data[i].x-.5f,2);}
 check(grainAfter<grainBefore*.6f,"must reduce dense grain independently of outliers");
 std::cout<<"firefly/grain MSE "<<before<<" -> "<<after<<"; grain ratio "<<grainAfter/grainBefore<<"\n";
 // Same-color, tiny geometric island: image-only filtering would erase it.
 for(int kind=0;kind<4;kind++){
  setup(31,31,vec4(.05,.05,.05,1));int c=15*31+15;inputImage.data[c]=vec4(4,4,4,1);
  if(kind==0)depthImage.data[c]=vec4(.2);
  if(kind==1)normalImage.data[c]=vec4(1,0,0,.5);
  if(kind==2)albedoImage.data[c]=vec4(1,0,0,1);
  if(kind==3){for(auto& p:albedoImage.data)p=vec4(0,0,0,1);specularImage.data[c]=vec4(1,0,0,1);}
  varianceAt(c,vec3(16));
  auto result=run();check(result.data[c].x>3.8f,"guide boundary must protect a distinct tiny surface");
 }
 // A broad reflected highlight has no guide boundary and must survive the rank prefilter.
 setup(41,35,vec4(.05,.05,.05,1));for(int y=10;y<25;y++)for(int x=10;x<30;x++)inputImage.data[y*41+x]=vec4(8,8,8,1);
 auto highlight=run();check(highlight.data[17*41+20].x>7.8f,"broad reflection highlight must survive");
 // Color edges on the same surface: reconstruction may soften the edge but not destroy contrast.
 setup(41,35,vec4(.1,.1,.1,1));for(int y=0;y<35;y++)for(int x=21;x<41;x++)inputImage.data[y*41+x]=vec4(2,2,2,1);
 auto edge=run();check(edge.data[17*41+18].x<.18f && edge.data[17*41+23].x>1.8f,"reflection contrast across an unmarked color edge");
 setup(31,31,vec4(.1,.1,.1,1));for(auto& n:normalImage.data)n=vec4(0,0,0,1);for(auto& d:depthImage.data)d=vec4(0);
 Image sky=inputImage;auto skyResult=run();check(error(sky,skyResult)<1e-10f,"zero-normal sky must remain finite and constant");
 setup(31,31,vec4(1,0,0,1));for(int y=0;y<31;y++)for(int x=16;x<31;x++)inputImage.data[y*31+x]=vec4(0,.2126/.7152,0,1);
 auto chroma=run();check(chroma.data[15*31+14].x>.95f && chroma.data[15*31+17].x<.05f,"equal-luminance colored reflection edge");
 std::cout<<"PASS constant/HDR, small images, geometry/material islands and reflection fixtures\n";
}
'''

def execute(s, name):
    cpp = out / (name+'.cpp')
    cpp.write_text(shim+translate(s)+fixtures, encoding='utf-8')
    exe = out / (name+'.exe')
    subprocess.run(['D:/program/mingw64/bin/g++.exe', '-std=c++17', '-O2', str(cpp), '-o', str(exe)], check=True)
    return subprocess.run([str(exe)], capture_output=True, text=True)

r=execute(source,'kernel')
print(r.stdout)
assert r.returncode==0,r.stderr
for name,mutated in [('bypass',source.replace('vec3 result =', 'vec3 result =',1).replace('if (pc.finalPass != 0)', 'result = loadColor(pixel);\n    if (pc.finalPass != 0)')),
                     ('no_guides',re.sub(r'float guideWeight\(.*?\n\}', 'float guideWeight(ivec2 p, ivec2 q) { return 1.0;\n}',source, count=1, flags=re.S))]:
    assert mutated!=source,name
    r=execute(mutated,name)
    assert r.returncode!=0,'undetected negative control: '+name
    print('PASS rejected',name,r.stderr.strip())
