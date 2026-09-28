package dev.comfyfluffy.caustica.rt.light;

import dev.comfyfluffy.caustica.rt.offline.OfflineStaticLightMath;

import java.util.Arrays;
import java.util.List;

/** Executable contract for the CPU-side realtime Light-block source index. */
public final class RealtimeLightBlockBehaviorTest {
    private static final float EPSILON = 1.0e-5f;

    private RealtimeLightBlockBehaviorTest() {
    }

    public static void main(String[] args) {
        levelZeroProducesNoEntries();
        levelsProduceIncreasingFiniteIntensities();
        selectionPdfSumsToOne();
        reversedInputProducesIdenticalSortedEntries();
        sameSourcesComparesContents();
        sourceValidationRejectsInvalidValues();
        invalidPdfInputsProduceZero();
        entriesUseTerrainRelativePositions();
        System.out.println("Realtime Light-block behavior: PASS");
    }

    private static void levelZeroProducesNoEntries() {
        var build = RealtimeLightBlockIndex.build(
                List.of(new RealtimeLightBlockIndex.Source(1.5f, 2.5f, 3.5f, 0)), 0, 0, 0);
        check(build.entries().length == 0, "level 0 must not produce an entry");
        check(build.totalWeight() == 0.0f, "level 0 must not contribute weight");
    }

    private static void levelsProduceIncreasingFiniteIntensities() {
        var build = RealtimeLightBlockIndex.build(List.of(
                new RealtimeLightBlockIndex.Source(0.5f, 0.5f, 0.5f, 1),
                new RealtimeLightBlockIndex.Source(1.5f, 0.5f, 0.5f, 7),
                new RealtimeLightBlockIndex.Source(2.5f, 0.5f, 0.5f, 15)), 0, 0, 0);
        var entries = build.entries();
        check(entries.length == 3, "levels 1, 7, and 15 must each produce an entry");
        float one = entries[0].intensity();
        float seven = entries[1].intensity();
        float fifteen = entries[2].intensity();
        check(Float.isFinite(one) && Float.isFinite(seven) && Float.isFinite(fifteen),
                "Light-block intensities must be finite");
        check(one < seven && seven < fifteen, "Light-block intensity must increase with level");
        close(one, OfflineStaticLightMath.pointIntensity(1), "level 1 intensity");
        close(seven, OfflineStaticLightMath.pointIntensity(7), "level 7 intensity");
        close(fifteen, OfflineStaticLightMath.pointIntensity(15), "level 15 intensity");
    }

    private static void selectionPdfSumsToOne() {
        var build = RealtimeLightBlockIndex.build(List.of(
                new RealtimeLightBlockIndex.Source(0.5f, 0.5f, 0.5f, 1),
                new RealtimeLightBlockIndex.Source(1.5f, 0.5f, 0.5f, 7),
                new RealtimeLightBlockIndex.Source(2.5f, 0.5f, 0.5f, 15)), 0, 0, 0);
        float sum = 0.0f;
        for (var entry : build.entries()) {
            sum += RealtimeLightBlockIndex.selectionPdf(entry, build.totalWeight());
        }
        close(sum, 1.0f, "selection PDFs must sum to 1");
    }

    private static void reversedInputProducesIdenticalSortedEntries() {
        var a = new RealtimeLightBlockIndex.Source(9.5f, 3.5f, 1.5f, 15);
        var b = new RealtimeLightBlockIndex.Source(1.5f, 9.5f, 3.5f, 7);
        var c = new RealtimeLightBlockIndex.Source(1.5f, 9.5f, 3.5f, 1);
        var forward = RealtimeLightBlockIndex.build(List.of(a, b, c), 0, 0, 0);
        var reversed = RealtimeLightBlockIndex.build(List.of(c, b, a), 0, 0, 0);
        check(Arrays.equals(forward.entries(), reversed.entries()),
                "reversed sources must produce identical sorted entries");
        close(forward.totalWeight(), reversed.totalWeight(), "sorted total weight");
    }

    private static void sameSourcesComparesContents() {
        var source = new RealtimeLightBlockIndex.Source(1.5f, 2.5f, 3.5f, 7);
        var equal = new RealtimeLightBlockIndex.Source(1.5f, 2.5f, 3.5f, 7);
        check(RealtimeLightBlockIndex.sameSources(
                new RealtimeLightBlockIndex.Source[]{source},
                new RealtimeLightBlockIndex.Source[]{equal}), "content-equal arrays must compare equal");
        check(!RealtimeLightBlockIndex.sameSources(
                new RealtimeLightBlockIndex.Source[]{source},
                new RealtimeLightBlockIndex.Source[]{new RealtimeLightBlockIndex.Source(2.5f, 2.5f, 3.5f, 7)}),
                "position changes must compare unequal");
        check(!RealtimeLightBlockIndex.sameSources(
                new RealtimeLightBlockIndex.Source[]{source},
                new RealtimeLightBlockIndex.Source[]{new RealtimeLightBlockIndex.Source(1.5f, 2.5f, 3.5f, 8)}),
                "level changes must compare unequal");
    }

    private static void sourceValidationRejectsInvalidValues() {
        expectIllegalArgument(() -> new RealtimeLightBlockIndex.Source(Float.NaN, 0.0f, 0.0f, 1),
                "NaN coordinates must be rejected");
        expectIllegalArgument(() -> new RealtimeLightBlockIndex.Source(Float.POSITIVE_INFINITY, 0.0f, 0.0f, 1),
                "infinite coordinates must be rejected");
        expectIllegalArgument(() -> new RealtimeLightBlockIndex.Source(0.0f, 0.0f, 0.0f, -1),
                "negative levels must be rejected");
        expectIllegalArgument(() -> new RealtimeLightBlockIndex.Source(0.0f, 0.0f, 0.0f, 16),
                "levels above 15 must be rejected");
    }

    private static void invalidPdfInputsProduceZero() {
        var entry = new RealtimeLightBlockIndex.Entry(0.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f);
        check(RealtimeLightBlockIndex.selectionPdf(entry, 0.0f) == 0.0f, "zero total must produce zero PDF");
        check(RealtimeLightBlockIndex.selectionPdf(entry, -1.0f) == 0.0f, "negative total must produce zero PDF");
        check(RealtimeLightBlockIndex.selectionPdf(entry, Float.NaN) == 0.0f, "NaN total must produce zero PDF");
        check(RealtimeLightBlockIndex.selectionPdf(entry, Float.POSITIVE_INFINITY) == 0.0f,
                "infinite total must produce zero PDF");
        var invalidEntry = new RealtimeLightBlockIndex.Entry(0.0f, 0.0f, 0.0f, 1.0f, Float.NaN, 1.0f);
        check(RealtimeLightBlockIndex.selectionPdf(invalidEntry, 1.0f) == 0.0f,
                "invalid entry weight must produce zero PDF");
    }

    private static void entriesUseTerrainRelativePositions() {
        var build = RealtimeLightBlockIndex.build(
                List.of(new RealtimeLightBlockIndex.Source(100.5f, 64.5f, -20.5f, 15)), 96, 64, -32);
        var entry = build.entries()[0];
        close(entry.x(), 4.5f, "relative x");
        close(entry.y(), 0.5f, "relative y");
        close(entry.z(), 11.5f, "relative z");
    }

    private static void expectIllegalArgument(Runnable action, String message) {
        try {
            action.run();
        } catch (IllegalArgumentException expected) {
            return;
        }
        throw new AssertionError(message);
    }

    private static void close(float actual, float expected, String message) {
        check(Math.abs(actual - expected) <= EPSILON,
                message + ": expected " + expected + ", got " + actual);
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
