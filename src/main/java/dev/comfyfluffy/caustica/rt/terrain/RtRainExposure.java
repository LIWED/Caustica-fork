package dev.comfyfluffy.caustica.rt.terrain;

/** Shared-corner rain exposure for adjacent terrain faces. */
final class RtRainExposure {
    private RtRainExposure() {}

    /** Nine direct-sky samples, laid out in X-major rows of three Z positions. */
    static void corners(int[] sky, float[] out) {
        out[0] = (sky[0] + sky[1] + sky[3] + sky[4]) * 0.25f;
        out[1] = (sky[1] + sky[2] + sky[4] + sky[5]) * 0.25f;
        out[2] = (sky[3] + sky[4] + sky[6] + sky[7]) * 0.25f;
        out[3] = (sky[4] + sky[5] + sky[7] + sky[8]) * 0.25f;
    }

    static float at(float[] corners, float x, float z) {
        x = Math.max(0.0f, Math.min(1.0f, x));
        z = Math.max(0.0f, Math.min(1.0f, z));
        return (corners[0] + (corners[1] - corners[0]) * x) * (1.0f - z)
                + (corners[2] + (corners[3] - corners[2]) * x) * z;
    }

    static int packTriangle(float a, float b, float c) {
        return byteLevel(a) | (byteLevel(b) << 8) | (byteLevel(c) << 16);
    }

    private static int byteLevel(float value) {
        return Math.round(Math.max(0.0f, Math.min(1.0f, value)) * 255.0f);
    }
}
