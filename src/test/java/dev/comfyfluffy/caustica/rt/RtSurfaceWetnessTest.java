package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

final class RtSurfaceWetnessTest {
    @Test
    void sustainedRainWetsGroundCompletelyAndClearWeatherDriesIt() {
        RtSurfaceWetness wetness = new RtSurfaceWetness();
        Object level = new Object();

        assertEquals(0.0f, wetness.update(level, 100L, 1.0f), 1.0e-5f);
        assertEquals(0.5f, wetness.update(level, 850L, 1.0f), 1.0e-5f);
        assertEquals(1.0f, wetness.update(level, 1600L, 1.0f), 1.0e-5f);
        assertEquals(0.5f, wetness.update(level, 2800L, 0.0f), 1.0e-5f);
        assertEquals(0.0f, wetness.update(level, 4000L, 0.0f), 1.0e-5f);
    }

    @Test
    void otherWorldAndRepeatedFrameDoNotCarryOrDoubleCountWetness() {
        RtSurfaceWetness wetness = new RtSurfaceWetness();
        Object level = new Object();
        wetness.update(level, 0L, 1.0f);
        assertEquals(0.2f, wetness.update(level, 300L, 1.0f), 1.0e-5f);
        assertEquals(0.2f, wetness.update(level, 300L, 1.0f), 1.0e-5f);
        assertEquals(0.0f, wetness.update(new Object(), 300L, 1.0f), 1.0e-5f);
        assertEquals(0.0f, wetness.update(level, 100L, 1.0f), 1.0e-5f);
    }

    @Test
    void backwardClockCorrectionDoesNotEraseAccumulatedRain() {
        RtSurfaceWetness wetness = new RtSurfaceWetness();
        Object level = new Object();
        wetness.update(level, 0L, 1.0f);
        assertEquals(0.2f, wetness.update(level, 300L, 1.0f), 1.0e-5f);
        assertEquals(0.2f, wetness.update(level, 299L, 1.0f), 1.0e-5f);
        assertEquals(0.3f, wetness.update(level, 449L, 1.0f), 1.0e-5f);
    }
}
