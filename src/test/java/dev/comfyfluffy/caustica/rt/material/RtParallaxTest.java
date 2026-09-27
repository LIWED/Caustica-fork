package dev.comfyfluffy.caustica.rt.material;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

final class RtParallaxTest {
    @Test
    void disabledZeroAndInvalidDepthAreNeutral() {
        assertEquals(0, RtParallax.flags(false, 1.0f));
        assertEquals(0, RtParallax.flags(true, 0.0f));
        assertEquals(0, RtParallax.flags(true, -1.0f));
        assertEquals(0, RtParallax.flags(true, Float.NaN));
        assertEquals(0, RtParallax.flags(true, Float.POSITIVE_INFINITY));
    }

    @Test
    void encodesClampedDepthWithoutOverwritingWaterOrWeatherBits() {
        assertEquals(100, (RtParallax.flags(true, 1.0f) >>> 16) & 255);
        assertEquals(125, (RtParallax.flags(true, 1.25f) >>> 16) & 255);
        assertEquals(200, (RtParallax.flags(true, 3.0f) >>> 16) & 255);
        assertEquals(256, RtParallax.flags(true, 1.0f) & 256);
        assertEquals(0, RtParallax.flags(true, 1.0f) & 255);
    }
}
