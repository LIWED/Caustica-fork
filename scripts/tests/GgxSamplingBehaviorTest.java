/** CPU float evaluation of extracted production functions; not a GPU or scene convergence test.
 * Reference: GGX D and Smith G1, and visible-normal density D(h) G1(v) max(v.h,0)/NoV.
 * VNDF sampling code itself is unchanged and is not executed by this scalar regression.
 */
public final class GgxSamplingBehaviorTest {
    private static int failures;

    private static double distribution(double cosine, double rough) {
        double alpha = rough * rough;
        double tangentPart = (1 - cosine) * (1 + cosine);
        double denominator = tangentPart + alpha * alpha * cosine * cosine;
        return alpha * alpha / (Math.PI * denominator * denominator);
    }

    private static double masking(double cosine, double rough) {
        double alpha = rough * rough;
        return 2 * cosine / (cosine + Math.hypot(alpha * Math.sqrt(1 - cosine * cosine), cosine));
    }

    private static void near(String label, double actual, double expected, double relativeTolerance) {
        if (!Double.isFinite(actual) || Math.abs(actual - expected) > relativeTolerance * Math.max(1e-30, Math.abs(expected))) {
            failures++;
            System.err.printf("FAIL %s: actual=%.10g expected=%.10g tolerance=%.3g%n", label, actual, expected, relativeTolerance);
        }
    }

    // Inverse CDF for density D(h) cos(theta) dOmega. Resolves very narrow low-roughness peaks.
    private static double normalCosine(double u, double rough) {
        double alpha = rough * rough;
        return Math.sqrt((1 - u) / (1 - u + alpha * alpha * u));
    }

    public static void main(String[] args) {
        for (float rough : new float[]{0.045f, 0.1f, 0.3f, 1f}) {
            for (float cosine : new float[]{0f, 1e-8f, 0.001f, 0.1f, 0.5f, 0.99f, 0.9999f, Math.nextDown(1f), 1f}) {
                // Input rounding is shared; stable FP32 arithmetic should track the double reference.
                near("D rough=" + rough + " cosine=" + cosine, ExtractedGgx.ggxD(cosine, rough), distribution(cosine, rough), 2e-6);
                near("G1 rough=" + rough + " cosine=" + cosine, ExtractedGgx.ggxG1(cosine, rough), masking(cosine, rough), 2e-6);
            }
            for (float cosine : new float[]{Math.nextUp(1f), -1e-6f}) {
                double boundary = Math.max(0, Math.min(1, cosine));
                near("D clamped rough=" + rough + " cosine=" + cosine, ExtractedGgx.ggxD(cosine, rough), distribution(boundary, rough), 2e-6);
                near("G1 clamped rough=" + rough + " cosine=" + cosine, ExtractedGgx.ggxG1(cosine, rough), masking(boundary, rough), 2e-6);
            }
            double integral = 0;
            int samples = 65536;
            for (int i = 0; i < samples; i++) {
                double cosine = normalCosine((i + 0.5) / samples, rough);
                // The float-rounded production input is intentional; include its error in integral.
                integral += ExtractedGgx.ggxD((float)cosine, rough) / distribution(cosine, rough);
            }
            near("projected D normalization rough=" + rough, integral / samples, 1, 0.025);
        }

        // Integrate visible-normal PDF with NDF importance coordinates; max(v.h,0) clips
        // invisible normals. G1 is exactly its normalization. Moderate roughness avoids
        // under-resolving the long tail at grazing view with this deterministic quadrature.
        for (float rough : new float[]{0.3f, 1f}) {
            for (float noV : new float[]{0.02f, 0.25f, 1f}) {
                int radial = 4096, azimuth = 256;
                double integral = 0;
                for (int i = 0; i < radial; i++) {
                    double noH = normalCosine((i + 0.5) / radial, rough);
                    double sinH = Math.sqrt(1 - noH * noH);
                    double ratio = ExtractedGgx.ggxD((float)noH, rough) / distribution(noH, rough);
                    for (int j = 0; j < azimuth; j++) {
                        double voH = noV * noH + Math.sqrt(1 - (double)noV * noV) * sinH * Math.cos(2 * Math.PI * (j + 0.5) / azimuth);
                        integral += ratio * ExtractedGgx.ggxG1(noV, rough) * Math.max(voH, 0) / (noV * noH);
                    }
                }
                near("VNDF normalization rough=" + rough + " NoV=" + noV, integral / (radial * azimuth), 1, 0.012);
            }
        }
        if (failures != 0) throw new AssertionError(failures + " GGX behavior checks failed");
        System.out.println("PASS: extracted GGX D/G1 densities and projected/visible-normal normalization (CPU float; GPU sampling not tested)");
    }
}
