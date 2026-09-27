package dev.comfyfluffy.caustica.rt;

/** Tracks rain-soaked ground in game ticks, independently of the rain-level transition. */
final class RtSurfaceWetness {
    private static final float WET_TICKS = 75.0f * 20.0f;
    private static final float DRY_TICKS = 120.0f * 20.0f;

    private Object level;
    private long lastTick;
    private float wetness;

    float update(Object currentLevel, long tick, float rain) {
        if (currentLevel == null) {
            level = null;
            wetness = 0.0f;
            return wetness;
        }
        if (currentLevel != level) {
            level = currentLevel;
            lastTick = tick;
            wetness = 0.0f;
            return wetness;
        }

        float target = Math.max(0.0f, Math.min(1.0f, rain));
        // Server time synchronization can move the client clock back by a tick. A clock
        // correction must not erase rain that has already soaked this level.
        long elapsed = Math.max(0L, tick - lastTick);
        lastTick = tick;
        if (target > wetness) {
            wetness = Math.min(target, wetness + elapsed * target / WET_TICKS);
        } else {
            wetness = Math.max(target, wetness - elapsed / DRY_TICKS);
        }
        return wetness;
    }
}
