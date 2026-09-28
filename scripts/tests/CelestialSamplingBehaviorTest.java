import java.util.Random;

/** Extracted production FP32 scalars versus double quadrature and a normal-incidence
 * GGX reference sampler. Does not execute GPU sampling, the integrator, or actual scenes. */
public final class CelestialSamplingBehaviorTest {
    private static int failures;
    private static void near(String label, double value, double expected, double tolerance) {
        if (!Double.isFinite(value) || Math.abs(value - expected) > tolerance * Math.max(1, Math.abs(expected))) {
            failures++;
            System.err.printf("FAIL %s: %.9g expected %.9g%n", label, value, expected);
        }
    }
    private static void check(String label, boolean condition) { near(label, condition ? 1 : 0, 1, 0); }
    // Independent double GGX D and masking; roughness is squared to form alpha.
    private static double d(double nh, double rough) {
        double a2 = Math.pow(rough, 4), denom = 1 - nh * nh + a2 * nh * nh;
        return a2 / (Math.PI * denom * denom);
    }
    private static double fCos(double z, double rough) {
        if (z <= 0) return 0;
        double g = 2 * z / (z + Math.sqrt(Math.pow(rough, 4) * (1 - z * z) + z * z));
        return d(Math.sqrt((1 + z) / 2), rough) * g / 4;
    }
    private static double prodF(double z, float rough) {
        if (z <= 0) return 0;
        return ExtractedCelestial.ggxD((float)Math.sqrt((1 + z) / 2), rough)
            * ExtractedCelestial.ggxG1((float)z, rough) / 4.0;
    }
    private static double q(double u, double v, float t) {
        return ExtractedCelestial.celestialPlanePdf((float)u, (float)v, t);
    }
    public static void main(String[] args) {
        for (int bits : new int[]{0, 1, 0xffffff00, 0xffffff7f, 0xffffff80, 0xffffffff}) {
            float value = ExtractedCelestial.rndFromBits(bits);
            check("production RNG is half-open for " + Integer.toUnsignedString(bits), value >= 0 && value < 1);
        }
        if (args.length == 1 && args[0].equals("--energy-only")) {
            pairedExperiment(.3f, .16f, 0);
            if (failures > 0) throw new AssertionError(failures + " energy regressions");
            return;
        }
        for (float a : new float[]{-1, 0}) near("delta angle", ExtractedCelestial.celestialTangentHalfAngle(a), 0, 0);
        for (float a : new float[]{1e-8f, 1e-4f, .01f, .5f, 1.4f, 3f})
            near("angle clamp", ExtractedCelestial.celestialTangentHalfAngle(a), Math.tan(Math.min(1.4f, Math.max(1e-4f, a))), 2e-6);
        near("zero area", q(0, 0, 0), 0, 0);
        near("negative area", q(0, 0, -1), 0, 0);
        for (double u : new double[]{-.201, .201}) {
            near("outside u", q(u, 0, .2f), 0, 0);
            near("outside v", q(0, u, .2f), 0, 0);
        }
        check("boundary included", q(.2f, -.2f, .2f) > 0);
        for (float a : new float[]{0, 1e-30f, 1e-6f, 1, 1e20f, Float.MAX_VALUE})
            for (float b : new float[]{0, 1e-30f, 1e-6f, 1, 1e20f, Float.MAX_VALUE}) {
                double expected = a == 0 && b == 0 ? 0 : (double)a * a / ((double)a * a + (double)b * b);
                near("stable power", ExtractedCelestial.celestialPowerHeuristic(a, b), expected, 2e-7);
                near("last bounce", ExtractedCelestial.celestialDirectMisWeight(a, b, false), 1, 0);
                near("delta escape", ExtractedCelestial.celestialEscapeMisWeight(a, b, true), 1, 0);
                if (a > 0) near("MIS complement", ExtractedCelestial.celestialDirectMisWeight(a, b, true)
                    + ExtractedCelestial.celestialEscapeMisWeight(b, a, false), 1, 2e-7);
            }
        near("delta direct", ExtractedCelestial.celestialDirectMisWeight(0, 10, true), 1, 0);
        near("backside particle has zero competing PDF", ExtractedCelestial.celestialDirectMisWeight(20, 0, true), 1, 0);
        // Independent spherical coordinates and dOmega = sin(theta)dtheta dphi.
        for (float t : new float[]{.0001f, .05f, .3f, 1f}) {
            double integral = 0;
            int n = 512;
            for (int i = 0; i < n; i++) {
                double phi = 2 * Math.PI * (i + .5) / n, c = Math.cos(phi), s = Math.sin(phi);
                double limit = Math.atan(t / Math.max(Math.abs(c), Math.abs(s)));
                for (int j = 0; j < n; j++) {
                    double theta = limit * (j + .5) / n, r = Math.tan(theta);
                    integral += q(r * c, r * s, t) * Math.sin(theta) * limit / n * 2 * Math.PI / n;
                }
            }
            near("solid angle normalization t=" + t, integral, 1, 3e-5);
        }
        pairedExperiment(.3f, .16f, 0);
        float sunT = ExtractedCelestial.celestialTangentHalfAngle((float)Math.toRadians(.6));
        pairedExperiment(sunT, .045f, 0);
        pairedExperiment(sunT, .045f, .008);
        if (failures > 0) throw new AssertionError(failures + " celestial regressions");
        System.out.println("PASS celestial scalar, solid-angle normalization, radiance expectation and paired MIS regression (CPU only)");
    }
    private static void pairedExperiment(float t, float rough, double axisTilt) {
        double ca = Math.cos(axisTilt), sa = Math.sin(axisTilt);
        double reference = 0;
        int grid = 1000;
        // Le = I*q, I=1: solid-angle Jacobian cancels q, leaving uniform plane average.
        for (int i = 0; i < grid; i++) for (int j = 0; j < grid; j++) {
            double u = t * (2 * (i + .5) / grid - 1), v = t * (2 * (j + .5) / grid - 1);
            reference += fCos((ca - u * sa) / Math.sqrt(1 + u * u + v * v), rough) / ((double)grid * grid);
        }
        Random random = new Random(0xCE1E571AL);
        int count = 250000;
        double sumL = 0, sumM = 0, sumL2 = 0, sumM2 = 0, sumUnweighted = 0;
        for (int i = 0; i < count; i++) {
            double u = t * (2 * random.nextDouble() - 1), v = t * (2 * random.nextDouble() - 1);
            double z = (ca - u * sa) / Math.sqrt(1 + u * u + v * v), light = q(u, v, t);
            double pB = ExtractedCelestial.ggxD((float)Math.sqrt((1 + z) / 2), rough) / 4.0;
            double only = prodF(z, rough);
            double paired = only * ExtractedCelestial.celestialDirectMisWeight((float)light, (float)pB, true);
            double unweighted = only;
            // At normal incidence VNDF=NDF*cos. Reflect about its inverse-CDF sample.
            double xi = random.nextDouble(), a2 = Math.pow(rough, 4);
            double nh = Math.sqrt((1 - xi) / (1 - xi + a2 * xi));
            double phi = 2 * Math.PI * random.nextDouble(), radial = 2 * nh * Math.sqrt(1 - nh * nh);
            z = 2 * nh * nh - 1;
            if (z > 0) {
                double x = radial * Math.cos(phi), y = radial * Math.sin(phi);
                double lightCosine = x * sa + z * ca;
                light = lightCosine > 0 ? q((x * ca - z * sa) / lightCosine, y / lightCosine, t) : 0;
                // Use the independent sampler's exact density for its denominator.
                pB = d(nh, rough) / 4;
                double escape = prodF(z, rough) * light / pB;
                unweighted += escape;
                paired += escape
                    * ExtractedCelestial.celestialEscapeMisWeight((float)pB, (float)light, false);
            }
            sumL += only; sumL2 += only * only;
            sumM += paired; sumM2 += paired * paired;
            sumUnweighted += unweighted;
        }
        double meanL = sumL / count, meanM = sumM / count;
        double varL = sumL2 / count - meanL * meanL, varM = sumM2 / count - meanM * meanM;
        near("Le=I*q light expectation", meanL, reference, .025);
        near("paired MIS energy", meanM, reference, .012);
        near("old unweighted estimator doubles energy", sumUnweighted / count, 2 * reference, .03);
        check("energy oracle rejects old weight=1 behavior", Math.abs(sumUnweighted / count - reference) > .5 * reference);
        check("paired MIS variance lower even at equal sample cost", 2 * varM < varL);
        System.out.printf("GGX rough=%.3f t=%.6f tilt=%.4f reference=%.6f light=%.6f paired=%.6f old=%.6f variance(light)=%.6f variance(paired)=%.6f%n",
            rough, t, axisTilt, reference, meanL, meanM, sumUnweighted / count, varL, varM);
    }
}
