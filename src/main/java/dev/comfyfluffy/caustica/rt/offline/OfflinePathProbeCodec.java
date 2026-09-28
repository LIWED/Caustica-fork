package dev.comfyfluffy.caustica.rt.offline;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

/** Fixed format version 1 readback ABI; intentionally independent of Minecraft/LWJGL for testing. */
public final class OfflinePathProbeCodec {
    public static final int HEADER_BYTES = 16;
    public static final int CAPACITY = 32;
    public static final int STEP_BYTES = 160;
    public static final int MAX_STEPS = 33;
    public static final int RECORD_BYTES = 64 + MAX_STEPS * STEP_BYTES;
    public static final int BUFFER_BYTES = HEADER_BYTES + CAPACITY * RECORD_BYTES;
    private static final String[] LANES = {
            "position_hitT", "incoming_inWater", "geometricNormal_material", "throughputBefore_protected",
            "albedo_perceptualRoughness", "F0_metal", "effectiveNormal_rouletteProbability",
            "throughputAfter_survived", "outgoing_event", "maxContribution_category"
    };

    private OfflinePathProbeCodec() { }

    public static List<String> decode(ByteBuffer input, String metadata, int limit) {
        ByteBuffer b = input.duplicate().order(ByteOrder.LITTLE_ENDIAN);
        List<String> records = new ArrayList<>();
        if (b.limit() < HEADER_BYTES || limit <= 0) return records;
        int count = (int) Math.min(Integer.toUnsignedLong(b.getInt(0)), CAPACITY);
        count = Math.min(count, (int) Math.min(Integer.toUnsignedLong(b.getInt(4)), CAPACITY));
        count = Math.min(count, (b.limit() - HEADER_BYTES) / RECORD_BYTES);
        for (int i = 0; i < count && records.size() < limit; i++) {
            int r = HEADER_BYTES + i * RECORD_BYTES;
            int steps = b.getInt(r + 48);
            if (b.getInt(r + 60) != 1 || b.getInt(r + 56) != 1 || steps < 0 || steps > MAX_STEPS) continue;
            StringBuilder out = new StringBuilder(1400 + steps * 700);
            out.append("{\"type\":\"path\",\"formatVersion\":1");
            if (!metadata.isEmpty()) out.append(',').append(metadata);
            out.append(",\"pixel\":[").append(Integer.toUnsignedLong(b.getInt(r))).append(',')
                    .append(Integer.toUnsignedLong(b.getInt(r + 4))).append(']');
            long sample = Integer.toUnsignedLong(b.getInt(r + 8)) | ((long) b.getInt(r + 12) << 32);
            out.append(",\"sampleIndex\":\"").append(Long.toUnsignedString(sample)).append('"');
            String[] fields = {"category", "bounce", "pathFlags", "protected"};
            for (int j = 0; j < fields.length; j++) {
                out.append(",\"").append(fields[j]).append("\":").append(Integer.toUnsignedLong(b.getInt(r + 16 + j * 4)));
            }
            out.append(",\"maxValue\":").append(number(b.getFloat(r + 32)));
            out.append(",\"sourceRGB\":");
            vector(out, b, r + 36, 3);
            out.append(",\"initialSeed\":").append(Integer.toUnsignedLong(b.getInt(r + 52)));
            out.append(",\"stepCount\":").append(steps).append(",\"steps\":[");
            for (int s = 0; s < steps; s++) {
                if (s != 0) out.append(',');
                out.append('{');
                for (int lane = 0; lane < LANES.length; lane++) {
                    if (lane != 0) out.append(',');
                    out.append('"').append(LANES[lane]).append("\":");
                    vector(out, b, r + 64 + s * STEP_BYTES + lane * 16, 4);
                }
                out.append('}');
            }
            records.add(out.append("]}").toString());
        }
        return records;
    }

    private static void vector(StringBuilder out, ByteBuffer b, int offset, int count) {
        out.append('[');
        for (int i = 0; i < count; i++) {
            if (i != 0) out.append(',');
            out.append(number(b.getFloat(offset + i * 4)));
        }
        out.append(']');
    }

    /** Nonfinite values retain their meaning without creating invalid JSON number tokens. */
    public static String number(double value) {
        if (Double.isNaN(value)) return "\"NaN\"";
        if (value == Double.POSITIVE_INFINITY) return "\"+Infinity\"";
        if (value == Double.NEGATIVE_INFINITY) return "\"-Infinity\"";
        return Double.toString(value);
    }
}
