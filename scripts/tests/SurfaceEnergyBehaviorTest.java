/** Extracted production scalar helper + Smith G1; independent VNDF reference quadrature.
 * Covers a single white surface, not shading-normal transport, SSS, or scene convergence.
 */
public final class SurfaceEnergyBehaviorTest {
    static double fresnel(double c,double f0) { return f0+(1-f0)*Math.pow(1-c,5); }
    static double fract(double x) { return x-Math.floor(x); }
    static void require(boolean b,String label) { if(!b) throw new AssertionError(label); }
    static double specular(float nv,float rough,float f0) {
        double a=rough*rough, vx=Math.sqrt(1-(double)nv*nv);
        double tx=a*vx, tz=nv, norm=Math.hypot(tx,tz); tx/=norm;tz/=norm;
        int count=262144; double sum=0;
        for(int i=1;i<=count;i++) {
            double u=fract(i*.7548776662466927), w=fract(i*.5698402909980532);
            double r=Math.sqrt(u), phi=2*Math.PI*w;
            double t1=r*Math.cos(phi), s=.5*(1+tz);
            double t2=(1-s)*Math.sqrt(1-t1*t1)+s*r*Math.sin(phi);
            double z=Math.sqrt(Math.max(0,1-t1*t1-t2*t2));
            double hx=a*(-tz*t2+tx*z),hy=a*t1,hz=tx*t2+tz*z;
            norm=Math.sqrt(hx*hx+hy*hy+hz*hz);hx/=norm;hz/=norm;
            double vh=vx*hx+nv*hz, nl=2*vh*hz-nv;
            if(nl>0) sum+=fresnel(vh,f0)*ExtractedSurfaceEnergy.ggxG1((float)nl,rough);
        }
        return sum/count;
    }
    static double diffuse(float nv,float f0) {
        double sum=0;int count=16384;
        for(int i=0;i<count;i++) {
            float nl=(float)((i+.5)/count);
            float scale=ExtractedSurfaceEnergy.surfaceDiffuseEnergyBudget(nv,nl,f0);
            require(Float.isFinite(scale)&&scale>=0&&scale<=1.19,"finite diffuse scale");
            require(Math.abs(scale-ExtractedSurfaceEnergy.surfaceDiffuseEnergyBudget(nl,nv,f0))<1e-7,"reciprocity");
            sum+=2*nl*scale;
        }
        return sum/count;
    }
    public static void main(String[] args) {
        double largest=0; int cases=0;
        for(float f0:new float[]{.04f,.5f,.9f})
          for(float nv:new float[]{.001f,.01f,.1f,.5f,1f}) {
            double d=diffuse(nv,f0);
            for(float rough:new float[]{.045f,.1f,.2f,.5f,1f}) {
                double spec=specular(nv,rough,f0),total=spec+d;
                System.out.printf("F0=%.2f NoV=%.3f rough=%.3f spec=%.8f diffuse=%.8f total=%.8f%n",f0,nv,rough,spec,d,total);
                require(total<=1.00002,"white furnace exceeds unity: "+total);
                largest=Math.max(largest,total);cases++;
            }
        }
        for(float mu:new float[]{0,Float.MIN_NORMAL,1e-8f,1e-5f,.001f,1f}) {
            float b=ExtractedSurfaceEnergy.surfaceDiffuseEnergyBudget(mu,1,.04f);
            require(Float.isFinite(b)&&b>=0&&b<=1.19,"endpoint finite");
        }
        double c=0;int n=1048576;
        for(int i=0;i<n;i++) {
            double mu=(i+.5)/n;
            double h=mu/Math.sqrt(2*(1+Math.sqrt(1-mu*mu)));
            c+=2*mu*(1-Math.pow(1-h,5))/n;
        }
        double analytic=-15.0/8+121*Math.sqrt(2)/63;
        require(Math.abs(c-analytic)<1e-10,"normalization independent integral");
        require((double)0.8411881f>=analytic,"normalization rounded upward");
        require(ExtractedSurfaceEnergy.surfaceDiffuseEnergyBudget(1,1,.04f)>1,"do not clamp directional coefficient");
        System.out.printf("C quadrature=%.15f analytic=%.15f shader=%.15f%n",c,analytic,(double)0.8411881f);
        System.out.printf("PASS: %d white-furnace cases; max %.9f; reciprocal diffuse and finite endpoints. CPU scalar test only.%n",cases,largest);
    }
}
