package dev.comfyfluffy.caustica.rt.gen;

import org.joml.Matrix4fc;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

public final class WorldPushDataAbiBehaviorTest {
    private static final long REALTIME_ADDRESS = 0x1122334455667788L;
    private static final int REALTIME_COUNT = 0x12345678;
    private static final float REALTIME_TOTAL = 123.25f;

    private WorldPushDataAbiBehaviorTest() {
    }

    public static void main(String[] args) {
        check(WorldPushData.BYTE_SIZE == 640,
                "generated WorldPushData includes the appended path probe fields (640 bytes)");

        Matrix4fc matrix = new Matrix4fc() {
            @Override
            public Matrix4fc get(int index, ByteBuffer destination) {
                return this;
            }
        };
        WorldPushData.Float3 zero3 = new WorldPushData.Float3(0.0f, 0.0f, 0.0f);
        WorldPushData.Float4 zero4 = new WorldPushData.Float4(0.0f, 0.0f, 0.0f, 0.0f);
        WorldPushData value = new WorldPushData(
                matrix,
                zero3,
                0L,
                0L,
                0,
                0.0f,
                REALTIME_ADDRESS,
                REALTIME_COUNT,
                REALTIME_TOTAL,
                0L,
                0L,
                0,
                0,
                0,
                0,
                matrix,
                zero3,
                0,
                0L,
                new WorldPushData.Float2(0.0f, 0.0f),
                0L,
                0,
                0,
                zero4,
                zero4,
                zero4,
                zero4,
                zero4,
                zero4,
                zero4,
                zero4,
                zero4,
                matrix,
                0,
                new WorldPushData.BreakEntry[0],
                0x0123456789abcdefL,
                256.0f);

        ByteBuffer buffer = ByteBuffer.allocate(WorldPushData.BYTE_SIZE)
                .order(ByteOrder.nativeOrder());
        value.write(buffer);
        check(buffer.getLong(624) == 0x0123456789abcdefL, "probe address ABI offset");
        check(buffer.getFloat(632) == 256.0f, "probe threshold ABI offset");

        check(buffer.getLong(104) == REALTIME_ADDRESS,
                "generated realtime address offset must remain 104");
        check(buffer.getInt(112) == REALTIME_COUNT,
                "generated realtime count offset must remain 112");
        check(Float.floatToIntBits(buffer.getFloat(116))
                        == Float.floatToIntBits(REALTIME_TOTAL),
                "generated realtime total-weight offset must remain 116");
        System.out.println("Generated WorldPushData ABI behavior: PASS");
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
