package dev.comfyfluffy.caustica.rt.water;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;
import org.junit.jupiter.api.function.Executable;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertAll;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

@TestInstance(TestInstance.Lifecycle.PER_CLASS)
final class WaterCausticStatisticsTest {
    private static final Path WATER_SHADER = Path.of("shaders", "world", "water.slang");
    private static final Path WORLD_CORE_SHADER = Path.of("shaders", "world", "world_core.slang");
    private static final double PI = 3.14159265359;
    private static final double GRID_METERS = 32.0;
    private static final double SAMPLE_STEP = 0.125;
    private static final int GRID_SIZE = 256;
    private static final double PEAK_THRESHOLD = 1.25;
    private static final double[] DEPTHS = {1.0, 3.0, 5.0};
    private static final double[] TIMES = {0.0, 1.7, 4.3};
    private static final double ORIGIN_X = 137.25;
    private static final double ORIGIN_Z = -83.75;
    private static final double REBASE_X = 4096.0;
    private static final double REBASE_Z = -3072.0;
    private static final double STRENGTH = 1.0;
    private static final double CONTINUITY_TIME = 1.7;
    private static final double FRAME_TIME = 1.0 / 60.0;
    private static final double CONTINUITY_MEAN_LIMIT = 0.03;
    private static final double CONTINUITY_MAX_LIMIT = 0.35;
    private static final double REBASE_ERROR_LIMIT = 1.0e-5;
    private static final double BASELINE_DENSITY_FLOOR = 1.0 / (GRID_METERS * GRID_METERS);
    private static final double RIDGE_PROFILE_STEP = 0.015625;
    private static final double RIDGE_BASELINE_DISTANCE = 0.75;
    private static final double RIDGE_WIDTH_LIMIT = 1.5;
    private static final int RIDGE_MIN_VALID_WIDTHS = 32;
    private static final double RIDGE_MIN_COVERAGE = 0.90;
    private static final double RIDGE_MIN_MEDIAN = 0.135;
    private static final double RIDGE_MAX_MEDIAN = 0.150;
    private static final double RIDGE_MIN_IQR_OVER_MEDIAN = 0.30;
    private static final double RIDGE_MAX_IQR_OVER_MEDIAN = 0.40;
    private static final double NEAREST_NEIGHBOUR_MAX_RATIO = 0.70;
    private static final double LIGHT_X;
    private static final double LIGHT_Y;
    private static final double LIGHT_Z;

    private static final double[] DETAIL_WAVELENGTH = {0.95, 0.68, 0.49, 0.34, 0.24, 0.18};
    private static final double[] DETAIL_DIRECTION = {2.36, -2.05, 0.98, -0.22, 1.71, -1.31};
    private static final double[] DETAIL_ENERGY = {0.0315, 0.0294, 0.0273, 0.0231, 0.0189, 0.0147};
    private static final double[] DETAIL_MEANDER_AMPLITUDE = {0.52, 0.61, 0.47, 0.68, 0.56, 0.73};
    private static final double[] DETAIL_PHASE = {5.11, 1.37, 3.92, 0.58, 4.46, 2.73};
    private static final double[] DETAIL_SHARPNESS = {0.86, 0.90, 0.94, 0.98, 1.02, 1.06};
    private static final double[] DETAIL_MEANDER_SCALE = {0.37, 0.43, 0.31, 0.47, 0.35, 0.41};
    private static final double[] DETAIL_MEANDER_SPEED = {0.33, -0.28, 0.42, -0.37, 0.25, -0.45};
    private static final double[] DETAIL_MEANDER_OFFSET = {0.91, 3.44, 5.26, 2.08, 4.79, 1.62};
    private static final double[] DETAIL_WARP = {0.22, 0.31, 0.17, 0.21, 0.41, -0.19, 0.29, 0.17, 2.13};

    static {
        double length = Math.sqrt(0.38 * 0.38 + 0.82 * 0.82 + 0.43 * 0.43);
        LIGHT_X = 0.38 / length;
        LIGHT_Y = 0.82 / length;
        LIGHT_Z = 0.43 / length;
    }

    private Fixture candidateFixture;
    private Evaluation cachedEvaluation;

    @Test
    void solarWeightMakesNightCausticsNeutralWithoutChangingDaylight() {
        String waterCaustic = ShaderParser.functionSection(
                ShaderParser.removeComments(ShaderParser.read(WATER_SHADER)),
                "public float waterCaustic");
        assertAll("solar-gated water caustics",
                () -> assertTrue(waterCaustic.contains(
                        "float solarCausticWeight = clamp(worldPush.sunDir.w, 0.0, 1.0);")),
                () -> assertTrue(waterCaustic.contains(
                        "if (strength <= 0.0 || solarCausticWeight <= 0.0) return 1.0;")),
                () -> assertTrue(waterCaustic.contains(
                        "return lerp(1.0, focus, solarCausticWeight * fade * (1.0 - deepFade));")));

        double focus = 2.4;
        assertEquals(1.0, applySolarWeight(focus, 0.0), 0.0);
        assertEquals(focus, applySolarWeight(focus, 1.0), 0.0);
        assertEquals(1.7, applySolarWeight(focus, 0.5), 1.0e-12);
    }

    @Test
    void currentShaderParsesTheApprovedDetailAndSplitRoles() {
        Fixture candidate = candidate();

        assertAll("approved caustic detail and split roles",
                () -> assertArrayEquals(DETAIL_WAVELENGTH, candidate.detail().wavelength(), 0.0),
                () -> assertArrayEquals(DETAIL_DIRECTION, candidate.detail().directionOffset(), 0.0),
                () -> assertArrayEquals(DETAIL_ENERGY, candidate.detail().energy(), 0.0),
                () -> assertArrayEquals(DETAIL_MEANDER_AMPLITUDE, candidate.detail().meanderAmplitude(), 0.0),
                () -> assertArrayEquals(DETAIL_PHASE, candidate.detail().phaseOffset(), 0.0),
                () -> assertArrayEquals(DETAIL_SHARPNESS, candidate.detail().sharpness(), 0.0),
                () -> assertArrayEquals(DETAIL_MEANDER_SCALE, candidate.detail().meanderScale(), 0.0),
                () -> assertArrayEquals(DETAIL_MEANDER_SPEED, candidate.detail().meanderSpeed(), 0.0),
                () -> assertArrayEquals(DETAIL_MEANDER_OFFSET, candidate.detail().meanderOffset(), 0.0),
                () -> assertArrayEquals(DETAIL_WARP, candidate.warp().values(), 0.0),
                () -> assertEquals(0.06, candidate.jacobianEps(), 0.0),
                () -> assertEquals(0.06, candidate.lodNear(), 0.0),
                () -> assertEquals(0.28, candidate.lodFar(), 0.0),
                () -> assertTrue(candidate.splitJacobianAndLod()),
                () -> assertSpectrumEquals(Baseline042.FIXTURE.base(), candidate.base()),
                () -> assertEquals(Baseline042.FIXTURE.surfaceGain(), candidate.surfaceGain(), 0.0),
                () -> assertEquals(Baseline042.FIXTURE.refractionGain(), candidate.refractionGain(), 0.0),
                () -> assertEquals(Baseline042.FIXTURE.refractionMaxSlope(), candidate.refractionMaxSlope(), 0.0),
                () -> assertEquals(Baseline042.FIXTURE.refractionComponentCount(), candidate.refractionComponentCount()),
                () -> assertEquals(Baseline042.FIXTURE.refractionMinFootprint(),
                        candidate.refractionMinFootprint(), 0.0));
    }

