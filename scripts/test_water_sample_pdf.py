"""Regression for generated proposal-edge samples, including the recorded GPU light frame."""
from pathlib import Path
import re, subprocess
ROOT=Path(__file__).resolve().parents[1]
# Reuse the existing production extractor/C++ scalar adapter without running its expensive test body.
helper=ROOT/'scripts/test_water_celestial.py'
ns={'__file__':str(helper)}
exec(helper.read_text(encoding="utf-8").split("tests = r" + chr(39)*3)[0], ns)
module=(ROOT/'shaders/world/water_celestial.slang').read_text(encoding='utf-8')
fixed='waterCelestialSamplePdf' in module
extra=ns['extract'](module,'waterCelestialSamplePdf') if fixed else "float waterCelestialSamplePdf(float3 axis,float3 pole,float halfAngle,float3 air,float3 water,float eta){return waterCelestialPdf(axis,pole,halfAngle,water,eta);}"
extra=re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])',r'\1f',extra)
test=r"""
int main(){
 float3 axis(-.48579132556915283f,.7569849491119385f,.4370132088661194f);
 float3 pole(0,-.49997231364250183f,.866041362285614f);
 float halfAngle=.010471975430846214f,eta=1.333f;
 int holes=0,badSamples=0;double worst=0;
 for(int edge=0;edge<4;edge++)for(int i=0;i<10000;i++){
  float t=(i+.5f)/10000.f, bound=(edge&1)?std::nextafter(1.f,0.f):0.f;
  float2 u=(edge<2)?float2(bound,t):float2(t,bound);
  float3 air=sampleCelestialSquare(axis,pole,waterCelestialGuideHalfAngle(halfAngle),u);
  float3 water=waterCelestialDirection(air,eta);
  float evaluated=waterCelestialPdf(axis,pole,halfAngle,water,eta);
  float sampled=waterCelestialSamplePdf(axis,pole,halfAngle,air,water,eta);
  if(!(evaluated>0)) holes++;
  if(!(sampled>1000.f && std::isfinite(sampled))) badSamples++;
  double tangent=std::tan((double)waterCelestialGuideHalfAngle(halfAngle));
  float cosine=dot(normalize(axis),air);
  double reference=eta*eta*water.y/air.y/(4*tangent*tangent*cosine*cosine*cosine);
  worst=std::max(worst,std::abs(sampled/reference-1));
 }
 std::cout<<"edge samples=40000 evaluated-PDF holes="<<holes<<" sampled-PDF failures="<<badSamples<<" relative error="<<worst<<"\n";
 require(holes>0,"must exercise actual inverse-mapping failures");
 require(badSamples==0,"a generated sample must retain its known proposal density");
 require(worst<2e-6,"known forward Jacobian density");
}
"""
out=ROOT/'build/water-celestial';out.mkdir(parents=True,exist_ok=True)
def run(extra,stem):
 cpp=out/(stem+'.cpp');exe=out/(stem+'.exe');cpp.write_text(ns['preamble']+ns['production']+extra+test)
 subprocess.run(['D:/program/mingw64/bin/g++.exe','-std=c++17','-O2',str(cpp),'-o',str(exe)],check=True)
 return subprocess.run([str(exe)],capture_output=True,text=True)
r=run(extra,'sample-pdf');print(r.stdout,end='');assert r.returncode==0,r.stderr
world=(ROOT/'shaders/world/world.rgen.slang').read_text(encoding='utf-8')
assert 'sampledWaterGuidePdf = interfaceCelestialSamplePdf(' in world
assert 'surfaceBsdfPdf(n, v, nextDir, diffAlb, F0, rough, pbr), sampledWaterGuidePdf, waterGuideMix)' in world
old="float waterCelestialSamplePdf(float3 axis,float3 pole,float halfAngle,float3 air,float3 water,float eta){return waterCelestialPdf(axis,pole,halfAngle,water,eta);}"
r=run(old,'sample-pdf-old');assert r.returncode!=0 and 'known proposal density' in r.stderr
print('PASS generated-edge density, continuation binding and old inverse-PDF negative control')
