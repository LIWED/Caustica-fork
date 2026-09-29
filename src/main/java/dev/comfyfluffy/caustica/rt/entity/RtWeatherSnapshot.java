package dev.comfyfluffy.caustica.rt.entity;

import net.minecraft.client.renderer.WeatherEffectRenderer.ColumnInstance;
import net.minecraft.client.renderer.state.level.WeatherRenderState;

import java.util.ArrayList;
import java.util.List;

/** Immutable render-thread handoff for vanilla's mutable per-frame weather column state. */
public record RtWeatherSnapshot(List<Column> rainColumns, List<Column> snowColumns,
                                float intensity, int radius, long frameId, float timeSeconds) {
    public enum Kind { RAIN, SNOW }

    public record Column(int x, int z, int bottomY, int topY,
                         float uOffset, float vOffset, int lightCoords) {
    }

    public record Vertex(float x, float y, float z, float u, float v,
                         float alpha, int lightCoords, float halfWidth, float motionX, float motionZ) {
    }

    public record Quad(Kind kind, List<Vertex> vertices) {
        public Quad {
            vertices = List.copyOf(vertices);
        }
    }

    public record Motion(float x, float y, float z) {
    }

    public record Mesh(List<Quad> quads, int instanceBit, int visibilityMask, Motion motion) {
        public Mesh {
            quads = List.copyOf(quads);
        }
    }

    public RtWeatherSnapshot {
        rainColumns = List.copyOf(rainColumns == null ? List.of() : rainColumns);
        snowColumns = List.copyOf(snowColumns == null ? List.of() : snowColumns);
        intensity = Math.max(0.0f, Math.min(1.0f, intensity));
        radius = Math.max(0, radius);
    }

    public RtWeatherSnapshot(List<Column> rainColumns, List<Column> snowColumns,
                             float intensity, int radius, long frameId) {
        this(rainColumns, snowColumns, intensity, radius, frameId, 0.0f);
    }

    public static RtWeatherSnapshot capture(WeatherRenderState state, long frameId) {
        return capture(state, frameId, 0.0f);
    }

    public static RtWeatherSnapshot capture(WeatherRenderState state, long frameId, float timeSeconds) {
        if (state == null) {
            return empty(frameId);
        }
        return new RtWeatherSnapshot(
                List.copyOf(copyColumns(state.rainColumns)),
                List.copyOf(copyColumns(state.snowColumns)),
                state.intensity, state.radius, frameId, timeSeconds);
    }

    public static RtWeatherSnapshot empty(long frameId) {
        return new RtWeatherSnapshot(List.of(), List.of(), 0.0f, 0, frameId);
    }

    private static List<Column> copyColumns(List<ColumnInstance> source) {
        if (source == null || source.isEmpty()) {
            return List.of();
        }
        List<Column> copy = new ArrayList<>(source.size());
        for (ColumnInstance column : source) {
            if (column != null) {
                copy.add(new Column(column.x(), column.z(), column.bottomY(), column.topY(),
                        column.uOffset(), column.vOffset(), column.lightCoords()));
            }
        }
        return copy;
    }

    public boolean isEmpty() {
        return intensity <= 0.0f || (rainColumns.isEmpty() && snowColumns.isEmpty());
    }

    /** Build weather directly in terrain-rebased coordinates. Snow bends through world space. */
    public Mesh mesh(int rbx, int rby, int rbz, double cameraX, double cameraZ) {
        return mesh(rbx, rby, rbz, cameraX, cameraZ, timeSeconds);
    }

    public Mesh mesh(int rbx, int rby, int rbz, double cameraX, double cameraZ, float previousTimeSeconds) {
        if (isEmpty()) {
            return new Mesh(List.of(), RtEntities.PARTICLE_BIT, RtEntities.PARTICLE_MASK,
                    new Motion(0.0f, 0.0f, 0.0f));
        }
        List<Quad> quads = new ArrayList<>(rainColumns.size() * 2 + snowColumns.size() * 6);
        for (Column column : rainColumns) {
            appendCrossedQuads(quads, Kind.RAIN, column, rbx, rby, rbz, cameraX, cameraZ, previousTimeSeconds);
        }
        for (Column column : snowColumns) {
            appendCrossedQuads(quads, Kind.SNOW, column, rbx, rby, rbz, cameraX, cameraZ, previousTimeSeconds);
        }
        return new Mesh(quads, RtEntities.PARTICLE_BIT, RtEntities.PARTICLE_MASK,
                new Motion(0.0f, 0.0f, 0.0f));
    }

    private void appendCrossedQuads(List<Quad> out, Kind kind, Column column,
                                    int rbx, int rby, int rbz, double cameraX, double cameraZ,
                                    float previousTimeSeconds) {
        float cx = column.x() + 0.5f - rbx;
        float cz = column.z() + 0.5f - rbz;
        float halfWidth = kind == Kind.RAIN ? 0.12f : 0.4f;
        float distanceNorm;
        if (radius <= 0) {
            distanceNorm = 1.0f;
        } else {
            double dx = column.x() + 0.5 - cameraX;
            double dz = column.z() + 0.5 - cameraZ;
            distanceNorm = (float) Math.min((dx * dx + dz * dz) / ((double) radius * radius), 1.0);
        }
        float nearAlpha = kind == Kind.RAIN ? 0.42f : 0.62f;
        float farAlpha = kind == Kind.RAIN ? 0.16f : 0.38f;
        float columnAlpha = (nearAlpha + distanceNorm * (farAlpha - nearAlpha)) * intensity;
        float u0 = column.uOffset();
        float u1 = u0 + 1.0f;
        // Vanilla's snow vOffset decreases with time. Its top vertex uses the lower V coordinate;
        // reversing that mapping makes flakes rise. Denser snow UVs make each flake slightly smaller.
        int height = Math.max(0, column.topY() - column.bottomY());
        int sections = kind == Kind.RAIN ? 1 : Math.min(3, Math.max(1, (height + 2) / 3));
        Drift low = kind == Kind.SNOW
                ? snowDrift(column, column.bottomY(), timeSeconds, previousTimeSeconds) : Drift.ZERO;
        for (int section = 0; section < sections; section++) {
            float lowY = column.bottomY() + height * (section / (float) sections);
            float highY = column.bottomY() + height * ((section + 1) / (float) sections);
            Drift high = kind == Kind.SNOW ? snowDrift(column, highY, timeSeconds, previousTimeSeconds) : Drift.ZERO;
            float v0 = (kind == Kind.SNOW ? (column.bottomY() + column.topY() - lowY) * 0.30f
                    : lowY * 0.45f) + column.vOffset();
            float v1 = (kind == Kind.SNOW ? (column.bottomY() + column.topY() - highY) * 0.30f
                    : highY * 0.45f) + column.vOffset();
            out.add(quad(kind,
                    vertex(cx - halfWidth + low.x, lowY - rby, cz + low.z, u0, v0, columnAlpha, column.lightCoords(), halfWidth, low),
                    vertex(cx - halfWidth + high.x, highY - rby, cz + high.z, u0, v1, columnAlpha, column.lightCoords(), halfWidth, high),
                    vertex(cx + halfWidth + high.x, highY - rby, cz + high.z, u1, v1, columnAlpha, column.lightCoords(), halfWidth, high),
                    vertex(cx + halfWidth + low.x, lowY - rby, cz + low.z, u1, v0, columnAlpha, column.lightCoords(), halfWidth, low)));
            out.add(quad(kind,
                    vertex(cx + low.x, lowY - rby, cz - halfWidth + low.z, u0, v0, columnAlpha, column.lightCoords(), halfWidth, low),
                    vertex(cx + high.x, highY - rby, cz - halfWidth + high.z, u0, v1, columnAlpha, column.lightCoords(), halfWidth, high),
                    vertex(cx + high.x, highY - rby, cz + halfWidth + high.z, u1, v1, columnAlpha, column.lightCoords(), halfWidth, high),
                    vertex(cx + low.x, lowY - rby, cz + halfWidth + low.z, u1, v0, columnAlpha, column.lightCoords(), halfWidth, low)));
            low = high;
        }
    }

    private record Drift(float x, float z, float motionX, float motionZ) {
        private static final Drift ZERO = new Drift(0f, 0f, 0f, 0f);
    }

    private static Drift snowDrift(Column column, float worldY, float currentTimeSeconds,
                                   float previousTimeSeconds) {
        int hash = column.x() * 0x1f123bb5 ^ column.z() * 0x5f356495;
        hash ^= hash >>> 16;
        float phaseX = (hash & 0xffff) * (float) (Math.PI * 2.0 / 65536.0);
        float phaseZ = ((hash >>> 16) & 0xffff) * (float) (Math.PI * 2.0 / 65536.0);
        float height = worldY - column.bottomY();
        float x = snowDriftX(height, worldY, phaseX, phaseZ, currentTimeSeconds);
        float z = snowDriftZ(height, worldY, phaseX, phaseZ, currentTimeSeconds);
        float previousX = snowDriftX(height, worldY, phaseX, phaseZ, previousTimeSeconds);
        float previousZ = snowDriftZ(height, worldY, phaseX, phaseZ, previousTimeSeconds);
        return new Drift(x, z, x - previousX, z - previousZ);
    }

    private static float snowDriftX(float height, float y, float phaseX, float phaseZ, float time) {
        return 0.025f * height + 0.19f * (float) Math.sin(time * 0.75f + y * 0.90f + phaseX)
                + 0.07f * (float) Math.sin(time * 1.33f + y * 0.47f + phaseZ);
    }

    private static float snowDriftZ(float height, float y, float phaseX, float phaseZ, float time) {
        return 0.013f * height + 0.17f * (float) Math.cos(time * 0.63f + y * 1.03f + phaseZ)
                + 0.08f * (float) Math.sin(time * 1.17f + y * 0.55f + phaseX);
    }

    private static Vertex vertex(float x, float y, float z, float u, float v, float alpha,
                                 int lightCoords, float halfWidth, Drift drift) {
        return new Vertex(x, y, z, u, v, alpha, lightCoords, halfWidth, drift.motionX, drift.motionZ);
    }

    private static Quad quad(Kind kind, Vertex a, Vertex b, Vertex c, Vertex d) {
        return new Quad(kind, List.of(a, b, c, d));
    }
}