    @Test
    void baseline042FixtureProducesDeterministicFiniteFocus() {
        double[][] first = sampleFocus(Baseline042.FIXTURE, 1.0, 0.0,
                ORIGIN_X, ORIGIN_Z, 0.0, 0.0);
        double[][] repeat = sampleFocus(Baseline042.FIXTURE, 1.0, 0.0,
                ORIGIN_X, ORIGIN_Z, 0.0, 0.0);

        assertFocusEquals(first, repeat, 0.0, "Baseline042 repeat");
        FrameStats stats = frameStats(first);
        assertTrue(Double.isFinite(stats.mean()));
        assertTrue(stats.min() >= Baseline042.FIXTURE.causticMin());
        assertTrue(stats.max() <= Baseline042.FIXTURE.causticMax());
    }

    @Test
    void approvedSpatialMetricsHoldAcrossDepthAverages() {
        Evaluation evaluation = evaluation();
        printMetricTable(evaluation);

        DepthStats oneBlock = evaluation.candidateDepth()[0];
        DepthStats baselineOneBlock = evaluation.baselineDepth()[0];
        double baselineDensity = Math.max(baselineOneBlock.peakDensity(), BASELINE_DENSITY_FLOOR);
        assertTrue(oneBlock.peakDensity() >= 2.5 * baselineDensity,
                () -> "one-block peak density " + oneBlock.peakDensity()
                        + " is below 2.5x baseline floor " + baselineDensity);

        DepthStats fiveBlocks = evaluation.candidateDepth()[2];
        assertTrue(fiveBlocks.peakDensity() >= 0.70 * oneBlock.peakDensity(),
                () -> "five-block peak density " + fiveBlocks.peakDensity()
                        + " falls more than 30% from one-block " + oneBlock.peakDensity());

        for (int depthIndex = 0; depthIndex < DEPTHS.length; depthIndex++) {
            double depth = DEPTHS[depthIndex];
            DepthStats stats = evaluation.candidateDepth()[depthIndex];
            assertTrue(stats.orientationEntropy() >= 0.75,
                    () -> "depth " + depth + " orientation entropy is " + stats.orientationEntropy());
            assertTrue(stats.principalAxisRatio() < 1.8,
                    () -> "depth " + depth + " principal-axis ratio is " + stats.principalAxisRatio());
            assertTrue(stats.maxAutocorrelation() < 0.35,
                    () -> "depth " + depth + " autocorrelation is " + stats.maxAutocorrelation());
        }

        for (int depthIndex = 0; depthIndex < DEPTHS.length; depthIndex++) {
            for (int timeIndex = 0; timeIndex < TIMES.length; timeIndex++) {
                FrameStats stats = evaluation.candidateFrames()[depthIndex][timeIndex];
                double depth = DEPTHS[depthIndex];
                double time = TIMES[timeIndex];
                assertTrue(stats.mean() >= 0.98 && stats.mean() <= 1.02,
                        () -> "depth/time " + depth + "/" + time + " mean focus is " + stats.mean());
                assertTrue(stats.min() >= 0.45,
                        () -> "depth/time " + depth + "/" + time + " minimum is " + stats.min());
                assertTrue(stats.max() <= 3.2,
                        () -> "depth/time " + depth + "/" + time + " maximum is " + stats.max());
            }
        }
    }

    @Test
    void broadenedDetailMeetsStrictPeakWidthAndSpacingGates() {
        Evaluation evaluation = evaluation();
        List<Executable> checks = new ArrayList<>();

        for (int depthIndex = 1; depthIndex < DEPTHS.length; depthIndex++) {
            double depth = DEPTHS[depthIndex];
            for (int timeIndex = 0; timeIndex < TIMES.length; timeIndex++) {
                double time = TIMES[timeIndex];
                RidgeStats ridges = evaluation.candidateFrames()[depthIndex][timeIndex].ridges();
                checks.add(() -> assertEquals(ridges.peakCount(),
                        ridges.validWidths() + ridges.censoredWidths(),
                        "ridge accounting at depth/time " + depth + "/" + time));
                checks.add(() -> assertTrue(ridges.validWidths() >= RIDGE_MIN_VALID_WIDTHS,
                        () -> "valid ridge widths at depth/time " + depth + "/" + time
                                + " are " + ridges.validWidths()));
                checks.add(() -> assertTrue(ridges.coverage() >= RIDGE_MIN_COVERAGE,
                        () -> "ridge coverage at depth/time " + depth + "/" + time
                                + " is " + ridges.coverage()));
                checks.add(() -> assertTrue(ridges.medianWidth() >= RIDGE_MIN_MEDIAN
                                && ridges.medianWidth() <= RIDGE_MAX_MEDIAN,
                        () -> "ridge median at depth/time " + depth + "/" + time
                                + " is " + ridges.medianWidth()));
                checks.add(() -> assertTrue(ridges.iqrOverMedian() >= RIDGE_MIN_IQR_OVER_MEDIAN
                                && ridges.iqrOverMedian() <= RIDGE_MAX_IQR_OVER_MEDIAN,
                        () -> "ridge IQR/median at depth/time " + depth + "/" + time
                                + " is " + ridges.iqrOverMedian()));
            }
        }

        int threeMetres = 1;
        for (int timeIndex = 0; timeIndex < TIMES.length; timeIndex++) {
            double time = TIMES[timeIndex];
            double candidateMedian = evaluation.candidateFrames()[threeMetres][timeIndex]
                    .ridges().nearestNeighbourMedian();
            double unbroadenedMedian = evaluation.unbroadenedFrames()[threeMetres][timeIndex]
                    .ridges().nearestNeighbourMedian();
            checks.add(() -> assertTrue(Double.isFinite(candidateMedian)
                            && Double.isFinite(unbroadenedMedian)
                            && candidateMedian <= NEAREST_NEIGHBOUR_MAX_RATIO * unbroadenedMedian,
                    () -> "3m nearest-neighbour median at time " + time + " is " + candidateMedian
                            + "; unbroadened=" + unbroadenedMedian
                            + ", ratio=" + candidateMedian / unbroadenedMedian));
        }

        assertAll("strict-peak transverse structure", checks);
    }

    @Test
    void samplingIsDeterministicContinuousAndRebaseInvariant() {
        Evaluation evaluation = evaluation();
        Fixture candidate = candidate();

        for (int depthIndex = 0; depthIndex < DEPTHS.length; depthIndex++) {
            double depth = DEPTHS[depthIndex];
            for (int timeIndex = 0; timeIndex < TIMES.length; timeIndex++) {
                double time = TIMES[timeIndex];
                double[][] expected = evaluation.candidateFocus()[depthIndex][timeIndex];
                double[][] repeat = sampleFocus(depth, time);
                assertFocusEquals(expected, repeat, 0.0,
                        "candidate repeat at depth/time " + depth + "/" + time);

                double[][] rebased = sampleFocus(candidate, depth, time,
                        ORIGIN_X + REBASE_X, ORIGIN_Z + REBASE_Z, -REBASE_X, -REBASE_Z);
                Difference rebaseDifference = difference(expected, rebased);
                System.out.printf(Locale.ROOT,
                        "CAUSTIC_REBASE depth=%.1f time=%.1f mean=%.9g max=%.9g%n",
                        depth, time, rebaseDifference.mean(), rebaseDifference.max());
                assertTrue(rebaseDifference.max() < REBASE_ERROR_LIMIT,
                        () -> "rebase max error at depth/time " + depth + "/" + time
                                + " is " + rebaseDifference.max());
            }

            double[][] current = evaluation.candidateFocus()[depthIndex][1];
            double[][] next = sampleFocus(depth, CONTINUITY_TIME + FRAME_TIME);
            Difference continuity = difference(current, next);
            System.out.printf(Locale.ROOT,
                    "CAUSTIC_CONTINUITY depth=%.1f mean=%.9f max=%.9f%n",
                    depth, continuity.mean(), continuity.max());
            assertTrue(continuity.mean() <= CONTINUITY_MEAN_LIMIT,
                    () -> "1/60s mean delta at depth " + depth + " is " + continuity.mean());
            assertTrue(continuity.max() <= CONTINUITY_MAX_LIMIT,
                    () -> "1/60s max delta at depth " + depth + " is " + continuity.max());
        }
    }

