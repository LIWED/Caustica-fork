package dev.comfyfluffy.caustica.rt.light;

import dev.comfyfluffy.caustica.rt.offline.OfflineStaticLightMath;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Comparator;
import java.util.Objects;

/** Pure CPU representation of invisible vanilla Light-block sources for realtime publication. */
public final class RealtimeLightBlockIndex {
    public static final int GPU_RECORD_BYTES = 32;

    public record Source(float x, float y, float z, int level) {
        public Source {
            if (!Float.isFinite(x) || !Float.isFinite(y) || !Float.isFinite(z)) {
                throw new IllegalArgumentException("Light-block source coordinates must be finite");
            }
            if (level < 0 || level > 15) {
                throw new IllegalArgumentException("Light-block source level must be in [0, 15]");
            }
        }
    }

    public record Entry(
            float x, float y, float z,
            float intensity,
            float selectionWeight,
            float cumulativeWeight) {
    }

    public record Build(Entry[] entries, float totalWeight) {
    }

    private static final Comparator<Source> SOURCE_ORDER = Comparator
            .comparingDouble(Source::x)
            .thenComparingDouble(Source::y)
            .thenComparingDouble(Source::z)
            .thenComparingInt(Source::level);

    private RealtimeLightBlockIndex() {
    }

    public static Build build(Collection<Source> sources, int baseX, int baseY, int baseZ) {
        Objects.requireNonNull(sources, "sources");
        var sorted = new ArrayList<Source>(sources.size());
        for (Source source : sources) {
            sorted.add(Objects.requireNonNull(source, "source"));
        }
        sorted.sort(SOURCE_ORDER);

        var entries = new ArrayList<Entry>(sorted.size());
        float totalWeight = 0.0f;
        for (Source source : sorted) {
            if (source.level() == 0) {
                continue;
            }
            float intensity = OfflineStaticLightMath.pointIntensity(source.level());
            totalWeight += intensity;
            if (!Float.isFinite(totalWeight)) {
                throw new IllegalArgumentException("Light-block cumulative weight must be finite");
            }
            entries.add(new Entry(source.x() - baseX, source.y() - baseY, source.z() - baseZ,
                    intensity, intensity, totalWeight));
        }
        return new Build(entries.toArray(Entry[]::new), totalWeight);
    }

    public static boolean sameSources(Source[] left, Source[] right) {
        return Arrays.equals(left, right);
    }

    public static float selectionPdf(Entry entry, float totalWeight) {
        if (entry == null || !Float.isFinite(entry.selectionWeight()) || !Float.isFinite(totalWeight)
                || !(entry.selectionWeight() > 0.0f) || !(totalWeight > 0.0f)) {
            return 0.0f;
        }
        return entry.selectionWeight() / totalWeight;
    }
}
