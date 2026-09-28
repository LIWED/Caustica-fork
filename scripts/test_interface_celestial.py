"""Extract production FP32 Slang; test tilted planar interfaces without Vulkan."""
from pathlib import Path
import ast
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / 'shaders/world/interface_celestial.slang'
assert path.exists(), 'missing actual-normal interface proposal'

def extract(source, name):
    match = re.search(r'(?:public\s+)?(?:float3|float|bool|void)\s+' + name + r'\([^)]*\)\s*\{', source)
    assert match, name
    end, depth = match.end(), 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end].replace('public ', '').replace('out float3 ', 'float3& ')

# Reuse only the portable FP32 vector shim; do not run the older raygen contracts.
tree = ast.parse((ROOT / 'scripts/test_water_celestial.py').read_text(encoding='utf-8'))
preamble = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == 'preamble' for t in node.targets))
production = ''
for filename, names in [
    ('celestial.slang', ['celestialTangentHalfAngle', 'celestialPlanePdf', 'celestialFrame', 'sampleCelestialSquare', 'celestialDirectionPdf']),
    ('water_celestial.slang', ['waterCelestialGuideHalfAngle', 'waterCelestialJacobian', 'waterCelestialMixturePdf']),
    ('interface_celestial.slang', ['interfaceCelestialDirection', 'interfaceCelestialAirDirection', 'interfaceCelestialPdf', 'interfaceCelestialSamplePdf']),
]:
    source = (ROOT / 'shaders/world' / filename).read_text(encoding='utf-8')
    production += '\n'.join(extract(source, name) for name in names) + '\n'
production = re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])', r'\1f', production)