    double[][] sampleFocus(double depth, double time) {
        return sampleFocus(candidate(), depth, time, ORIGIN_X, ORIGIN_Z, 0.0, 0.0);
    }

    private static double applySolarWeight(double focus, double solarWeight) {
        return 1.0 + (focus - 1.0) * solarWeight;
    }

    double localPeakDensity(double[][] focus, double threshold) {
        return strictPeaks(focus, threshold).size() / (GRID_METERS * GRID_METERS);
    }

    private static List<Peak> strictPeaks(double[][] focus, double threshold) {
        List<Peak> peaks = new ArrayList<>();
        for (int z = 1; z < focus.length - 1; z++) {
            for (int x = 1; x < focus[z].length - 1; x++) {
                double value = focus[z][x];
                if (value <= threshold) {
                    continue;
                }
                boolean maximum = true;
                for (int dz = -1; dz <= 1 && maximum; dz++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        if ((dx != 0 || dz != 0) && value <= focus[z + dz][x + dx]) {
                            maximum = false;
                            break;
                        }
                    }
                }
                if (maximum) {
                    peaks.add(new Peak(x, z));
                }
            }
        }
        return peaks;
    }

    double orientationEntropy(double[][] focus) {
        double[] bins = new double[12];
        double totalWeight = 0.0;
        for (int z = 1; z < focus.length - 1; z++) {
            for (int x = 1; x < focus[z].length - 1; x++) {
                double gx = (focus[z][x + 1] - focus[z][x - 1]) / (2.0 * SAMPLE_STEP);
                double gz = (focus[z + 1][x] - focus[z - 1][x]) / (2.0 * SAMPLE_STEP);
                double weight = Math.hypot(gx, gz);
                if (weight <= 1.0e-12) {
                    continue;
                }
                double orientation = Math.atan2(gz, gx) % Math.PI;
                if (orientation < 0.0) {
                    orientation += Math.PI;
                }
                int bin = Math.min(11, (int) Math.floor(orientation * 12.0 / Math.PI));
                bins[bin] += weight;
                totalWeight += weight;
            }
        }
        if (totalWeight <= 0.0) {
            return 0.0;
        }
        double entropy = 0.0;
        for (double bin : bins) {
            if (bin > 0.0) {
                double probability = bin / totalWeight;
                entropy -= probability * Math.log(probability);
            }
        }
        return entropy / Math.log(bins.length);
    }

    double principalAxisRatio(double[][] focus) {
        double xx = 0.0;
        double xz = 0.0;
        double zz = 0.0;
        for (int z = 1; z < focus.length - 1; z++) {
            for (int x = 1; x < focus[z].length - 1; x++) {
                double gx = (focus[z][x + 1] - focus[z][x - 1]) / (2.0 * SAMPLE_STEP);
                double gz = (focus[z + 1][x] - focus[z - 1][x]) / (2.0 * SAMPLE_STEP);
                xx += gx * gx;
                xz += gx * gz;
                zz += gz * gz;
            }
        }
        double trace = xx + zz;
        double discriminant = Math.sqrt(Math.max(0.0, (xx - zz) * (xx - zz) + 4.0 * xz * xz));
        double major = 0.5 * (trace + discriminant);
        double minor = 0.5 * (trace - discriminant);
        return (major + 1.0e-12) / (minor + 1.0e-12);
    }

    double maxNonZeroAutocorrelation(double[][] focus) {
        double maximum = -1.0;
        for (double distance = 0.5; distance <= 8.0 + 1.0e-9; distance += 0.5) {
            for (int direction = 0; direction < 8; direction++) {
                double angle = direction * Math.PI / 4.0;
                int dx = (int) Math.round(distance * Math.cos(angle) / SAMPLE_STEP);
                int dz = (int) Math.round(distance * Math.sin(angle) / SAMPLE_STEP);
                if (dx == 0 && dz == 0) {
                    continue;
                }
                maximum = Math.max(maximum, correlationAtOffset(focus, dx, dz));
            }
        }
        return maximum;
    }

    RidgeStats strictPeakTransverseWidths(double[][] focus) {
        List<Peak> peaks = strictPeaks(focus, PEAK_THRESHOLD);
        List<Double> widths = new ArrayList<>();
        int censored = 0;
        for (Peak peak : peaks) {
            Normal normal = mostNegativeHessianNormal(focus, peak.x(), peak.z());
            if (!Double.isFinite(normal.x()) || !Double.isFinite(normal.z())) {
                censored++;
                continue;
            }

            double endpointPixels = RIDGE_BASELINE_DISTANCE / SAMPLE_STEP;
            double plusX = peak.x() + normal.x() * endpointPixels;
            double plusZ = peak.z() + normal.z() * endpointPixels;
            double minusX = peak.x() - normal.x() * endpointPixels;
            double minusZ = peak.z() - normal.z() * endpointPixels;
            if (!inside(focus, plusX, plusZ) || !inside(focus, minusX, minusZ)) {
                censored++;
                continue;
            }

            double peakValue = focus[peak.z()][peak.x()];
            double baseline = Math.min(
                    bilinear(focus, plusX, plusZ), bilinear(focus, minusX, minusZ));
            if (!Double.isFinite(baseline) || !(peakValue > baseline)) {
                censored++;
                continue;
            }
            double halfProminence = baseline + 0.5 * (peakValue - baseline);
            double plus = firstHalfProminenceCrossing(focus, peak, normal, 1.0, halfProminence);
            double minus = firstHalfProminenceCrossing(focus, peak, normal, -1.0, halfProminence);
            double width = plus + minus;
            if (!Double.isFinite(plus) || !Double.isFinite(minus)
                    || !(width > 0.0) || width > RIDGE_WIDTH_LIMIT + 1.0e-12) {
                censored++;
                continue;
            }
            widths.add(width);
        }

        Distribution widthDistribution = distribution(widths);
        Distribution nearestNeighbours = nearestNeighbourDistribution(peaks);
        double coverage = peaks.isEmpty() ? Double.NaN : (double) widths.size() / peaks.size();
        return new RidgeStats(peaks.size(), widths.size(), censored, coverage,
                widthDistribution.median(), widthDistribution.iqrOverMedian(),
                nearestNeighbours.median(), nearestNeighbours.coefficientOfVariation());
    }

    private static Normal mostNegativeHessianNormal(double[][] focus, int x, int z) {
        double center = focus[z][x];
        double inverseH2 = 1.0 / (SAMPLE_STEP * SAMPLE_STEP);
        double fxx = (focus[z][x + 1] - 2.0 * center + focus[z][x - 1]) * inverseH2;
        double fzz = (focus[z + 1][x] - 2.0 * center + focus[z - 1][x]) * inverseH2;
        double fxz = (focus[z + 1][x + 1] - focus[z + 1][x - 1]
                - focus[z - 1][x + 1] + focus[z - 1][x - 1]) * 0.25 * inverseH2;
        double trace = fxx + fzz;
        double minimumEigenvalue = 0.5 * (trace - Math.hypot(fxx - fzz, 2.0 * fxz));
        double nx = fxz;
        double nz = minimumEigenvalue - fxx;
        double length = Math.hypot(nx, nz);
        if (length <= 1.0e-15) {
            nx = minimumEigenvalue - fzz;
            nz = fxz;
            length = Math.hypot(nx, nz);
        }
        if (length <= 1.0e-15) {
            return fxx <= fzz ? new Normal(1.0, 0.0) : new Normal(0.0, 1.0);
        }
        return new Normal(nx / length, nz / length);
    }

    private static double firstHalfProminenceCrossing(double[][] focus, Peak peak,
            Normal normal, double sign, double level) {
        double previousDistance = 0.0;
        double previousValue = focus[peak.z()][peak.x()];
        int steps = (int) Math.round(RIDGE_BASELINE_DISTANCE / RIDGE_PROFILE_STEP);
        for (int index = 1; index <= steps; index++) {
            double distance = index * RIDGE_PROFILE_STEP;
            double offsetPixels = sign * distance / SAMPLE_STEP;
            double x = peak.x() + normal.x() * offsetPixels;
            double z = peak.z() + normal.z() * offsetPixels;
            if (!inside(focus, x, z)) {
                return Double.NaN;
            }
            double value = bilinear(focus, x, z);
            if (value <= level) {
                double denominator = previousValue - value;
                double amount = denominator <= 0.0
                        ? 1.0 : (previousValue - level) / denominator;
                amount = clamp(amount, 0.0, 1.0);
                return previousDistance + amount * (distance - previousDistance);
            }
            previousDistance = distance;
            previousValue = value;
        }
        return Double.NaN;
    }

    private static boolean inside(double[][] focus, double x, double z) {
        return x >= 0.0 && z >= 0.0
                && x <= focus[0].length - 1.0 && z <= focus.length - 1.0;
    }

    private static double bilinear(double[][] focus, double x, double z) {
        int x0 = (int) Math.floor(x);
        int z0 = (int) Math.floor(z);
        int x1 = Math.min(x0 + 1, focus[0].length - 1);
        int z1 = Math.min(z0 + 1, focus.length - 1);
        double tx = x - x0;
        double tz = z - z0;
        double top = focus[z0][x0] + (focus[z0][x1] - focus[z0][x0]) * tx;
        double bottom = focus[z1][x0] + (focus[z1][x1] - focus[z1][x0]) * tx;
        return top + (bottom - top) * tz;
    }

    private static Distribution nearestNeighbourDistribution(List<Peak> peaks) {
        if (peaks.size() < 2) {
            return Distribution.empty();
        }
        List<Double> distances = new ArrayList<>(peaks.size());
        for (int first = 0; first < peaks.size(); first++) {
            Peak origin = peaks.get(first);
            double nearestSquared = Double.POSITIVE_INFINITY;
            for (int second = 0; second < peaks.size(); second++) {
                if (first == second) {
                    continue;
                }
                Peak other = peaks.get(second);
                double dx = (origin.x() - other.x()) * SAMPLE_STEP;
                double dz = (origin.z() - other.z()) * SAMPLE_STEP;
                nearestSquared = Math.min(nearestSquared, dx * dx + dz * dz);
            }
            distances.add(Math.sqrt(nearestSquared));
        }
        return distribution(distances);
    }

    private static Distribution distribution(List<Double> values) {
        if (values.isEmpty()) {
            return Distribution.empty();
        }
        values.sort(Comparator.naturalOrder());
        double median = quantile(values, 0.5);
        double firstQuartile = quantile(values, 0.25);
        double thirdQuartile = quantile(values, 0.75);
        double mean = values.stream().mapToDouble(Double::doubleValue).average().orElseThrow();
        double variance = 0.0;
        for (double value : values) {
            double delta = value - mean;
            variance += delta * delta;
        }
        variance /= values.size();
        return new Distribution(median, Math.sqrt(variance) / mean,
                (thirdQuartile - firstQuartile) / median);
    }

    private static double quantile(List<Double> sorted, double probability) {
        if (sorted.size() == 1) {
            return sorted.get(0);
        }
        double index = (sorted.size() - 1.0) * probability;
        int lower = (int) Math.floor(index);
        int upper = (int) Math.ceil(index);
        double amount = index - lower;
        return sorted.get(lower) + (sorted.get(upper) - sorted.get(lower)) * amount;
    }

    private Evaluation evaluation() {
        if (cachedEvaluation != null) {
            return cachedEvaluation;
        }
        Fixture candidate = candidate();
        Fixture unbroadened = UnbroadenedDetail.fixture(candidate);
        double[][][][] candidateFocus = new double[DEPTHS.length][TIMES.length][][];
        FrameStats[][] candidateFrames = new FrameStats[DEPTHS.length][TIMES.length];
        FrameStats[][] baselineFrames = new FrameStats[DEPTHS.length][TIMES.length];
        FrameStats[][] unbroadenedFrames = new FrameStats[DEPTHS.length][TIMES.length];
        for (int depthIndex = 0; depthIndex < DEPTHS.length; depthIndex++) {
            for (int timeIndex = 0; timeIndex < TIMES.length; timeIndex++) {
                double depth = DEPTHS[depthIndex];
                double time = TIMES[timeIndex];
                candidateFocus[depthIndex][timeIndex] = sampleFocus(candidate, depth, time,
                        ORIGIN_X, ORIGIN_Z, 0.0, 0.0);
                candidateFrames[depthIndex][timeIndex] = frameStats(candidateFocus[depthIndex][timeIndex]);
                double[][] baseline = sampleFocus(Baseline042.FIXTURE, depth, time,
                        ORIGIN_X, ORIGIN_Z, 0.0, 0.0);
                baselineFrames[depthIndex][timeIndex] = frameStats(baseline);
                double[][] originalDetail = sampleFocus(unbroadened, depth, time,
                        ORIGIN_X, ORIGIN_Z, 0.0, 0.0);
                unbroadenedFrames[depthIndex][timeIndex] = frameStats(originalDetail);
            }
        }
        DepthStats[] candidateDepth = depthAverages(candidateFrames);
        DepthStats[] baselineDepth = depthAverages(baselineFrames);
        DepthStats[] unbroadenedDepth = depthAverages(unbroadenedFrames);
        cachedEvaluation = new Evaluation(candidateFocus, candidateFrames, baselineFrames,
                unbroadenedFrames, candidateDepth, baselineDepth, unbroadenedDepth);
        return cachedEvaluation;
    }

    private FrameStats frameStats(double[][] focus) {
        double sum = 0.0;
        double minimum = Double.POSITIVE_INFINITY;
        double maximum = Double.NEGATIVE_INFINITY;
        for (double[] row : focus) {
            for (double value : row) {
                sum += value;
                minimum = Math.min(minimum, value);
                maximum = Math.max(maximum, value);
            }
        }
        RidgeStats ridges = strictPeakTransverseWidths(focus);
        return new FrameStats(
                ridges.peakCount() / (GRID_METERS * GRID_METERS),
                orientationEntropy(focus),
                principalAxisRatio(focus),
                maxNonZeroAutocorrelation(focus),
                ridges,
                sum / (focus.length * focus[0].length),
                minimum,
                maximum);
    }

    private static DepthStats[] depthAverages(FrameStats[][] frames) {
        DepthStats[] result = new DepthStats[frames.length];
        for (int depth = 0; depth < frames.length; depth++) {
            double peak = 0.0;
            double entropy = 0.0;
            double axis = 0.0;
            double autocorrelation = 0.0;
            for (FrameStats frame : frames[depth]) {
                peak += frame.peakDensity();
                entropy += frame.orientationEntropy();
                axis += frame.principalAxisRatio();
                autocorrelation += frame.maxAutocorrelation();
            }
            double count = frames[depth].length;
            result[depth] = new DepthStats(peak / count, entropy / count, axis / count,
                    autocorrelation / count);
        }
        return result;
    }

    private static double[][] sampleFocus(Fixture fixture, double depth, double time,
            double originX, double originZ, double anchorX, double anchorZ) {
        double[][] focus = new double[GRID_SIZE][GRID_SIZE];
        for (int z = 0; z < GRID_SIZE; z++) {
            double receiverZ = originZ + z * SAMPLE_STEP;
            for (int x = 0; x < GRID_SIZE; x++) {
                double receiverX = originX + x * SAMPLE_STEP;
                focus[z][x] = focusAt(fixture, receiverX, receiverZ,
                        anchorX, anchorZ, depth, time);
            }
        }
        return focus;
    }

    private static double focusAt(Fixture fixture, double receiverX, double receiverZ,
            double anchorX, double anchorZ, double depth, double time) {
        if (STRENGTH <= 0.0) {
            return 1.0;
        }
        double fade = smoothstep(0.06, 0.18, LIGHT_Y);
        if (fade <= 0.0) {
            return 1.0;
        }
        double h = Math.max(depth, 0.05);
        double stableLightDistance = depth / Math.max(LIGHT_Y, 0.05);
        double baseX = receiverX + LIGHT_X * stableLightDistance + anchorX;
        double baseZ = receiverZ + LIGHT_Z * stableLightDistance + anchorZ;
        double depthBlur = smoothstep(0.0, fixture.causticFadeStart(), h);
        double lodFootprint = lerp(fixture.lodNear(), fixture.lodFar(), depthBlur);
        double jacobianEps = fixture.splitJacobianAndLod()
                ? fixture.jacobianEps() : lodFootprint;

        Landing p0 = landing(fixture, baseX, baseZ, time, h, lodFootprint);
        Landing px = landing(fixture, baseX + jacobianEps, baseZ, time, h, lodFootprint);
        Landing pz = landing(fixture, baseX, baseZ + jacobianEps, time, h, lodFootprint);
        double determinant = Math.abs((px.x() - p0.x()) * (pz.z() - p0.z())
                - (px.z() - p0.z()) * (pz.x() - p0.x()));
        double physicalFocus = (jacobianEps * jacobianEps) / Math.max(determinant, 1.0e-5);
        double softFocus = Math.pow(Math.max(physicalFocus, 1.0e-4), 0.72);
        double shallowWeight = 1.0 - smoothstep(0.25, 3.5, h);
        double shallowContrast = lerp(1.0, fixture.causticShallowContrast(), shallowWeight);
        double amplitudeResponse = clamp(STRENGTH, 0.0, 2.0);
        double shapedFocus = 1.0 + (softFocus - 1.0) * shallowContrast * amplitudeResponse;
        double boundedFocus = clamp(shapedFocus, fixture.causticMin(), fixture.causticMax());
        double deepFade = smoothstep(fixture.causticFadeStart(), fixture.causticFadeEnd(), h);
        return lerp(1.0, boundedFocus, fade * (1.0 - deepFade));
    }

    private static Landing landing(Fixture fixture, double x, double z, double time,
            double height, double lodFootprint) {
        Gradient gradient = causticGradient(fixture, x, z, time, lodFootprint);
        double normalLength = Math.sqrt(gradient.x() * gradient.x() + 1.0
                + gradient.z() * gradient.z());
        double nx = -gradient.x() / normalLength;
        double ny = 1.0 / normalLength;
        double nz = -gradient.z() / normalLength;
        double ix = -LIGHT_X;
        double iy = -LIGHT_Y;
        double iz = -LIGHT_Z;
        double eta = 1.0 / fixture.waterIor();
        double incidentDotNormal = ix * nx + iy * ny + iz * nz;
        double refractDiscriminant = 1.0 - eta * eta
                * (1.0 - incidentDotNormal * incidentDotNormal);
        if (refractDiscriminant < 0.0) {
            return new Landing(x, z);
        }
        double normalScale = eta * incidentDotNormal + Math.sqrt(refractDiscriminant);
        double rx = eta * ix - normalScale * nx;
        double ry = eta * iy - normalScale * ny;
        double rz = eta * iz - normalScale * nz;
        double distance = height / Math.max(-ry, 0.05);
        return new Landing(x + rx * distance, z + rz * distance);
    }

    private static Gradient causticGradient(Fixture fixture, double x, double z,
            double time, double footprint) {
        Gradient base = spectrumGradient(fixture, fixture.base(), x, z, time, footprint, null);
        Gradient detail = fixture.detail().wavelength().length == 0
                ? new Gradient(0.0, 0.0)
                : spectrumGradient(fixture, fixture.detail(), x, z, time, footprint, fixture.warp());
        double scale = clamp(STRENGTH, 0.0, 2.0) * fixture.causticGain();
        double gx = (base.x() + detail.x()) * scale;
        double gz = (base.z() + detail.z()) * scale;
        double slope = Math.hypot(gx, gz);
        if (slope > fixture.causticMaxSlope()) {
            double bound = fixture.causticMaxSlope() / slope;
            gx *= bound;
            gz *= bound;
        }
        return new Gradient(gx, gz);
    }

    private static Gradient spectrumGradient(Fixture fixture, Spectrum spectrum,
            double x, double z, double rawTime, double footprint, Warp warp) {
        double warpedX = x;
        double warpedZ = z;
        double warpDxX = 0.0;
        double warpDxZ = 0.0;
        double warpDzX = 0.0;
        double warpDzZ = 0.0;
        if (warp != null) {
            double[] values = warp.values();
            double phaseX = values[1] * x + values[2] * z - values[3] * rawTime + values[4];
            double phaseZ = values[5] * x + values[6] * z + values[7] * rawTime + values[8];
            warpedX += values[0] * Math.sin(phaseX);
            warpedZ += values[0] * Math.sin(phaseZ);
            double cosX = Math.cos(phaseX);
            double cosZ = Math.cos(phaseZ);
            warpDxX = values[0] * values[1] * cosX;
            warpDxZ = values[0] * values[5] * cosZ;
            warpDzX = values[0] * values[2] * cosX;
            warpDzZ = values[0] * values[6] * cosZ;
        }

        double time = rawTime * fixture.waveSpeed();
        double gx = 0.0;
        double gz = 0.0;
        for (int index = 0; index < spectrum.wavelength().length; index++) {
            double wavelength = spectrum.wavelength()[index];
            double lodWeight = waterWaveLodWeight(wavelength, footprint);
            if (lodWeight <= 0.0) {
                continue;
            }
            double k = 2.0 * PI / wavelength;
            double omega = Math.sqrt(fixture.waveG() * k);
            double angle = spectrum.directionOffset()[index];
            double cosine = Math.cos(angle);
            double sine = Math.sin(angle);
            double directionX = fixture.windX() * cosine - fixture.windZ() * sine;
            double directionZ = fixture.windX() * sine + fixture.windZ() * cosine;
            double perpendicularX = -directionZ;
            double perpendicularZ = directionX;
            double phase = k * (directionX * warpedX + directionZ * warpedZ)
                    - omega * time + spectrum.phaseOffset()[index];
            double phaseGradientX = k * directionX;
            double phaseGradientZ = k * directionZ;
            double meanderSpatialRate = spectrum.meanderScale()[index] * k;
            double meanderPhaseSpeed = spectrum.meanderSpeed()[index] * omega;
            double meanderPhase = meanderSpatialRate
                    * (perpendicularX * warpedX + perpendicularZ * warpedZ)
                    + meanderPhaseSpeed * time + spectrum.meanderOffset()[index];
            phase += spectrum.meanderAmplitude()[index] * Math.sin(meanderPhase);
            double meanderGradientScale = spectrum.meanderAmplitude()[index]
                    * Math.cos(meanderPhase) * meanderSpatialRate;
            phaseGradientX += meanderGradientScale * perpendicularX;
            phaseGradientZ += meanderGradientScale * perpendicularZ;
            if (warp != null) {
                double qGradientX = phaseGradientX;
                double qGradientZ = phaseGradientZ;
                phaseGradientX = qGradientX * (1.0 + warpDxX) + qGradientZ * warpDxZ;
                phaseGradientZ = qGradientX * warpDzX + qGradientZ * (1.0 + warpDzZ);
            }
            double sharpness = spectrum.sharpness()[index];
            double sinPhase = Math.sin(phase);
            double cosPhase = Math.cos(phase);
            double exponential = Math.exp(sharpness * (sinPhase - 1.0));
            double amplitude = lodWeight * (spectrum.energy()[index] / k) * sharpness;
            gx += amplitude * cosPhase * exponential * phaseGradientX;
            gz += amplitude * cosPhase * exponential * phaseGradientZ;
        }
        return new Gradient(gx * fixture.waveStrength(), gz * fixture.waveStrength());
    }

    private static double waterWaveLodWeight(double wavelength, double footprint) {
        double cyclesPerPixel = Math.max(footprint, 0.0) / Math.max(wavelength, 1.0e-4);
        return 1.0 - smoothstep(0.25, 0.5, cyclesPerPixel);
    }

    private static double correlationAtOffset(double[][] focus, int dx, int dz) {
        int minX = Math.max(0, -dx);
        int maxX = Math.min(focus[0].length, focus[0].length - dx);
        int minZ = Math.max(0, -dz);
        int maxZ = Math.min(focus.length, focus.length - dz);
        double sumA = 0.0;
        double sumB = 0.0;
        double sumAA = 0.0;
        double sumBB = 0.0;
        double sumAB = 0.0;
        long count = 0;
        for (int z = minZ; z < maxZ; z++) {
            for (int x = minX; x < maxX; x++) {
                double a = focus[z][x];
                double b = focus[z + dz][x + dx];
                sumA += a;
                sumB += b;
                sumAA += a * a;
                sumBB += b * b;
                sumAB += a * b;
                count++;
            }
        }
        double covariance = sumAB - sumA * sumB / count;
        double varianceA = sumAA - sumA * sumA / count;
        double varianceB = sumBB - sumB * sumB / count;
        double denominator = Math.sqrt(Math.max(0.0, varianceA * varianceB));
        return denominator <= 1.0e-20 ? 0.0 : covariance / denominator;
    }

    private static Difference difference(double[][] first, double[][] second) {
        double sum = 0.0;
        double maximum = 0.0;
        long count = 0;
        for (int z = 0; z < first.length; z++) {
            for (int x = 0; x < first[z].length; x++) {
                double delta = Math.abs(first[z][x] - second[z][x]);
                sum += delta;
                maximum = Math.max(maximum, delta);
                count++;
            }
        }
        return new Difference(sum / count, maximum);
    }

    private static void assertFocusEquals(double[][] expected, double[][] actual,
            double tolerance, String message) {
        assertEquals(expected.length, actual.length, message + " row count");
        for (int row = 0; row < expected.length; row++) {
            assertArrayEquals(expected[row], actual[row], tolerance, message + " row " + row);
        }
    }

    private static void assertSpectrumEquals(Spectrum expected, Spectrum actual) {
        assertArrayEquals(expected.wavelength(), actual.wavelength(), 0.0);
        assertArrayEquals(expected.directionOffset(), actual.directionOffset(), 0.0);
        assertArrayEquals(expected.energy(), actual.energy(), 0.0);
        assertArrayEquals(expected.phaseOffset(), actual.phaseOffset(), 0.0);
        assertArrayEquals(expected.sharpness(), actual.sharpness(), 0.0);
        assertArrayEquals(expected.meanderAmplitude(), actual.meanderAmplitude(), 0.0);
        assertArrayEquals(expected.meanderScale(), actual.meanderScale(), 0.0);
        assertArrayEquals(expected.meanderSpeed(), actual.meanderSpeed(), 0.0);
        assertArrayEquals(expected.meanderOffset(), actual.meanderOffset(), 0.0);
    }

    private static void printMetricTable(Evaluation evaluation) {
        for (int depthIndex = 0; depthIndex < DEPTHS.length; depthIndex++) {
            for (int timeIndex = 0; timeIndex < TIMES.length; timeIndex++) {
                printMetricLine("candidate", DEPTHS[depthIndex], TIMES[timeIndex],
                        evaluation.candidateFrames()[depthIndex][timeIndex]);
                printMetricLine("baseline042", DEPTHS[depthIndex], TIMES[timeIndex],
                        evaluation.baselineFrames()[depthIndex][timeIndex]);
                printMetricLine("unbroadened-detail", DEPTHS[depthIndex], TIMES[timeIndex],
                        evaluation.unbroadenedFrames()[depthIndex][timeIndex]);
            }
            printDepthLine("candidate-avg", DEPTHS[depthIndex], evaluation.candidateDepth()[depthIndex]);
            printDepthLine("baseline042-avg", DEPTHS[depthIndex], evaluation.baselineDepth()[depthIndex]);
            printDepthLine("unbroadened-detail-avg", DEPTHS[depthIndex],
                    evaluation.unbroadenedDepth()[depthIndex]);
        }
    }

    private static void printMetricLine(String fixture, double depth, double time, FrameStats stats) {
        RidgeStats ridges = stats.ridges();
        System.out.printf(Locale.ROOT,
                "CAUSTIC_METRIC fixture=%s depth=%.1f time=%.1f peaks=%d peak=%.9f entropy=%.9f axis=%.9f autocorr=%.9f ridgeValid=%d ridgeCensored=%d ridgeCoverage=%.9f ridgeMedian=%.12f ridgeIqrRatio=%.12f nnMedian=%.12f nnCv=%.12f mean=%.12f min=%.12f max=%.12f%n",
                fixture, depth, time, ridges.peakCount(), stats.peakDensity(),
                stats.orientationEntropy(), stats.principalAxisRatio(), stats.maxAutocorrelation(),
                ridges.validWidths(), ridges.censoredWidths(), ridges.coverage(),
                ridges.medianWidth(), ridges.iqrOverMedian(), ridges.nearestNeighbourMedian(),
                ridges.nearestNeighbourCv(), stats.mean(), stats.min(), stats.max());
    }

    private static void printDepthLine(String fixture, double depth, DepthStats stats) {
        System.out.printf(Locale.ROOT,
                "CAUSTIC_DEPTH fixture=%s depth=%.1f peak=%.12f entropy=%.12f axis=%.12f autocorr=%.12f%n",
                fixture, depth, stats.peakDensity(), stats.orientationEntropy(),
                stats.principalAxisRatio(), stats.maxAutocorrelation());
    }

    private Fixture candidate() {
        if (candidateFixture == null) {
            candidateFixture = ShaderParser.parseCandidate();
        }
        return candidateFixture;
    }

    private static double smoothstep(double edge0, double edge1, double value) {
        double t = clamp((value - edge0) / (edge1 - edge0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    private static double clamp(double value, double minimum, double maximum) {
        return Math.max(minimum, Math.min(maximum, value));
    }

    private static double lerp(double first, double second, double amount) {
        return first + (second - first) * amount;
    }

    record RidgeStats(int peakCount, int validWidths, int censoredWidths, double coverage,
            double medianWidth, double iqrOverMedian, double nearestNeighbourMedian,
            double nearestNeighbourCv) {
    }

    private record Peak(int x, int z) {
    }

    private record Normal(double x, double z) {
    }

    private record Distribution(double median, double coefficientOfVariation,
            double iqrOverMedian) {
        private static Distribution empty() {
            return new Distribution(Double.NaN, Double.NaN, Double.NaN);
        }
    }

    private record Gradient(double x, double z) {
    }

    private record Landing(double x, double z) {
    }

    private record Difference(double mean, double max) {
    }

    private record FrameStats(double peakDensity, double orientationEntropy,
            double principalAxisRatio, double maxAutocorrelation, RidgeStats ridges,
            double mean, double min, double max) {
    }

    private record DepthStats(double peakDensity, double orientationEntropy,
            double principalAxisRatio, double maxAutocorrelation) {
    }

    private record Evaluation(double[][][][] candidateFocus, FrameStats[][] candidateFrames,
            FrameStats[][] baselineFrames, FrameStats[][] unbroadenedFrames,
            DepthStats[] candidateDepth, DepthStats[] baselineDepth,
            DepthStats[] unbroadenedDepth) {
    }

    private record Spectrum(double[] wavelength, double[] directionOffset, double[] energy,
            double[] phaseOffset, double[] sharpness, double[] meanderAmplitude,
            double[] meanderScale, double[] meanderSpeed, double[] meanderOffset) {
        private static Spectrum empty() {
            return new Spectrum(new double[0], new double[0], new double[0], new double[0],
                    new double[0], new double[0], new double[0], new double[0], new double[0]);
        }
    }

    private record Warp(double[] values) {
    }

    private record Fixture(double waveStrength, double waveSpeed, double waveG,
            double windX, double windZ, Spectrum base, Spectrum detail, Warp warp,
            double surfaceGain, double refractionGain, double refractionMaxSlope,
            int refractionComponentCount, double refractionMinFootprint,
            double causticGain, double causticMaxSlope, double jacobianEps,
            double lodNear, double lodFar, boolean splitJacobianAndLod,
            double causticShallowContrast, double causticMin, double causticMax,
            double causticFadeStart, double causticFadeEnd, double waterIor) {
    }

    private static final class UnbroadenedDetail {
        private static final double[] ENERGY = {0.015, 0.014, 0.013, 0.011, 0.009, 0.007};
        private static final double[] SHARPNESS = {1.72, 1.80, 1.88, 1.96, 2.04, 2.12};

        private static Fixture fixture(Fixture candidate) {
            Spectrum detail = candidate.detail();
            Spectrum originalDetail = new Spectrum(
                    detail.wavelength().clone(), detail.directionOffset().clone(), ENERGY.clone(),
                    detail.phaseOffset().clone(), SHARPNESS.clone(),
                    detail.meanderAmplitude().clone(), detail.meanderScale().clone(),
                    detail.meanderSpeed().clone(), detail.meanderOffset().clone());
            Spectrum base = copySpectrum(candidate.base());
            Warp warp = candidate.warp() == null ? null : new Warp(candidate.warp().values().clone());
            return new Fixture(
                    candidate.waveStrength(), candidate.waveSpeed(), candidate.waveG(),
                    candidate.windX(), candidate.windZ(), base, originalDetail, warp,
                    candidate.surfaceGain(), candidate.refractionGain(),
                    candidate.refractionMaxSlope(), candidate.refractionComponentCount(),
                    candidate.refractionMinFootprint(), candidate.causticGain(),
                    candidate.causticMaxSlope(), candidate.jacobianEps(), candidate.lodNear(),
                    candidate.lodFar(), candidate.splitJacobianAndLod(),
                    candidate.causticShallowContrast(), candidate.causticMin(),
                    candidate.causticMax(), candidate.causticFadeStart(),
                    candidate.causticFadeEnd(), candidate.waterIor());
        }

        private static Spectrum copySpectrum(Spectrum source) {
            return new Spectrum(
                    source.wavelength().clone(), source.directionOffset().clone(),
                    source.energy().clone(), source.phaseOffset().clone(),
                    source.sharpness().clone(), source.meanderAmplitude().clone(),
                    source.meanderScale().clone(), source.meanderSpeed().clone(),
                    source.meanderOffset().clone());
        }

        private UnbroadenedDetail() {
        }
    }

    private static final class Baseline042 {
        private static final Spectrum BASE = new Spectrum(
                new double[] {18.70, 13.10, 9.40, 6.20, 4.70, 3.15, 2.38, 1.54, 1.17, 0.73, 0.52, 0.37},
                new double[] {-0.12, 0.19, -0.48, 0.72, -0.93, 1.17, -1.36, 0.44, 1.53, -0.69, 1.94, -1.71},
                new double[] {0.028, 0.031, 0.030, 0.029, 0.027, 0.025, 0.022, 0.019, 0.016, 0.013, 0.010, 0.008},
                new double[] {0.37, 2.11, 4.73, 1.28, 5.41, 3.02, 0.83, 4.16, 2.67, 5.92, 1.74, 3.58},
                new double[] {1.10, 1.18, 1.27, 1.34, 1.40, 1.46, 1.52, 1.58, 1.64, 1.70, 1.76, 1.82},
                new double[] {0.95, 0.82, 0.73, 0.66, 0.58, 0.51, 0.45, 0.39, 0.34, 0.29, 0.25, 0.21},
                new double[] {0.23, 0.31, 0.27, 0.36, 0.29, 0.41, 0.33, 0.38, 0.26, 0.43, 0.35, 0.30},
                new double[] {0.38, -0.27, 0.44, -0.32, 0.24, -0.41, 0.35, -0.22, 0.47, -0.30, 0.28, -0.39},
                new double[] {1.13, 4.29, 2.54, 5.77, 0.68, 3.91, 1.86, 4.97, 2.21, 5.38, 0.34, 3.46});
        private static final double WIND_LENGTH = Math.sqrt(1.0 + 0.35 * 0.35);
        private static final Fixture FIXTURE = new Fixture(
                0.3, 0.8, 9.81, 1.0 / WIND_LENGTH, 0.35 / WIND_LENGTH,
                BASE, Spectrum.empty(), null,
                1.50, 0.45, 0.12, 8, 0.35,
                1.35, 0.45, Double.NaN, 0.08, 0.65, false,
                1.65, 0.45, 3.2, 12.0, 42.0, 1.333);

        private Baseline042() {
        }
    }

    private static final class ShaderParser {
        private static final String NUMBER = "(?<![A-Za-z_])[-+]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][-+]?\\d+)?(?![A-Za-z_])";

        private static Fixture parseCandidate() {
            String water = read(WATER_SHADER);
            String core = read(WORLD_CORE_SHADER);
            String code = removeComments(water);
            String coreCode = removeComments(core);
            String baseFunction = functionSection(code, "public void waterWaveSpectrum");
            String detailFunction = functionSection(code, "public void waterCausticDetailSpectrum");
            String surfaceFunction = functionSection(code, "public float2 waterSurfaceGrad");
            String refractionFunction = functionSection(code, "public float2 waterRefractionGrad");
            if (surfaceFunction.contains("waterCausticDetailSpectrum")
                    || refractionFunction.contains("waterCausticDetailSpectrum")) {
                throw new AssertionError("Surface/refraction consumes caustic detail");
            }

            int baseCount = intConstant(code, "WAVE_COMPONENT_COUNT");
            int detailCount = intConstant(code, "CAUSTIC_DETAIL_COMPONENT_COUNT");
            Spectrum base = spectrum(baseFunction, baseCount);
            Spectrum detail = spectrum(detailFunction, detailCount);
            requireExact("detail wavelength", detail.wavelength(), DETAIL_WAVELENGTH);
            requireExact("detail directionOffset", detail.directionOffset(), DETAIL_DIRECTION);
            requireExact("detail meanderAmplitude", detail.meanderAmplitude(), DETAIL_MEANDER_AMPLITUDE);
            requireExact("detail phaseOffset", detail.phaseOffset(), DETAIL_PHASE);
            requireExact("detail meanderScale", detail.meanderScale(), DETAIL_MEANDER_SCALE);
            requireExact("detail meanderSpeed", detail.meanderSpeed(), DETAIL_MEANDER_SPEED);
            requireExact("detail meanderOffset", detail.meanderOffset(), DETAIL_MEANDER_OFFSET);
            requireSpectrumExact("base", base, Baseline042.BASE);

            double[] wind = normalizedFloat2Constant(code, "WAVE_WIND");
            double[] warpNumbers = statementNumbers(detailFunction, "float2 warp =");
            requireExact("detail warp", warpNumbers, DETAIL_WARP);
            return new Fixture(
                    floatConstant(code, "WATER_WAVE_STRENGTH"),
                    floatConstant(code, "WAVE_SPEED"),
                    floatConstant(code, "WAVE_G"),
                    wind[0], wind[1], base, detail, new Warp(warpNumbers),
                    floatConstant(code, "WATER_SURFACE_GAIN"),
                    floatConstant(code, "WATER_REFRACTION_GAIN"),
                    floatConstant(code, "WATER_REFRACTION_MAX_SLOPE"),
                    intConstant(code, "WATER_REFRACTION_COMPONENT_COUNT"),
                    floatConstant(code, "WATER_REFRACTION_MIN_FOOTPRINT"),
                    floatConstant(code, "WATER_CAUSTIC_GAIN"),
                    floatConstant(code, "WATER_CAUSTIC_MAX_SLOPE"),
                    floatConstant(code, "CAUSTIC_JACOBIAN_EPS"),
                    floatConstant(code, "CAUSTIC_LOD_NEAR"),
                    floatConstant(code, "CAUSTIC_LOD_FAR"), true,
                    floatConstant(code, "CAUSTIC_SHALLOW_CONTRAST"),
                    floatConstant(code, "CAUSTIC_MIN"),
                    floatConstant(code, "CAUSTIC_MAX"),
                    floatConstant(code, "CAUSTIC_FADE_START"),
                    floatConstant(code, "CAUSTIC_FADE_END"),
                    floatConstant(coreCode, "WATER_IOR"));
        }

        private static Spectrum spectrum(String function, int expectedCount) {
            return new Spectrum(
                    array(function, "wavelength", expectedCount),
                    array(function, "directionOffset", expectedCount),
                    array(function, "energy", expectedCount),
                    array(function, "phaseOffset", expectedCount),
                    array(function, "sharpness", expectedCount),
                    array(function, "meanderAmplitude", expectedCount),
                    array(function, "meanderScale", expectedCount),
                    array(function, "meanderSpeed", expectedCount),
                    array(function, "meanderOffset", expectedCount));
        }

        private static double[] array(String function, String name, int expectedCount) {
            Pattern declaration = Pattern.compile("const\\s+float\\s+" + Pattern.quote(name)
                    + "\\s*\\[[^]]+\\]\\s*=\\s*\\{(?<body>.*?)\\};", Pattern.DOTALL);
            Matcher matcher = declaration.matcher(function);
            if (!matcher.find()) {
                throw new AssertionError("Missing array " + name);
            }
            double[] values = numbers(matcher.group("body"));
            if (values.length != expectedCount) {
                throw new AssertionError("Array " + name + " has " + values.length
                        + " values; expected " + expectedCount);
            }
            return values;
        }

        private static double[] statementNumbers(String function, String marker) {
            int start = function.indexOf(marker);
            if (start < 0) {
                throw new AssertionError("Missing statement " + marker);
            }
            int end = function.indexOf(';', start);
            if (end < 0) {
                throw new AssertionError("Unterminated statement " + marker);
            }
            return numbers(function.substring(start, end));
        }

        private static double[] numbers(String text) {
            Matcher matcher = Pattern.compile(NUMBER).matcher(text);
            List<Double> values = new ArrayList<>();
            while (matcher.find()) {
                values.add(Double.parseDouble(matcher.group()));
            }
            return values.stream().mapToDouble(Double::doubleValue).toArray();
        }

        private static int intConstant(String code, String name) {
            Pattern pattern = Pattern.compile("\\b" + Pattern.quote(name) + "\\s*=\\s*(\\d+)\\s*;");
            Matcher matcher = pattern.matcher(code);
            if (!matcher.find()) {
                throw new AssertionError("Missing int constant " + name);
            }
            return Integer.parseInt(matcher.group(1));
        }

        private static double floatConstant(String code, String name) {
            Pattern pattern = Pattern.compile("\\b" + Pattern.quote(name) + "\\s*=\\s*(" + NUMBER + ")\\s*;");
            Matcher matcher = pattern.matcher(code);
            if (!matcher.find()) {
                throw new AssertionError("Missing float constant " + name);
            }
            return Double.parseDouble(matcher.group(1));
        }

        private static double[] normalizedFloat2Constant(String code, String name) {
            Pattern pattern = Pattern.compile("\\b" + Pattern.quote(name)
                    + "\\s*=\\s*normalize\\(float2\\(\\s*(" + NUMBER + ")\\s*,\\s*("
                    + NUMBER + ")\\s*\\)\\)\\s*;");
            Matcher matcher = pattern.matcher(code);
            if (!matcher.find()) {
                throw new AssertionError("Missing normalized float2 constant " + name);
            }
            double x = Double.parseDouble(matcher.group(1));
            double z = Double.parseDouble(matcher.group(2));
            double length = Math.hypot(x, z);
            return new double[] {x / length, z / length};
        }

        private static String functionSection(String code, String signature) {
            int start = code.indexOf(signature);
            if (start < 0) {
                throw new AssertionError("Missing function " + signature);
            }
            int open = code.indexOf('{', start);
            if (open < 0) {
                throw new AssertionError("Missing function body " + signature);
            }
            int depth = 0;
            for (int index = open; index < code.length(); index++) {
                char character = code.charAt(index);
                if (character == '{') {
                    depth++;
                } else if (character == '}' && --depth == 0) {
                    return code.substring(start, index + 1);
                }
            }
            throw new AssertionError("Unterminated function " + signature);
        }

        private static String removeComments(String text) {
            return text.replaceAll("(?s)/\\*.*?\\*/", "")
                    .replaceAll("(?m)//.*$", "");
        }

        private static String read(Path path) {
            try {
                return Files.readString(path);
            } catch (IOException exception) {
                throw new AssertionError("Unable to read " + path, exception);
            }
        }

        private static void requireExact(String name, double[] actual, double[] expected) {
            if (!Arrays.equals(actual, expected)) {
                throw new AssertionError(name + " differs: " + Arrays.toString(actual));
            }
        }

        private static void requireSpectrumExact(String name, Spectrum actual, Spectrum expected) {
            requireExact(name + " wavelength", actual.wavelength(), expected.wavelength());
            requireExact(name + " directionOffset", actual.directionOffset(), expected.directionOffset());
            requireExact(name + " energy", actual.energy(), expected.energy());
            requireExact(name + " phaseOffset", actual.phaseOffset(), expected.phaseOffset());
            requireExact(name + " sharpness", actual.sharpness(), expected.sharpness());
            requireExact(name + " meanderAmplitude", actual.meanderAmplitude(), expected.meanderAmplitude());
            requireExact(name + " meanderScale", actual.meanderScale(), expected.meanderScale());
            requireExact(name + " meanderSpeed", actual.meanderSpeed(), expected.meanderSpeed());
            requireExact(name + " meanderOffset", actual.meanderOffset(), expected.meanderOffset());
        }

        private ShaderParser() {
        }
    }
}
