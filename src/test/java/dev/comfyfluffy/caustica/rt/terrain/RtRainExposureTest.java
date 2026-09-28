package dev.comfyfluffy.caustica.rt.terrain;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

final class RtRainExposureTest {
    @Test
    void neighboringFacesShareTheSameExposureAtTheirBoundary() {
        float[] coveredSide = corners(-1);
        float[] openSide = corners(0);

        assertEquals(0.0f, RtRainExposure.at(coveredSide, 0.0f, 0.5f));
        assertEquals(0.5f, RtRainExposure.at(coveredSide, 1.0f, 0.5f));
        assertEquals(RtRainExposure.at(coveredSide, 1.0f, 0.5f),
                RtRainExposure.at(openSide, 0.0f, 0.5f));
        assertEquals(1.0f, RtRainExposure.at(openSide, 1.0f, 0.5f));
    }

    @Test
    void triangleEncodingRetainsTheInterpolatedCornerLevels() {
        int packed = RtRainExposure.packTriangle(0.0f, 0.5f, 1.0f);
        assertEquals(0, packed & 255);
        assertEquals(128, (packed >>> 8) & 255);
        assertEquals(255, (packed >>> 16) & 255);
    }

    private static float[] corners(int tileX) {
        int[] sky = new int[9];
        for (int z = 0; z < 3; z++) {
            for (int x = 0; x < 3; x++) {
                sky[x + z * 3] = tileX + x - 1 >= 0 ? 1 : 0;
            }
        }
        float[] out = new float[4];
        RtRainExposure.corners(sky, out);
        return out;
    }
}