tests = r'''
float3 traceExit(float3 d,float3 n,float eta,bool reflection){
 float c=dot(d,n);
 if(reflection)return d-2.f*c*n;
 float k=1.f-eta*eta*(1.f-c*c);
 return k>0?eta*d+(std::sqrt(k)-eta*c)*n:float3(0);
}
double fresnel(double ca,double eta){
 double cw=std::sqrt(1-(1-ca*ca)/(eta*eta));
 double rs=(ca-eta*cw)/(ca+eta*cw),rp=(eta*ca-cw)/(eta*ca+cw);
 return .5*(rs*rs+rp*rp);
}
struct D3 {double x,y,z;};
D3 operator+(D3 a,D3 b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
D3 operator*(D3 a,double b){return {a.x*b,a.y*b,a.z*b};}
double ddot(D3 a,D3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
D3 dcross(D3 a,D3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
D3 unit(D3 a){return a*(1/std::sqrt(ddot(a,a)));}
D3 dbl(float3 a){return {a.x,a.y,a.z};}
int main(){
 const float eta=1.333f,angle=.010471976f; const float3 pole(0,0,1);
 std::mt19937 rng(193127);std::uniform_real_distribution<float> u(0,1);
 int lostInverse[2]={0,0};
 for(float3 raw:{float3(0,1,0),float3(-.003583809f,.99997234f,-.006516753f),float3(.36f,.8f,-.48f)}) {
  float3 n=normalize(raw),tangent=normalize(cross(n,pole));
  for(bool reflection:{false,true}) {
   float3 wrong=n*(reflection?1.f:-1.f);
   require(dot(interfaceCelestialDirection(n*-1.f,n,eta,reflection),interfaceCelestialDirection(n*-1.f,n,eta,reflection))==0,"air hemisphere gate");
   require(dot(interfaceCelestialAirDirection(wrong,n,eta,reflection),interfaceCelestialAirDirection(wrong,n,eta,reflection))==0,"mapped hemisphere gate");
   require(interfaceCelestialPdf(n,pole,angle,wrong,n,eta,reflection)==0,"wrong hemisphere PDF");
   if(!reflection)require(dot(interfaceCelestialAirDirection(normalize(tangent+n*.1f),n,eta,false),interfaceCelestialAirDirection(normalize(tangent+n*.1f),n,eta,false))==0,"TIR inverse gate");
   for(float ca:{.15f,.3f,.8f,1.f}) {
    float3 a=normalize(n*ca+tangent*std::sqrt(1-ca*ca));
    float3 d=interfaceCelestialDirection(a,n,eta,reflection),back=interfaceCelestialAirDirection(d,n,eta,reflection);
    near(dot(d,d),1,2e-6,"unit mapped direction");
    near(dot(back-a,back-a),0,1e-10,"actual-normal inverse roundtrip");
    float3 traced=traceExit(d,n,eta,reflection);
    near(dot(traced-a,traced-a),0,2e-10,"mapping agrees with real refract/reflect");
    if(ca<1) {
     double h=1e-5,ta=std::acos(double(ca));
     double plus=reflection?ta+h:std::asin(std::sin(ta+h)/eta),minus=reflection?ta-h:std::asin(std::sin(ta-h)/eta);
     double area=std::sin((plus+minus)*.5)*(plus-minus)/(2*h*std::sin(ta));
     double p=interfaceCelestialSamplePdf(a,pole,angle,a,d,n,eta,reflection);
     double ap=celestialDirectionPdf(a,pole,waterCelestialGuideHalfAngle(angle),a);
     near(ap/p,area,3e-6,"finite-difference solid-angle Jacobian");
    }
   }
   // Grid includes exact and adjacent FP32 square edges, including the logged ripple normal.
   for(float ca:{.2f,.7f,.98f})for(float half:{.0001f,angle,.08f}) {
    float3 axis=normalize(n*ca+tangent*std::sqrt(1-ca*ca));
    for(int i=0;i<20000;i++) {
     float edge=(i&1)?1.f:0.f,other=u(rng);float2 uv=(i&2)?float2(edge,other):float2(other,edge);
     float3 a=sampleCelestialSquare(axis,pole,waterCelestialGuideHalfAngle(half),uv);
     float3 d=interfaceCelestialDirection(a,n,eta,reflection);
     float known=interfaceCelestialSamplePdf(axis,pole,half,a,d,n,eta,reflection);
     require(known>0 && std::isfinite(known),"known generated edge keeps complete density");
     if(interfaceCelestialPdf(axis,pole,half,d,n,eta,reflection)==0)lostInverse[reflection]++;
     // Actual emitter fits strictly inside the proposal despite traced inverse rounding.
     a=sampleCelestialSquare(axis,pole,half,uv);d=interfaceCelestialDirection(a,n,eta,reflection);
     float3 escaped=traceExit(d,n,eta,reflection);
     if(celestialDirectionPdf(axis,pole,half,escaped)>0)require(interfaceCelestialPdf(axis,pole,half,d,n,eta,reflection)>0,"traced emitter covered by padded guide");
    }
   }
   for(float ca:{.3f,.8f})for(bool blocked:{false,true}) {
    float3 axis=normalize(n*ca+tangent*std::sqrt(1-ca*ca));
    float3 receiver=n*(reflection?-1.f:1.f),right=normalize(cross(receiver,pole)),up=cross(right,receiver);
    // Independent DOUBLE tangent-plane quadrature, Fresnel, and planar Beer transport.
    D3 dn=unit(dbl(n)),forward=unit(dbl(axis)),dr=unit(dcross(forward,dbl(pole))),du=dcross(dr,forward);
    // Integrate the arbitrary-direction PDF over an independently mapped plane.
    double normalization=0,guideT=std::tan(double(waterCelestialGuideHalfAngle(angle)));
    const int normGrid=64;
    for(int i=0;i<normGrid;i++)for(int j=0;j<normGrid;j++) {
     double x=(2*(i+.5)/normGrid-1)*guideT,y=(2*(j+.5)/normGrid-1)*guideT;
     D3 a=unit(forward+dr*x+du*y);double ac=ddot(a,dn);
     double wc=reflection?ac:std::sqrt(1-(1-ac*ac)/(eta*eta));
     D3 d=reflection?a+dn*(-2*ac):(a+dn*(-ac))*(1/double(eta))+dn*wc;
     double jac=reflection?1:eta*eta*wc/ac;
     double p=interfaceCelestialPdf(axis,pole,angle,{float(d.x),float(d.y),float(d.z)},n,eta,reflection);
     normalization+=p*4*guideT*guideT/std::pow(1+x*x+y*y,1.5)/jac/(normGrid*normGrid);
    }
    near(normalization,1,2e-5,"actual-normal proposal PDF normalization");
    double reference=0;const int grid=140;double t=std::tan(double(angle));
    for(int i=0;i<grid;i++)for(int j=0;j<grid;j++) {
     D3 a=unit(forward+dr*((2*(i+.5)/grid-1)*t)+du*((2*(j+.5)/grid-1)*t));
     double ac=ddot(a,dn),wc=reflection?ac:std::sqrt(1-(1-ac*ac)/(eta*eta));
     double jac=reflection?1:eta*eta*wc/ac;
     double tr=reflection?fresnel(ac,eta):(1-fresnel(ac,eta))*std::exp(-.2/wc);
     if(!blocked || ddot(a,du)>0)reference+=.7/PI*wc*tr/jac/(grid*grid);
    }
    auto evaluate=[&](float3 d,double pdf){
     float3 a=traceExit(d,n,eta,reflection);if(dot(a,n)<=0)return 0.;
     double light=celestialDirectionPdf(axis,pole,angle,a);
     if(light<=0 || (blocked && ddot(dbl(a),du)<=0))return 0.;
     double ac=dot(a,n),wc=dot(d,receiver),tr=reflection?fresnel(ac,eta):(1-fresnel(ac,eta))*std::exp(-.2/wc);
     return .7/PI*wc*light*tr/pdf;
    };
    auto baseSample=[&](){float r=std::sqrt(u(rng)),phi=2*PI*u(rng);return right*(r*std::cos(phi))+up*(r*std::sin(phi))+receiver*std::sqrt(1-r*r);};
    double sum=0,sq=0,oldSum=0,oldSq=0;const int count=800000;
    for(int i=0;i<count;i++) {
     float3 d;float guide;
     if(u(rng)<.5f){float u1=u(rng),u2=u(rng);float3 a=sampleCelestialSquare(axis,pole,waterCelestialGuideHalfAngle(angle),{u1,u2});d=interfaceCelestialDirection(a,n,eta,reflection);guide=interfaceCelestialSamplePdf(axis,pole,angle,a,d,n,eta,reflection);}
     else{d=baseSample();guide=interfaceCelestialPdf(axis,pole,angle,d,n,eta,reflection);}
     double v=evaluate(d,waterCelestialMixturePdf(dot(d,receiver)/PI,guide,.5f));sum+=v;sq+=v*v;
     d=baseSample();v=evaluate(d,dot(d,receiver)/PI);oldSum+=v;oldSq+=v*v;
    }
    double mean=sum/count,var=sq/count-mean*mean,baseMean=oldSum/count,baseVar=oldSq/count-baseMean*baseMean;
    near(mean,reference,reference*.025,"mixture mean versus independent planar integral");
    near(baseMean,reference,8*std::sqrt(baseVar/count)+reference*.01,"base mean versus independent planar integral");
    require(baseVar>var*100,"small-sun variance improves over ordinary BSDF");
    std::cout<<"reflection="<<reflection<<" cos="<<ca<<" blocked="<<blocked<<" mean="<<mean<<" reference="<<reference<<" base="<<baseMean<<" varianceRatio="<<baseVar/var<<"\n";
   }
  }
 }
 require(lostInverse[0]>0 && lostInverse[1]>0,"negative evidence: inverse square test loses edge samples in both modes");
 std::cout<<"PASS FP32 actual-normal maps, Jacobians, edge support; inverse edge losses refraction="<<lostInverse[0]<<" reflection="<<lostInverse[1]<<"; 24 planar transport cases\n";
}
'''
out = ROOT / 'build/interface-celestial'
out.mkdir(parents=True, exist_ok=True)

def run(source, stem):
    cpp, exe = out / (stem + '.cpp'), out / (stem + '.exe')
    cpp.write_text(source, encoding='utf-8')
    subprocess.run(['D:/program/mingw64/bin/g++.exe', '-std=c++17', '-O2', str(cpp), '-o', str(exe)], check=True)
    return subprocess.run([str(exe)], capture_output=True, text=True)

result = run(preamble + production + tests, 'test')
print(result.stdout, end='')
assert result.returncode == 0, result.stderr
for label, old, new in [
    ('missing_jacobian', 'eta * eta * waterCos / airCos', '1.0f'),
    ('missing_mixture', '(1.0f - mix) * bsdfPdf + mix * guidePdf', 'bsdfPdf'),
    ('sample_inverse_edge', 'float cosine = dot(normalize(axis), airDir);', 'return interfaceCelestialPdf(axis, pole, halfAngle, direction, normal, eta, reflection);\n    float cosine = dot(normalize(axis), airDir);'),
]:
    assert old in production, label
    mutant = run(preamble + production.replace(old, new) + tests, label)
    assert mutant.returncode != 0 and 'FAIL' in mutant.stderr, (label, mutant.stderr)
    print('PASS numerical negative control:', label)
