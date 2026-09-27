package dev.comfyfluffy.caustica.rt.entity;

import net.minecraft.client.renderer.WeatherEffectRenderer.ColumnInstance;
import net.minecraft.client.renderer.state.level.WeatherRenderState;

import java.util.ArrayList;
import java.util.List;

/** Immutable render-thread handoff for vanilla's mutable per-frame weather column state. */
public record RtWeatherSnapshot(List<Column> rainColumns, List<Column> snowColumns,
                                float intensity, int radius, long frameId) {
    public enum Kind { RAIN, SNOW }

    public record Column(int x, int z, int bottomY, int topY,
                         float uOffset, float vOffset, int lightCoords) {
    }

    public record Vertex(float x, float y, float z, float u, float v,
                         float alpha, int lightCoords, float halfWidth) {
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

    public static RtWeatherSnapshot capture(WeatherRenderState state, long frameId) {
        if (state == null) {
            return empty(frameId);
        }
        return new RtWeatherSnapshot(
                List.copyOf(copyColumns(state.rainColumns)),
                List.copyOf(copyColumns(state.snowColumns)),
                state.intensity, state.radius, frameId);
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

    /** Build stable crossed vertical quads directly in terrain-rebased coordinates. */
    public Mesh mesh(int rbx, int rby, int rbz, double cameraX, double cameraZ) {
        if (isEmpty()) {
            return new Mesh(List.of(), RtEntities.PARTICLE_BIT, RtEntities.PARTICLE_MASK,
                    new Motion(0.0f, 0.0f, 0.0f));
        }
        List<Quad> quads = new ArrayList<>((rainColumns.size() + snowColumns.size()) * 2);
        for (Column column : rainColumns) {
            appendCrossedQuads(quads, Kind.RAIN, column, rbx, rby, rbz, cameraX, cameraZ);
        }
        for (Column column : snowColumns) {
            appendCrossedQuads(quads, Kind.SNOW, column, rbx, rby, rbz, cameraX, cameraZ);
        }
        return new Mesh(quads, RtEntities.PARTICLE_BIT, RtEntities.PARTICLE_MASK,
                new Motion(0.0f, 0.0f, 0.0f));
    }

    private void appendCrossedQuads(List<Quad> out, Kind kind, Column column,
                                    int rbx, int rby, int rbz, double cameraX, double cameraZ) {
        float cx = column.x() + 0.5f - rbx;
        float cz = column.z() + 0.5f - rbz;
        float bottom = column.bottomY() - rby;
        float top = column.topY() - rby;
        float halfWidth = kind == Kind.RAIN ? 0.35f : 0.5f;
        float distanceNorm;
        if (radius <= 0) {
            distanceNorm = 1.0f;
        } else {
            double dx = column.x() + 0.5 - cameraX;
            double dz = column.z() + 0.5 - cameraZ;
            distanceNorm = (float) Math.min((dx * dx + dz * dz) / ((double) radius * radius), 1.0);
        }
        float nearAlpha = kind == Kind.RAIN ? 0.42f : 0.8f;
        float farAlpha = kind == Kind.RAIN ? 0.16f : 0.5f;
        float columnAlpha = (nearAlpha + distanceNorm * (farAlpha - nearAlpha)) * intensity;
        float u0 = column.uOffset();
        float u1 = u0 + 1.0f;
        // Vanilla's captured vOffset is already game-time animated; preserve it exactly once.
        float v0 = column.bottomY() * 0.25f + column.vOffset();
        float v1 = column.topY() * 0.25f + column.vOffset();
        out.add(quad(kind,
                vertex(cx - halfWidth, bottom, cz, u0, v0, columnAlpha, column.lightCoords(), halfWidth),
                vertex(cx - halfWidth, top, cz, u0, v1, columnAlpha, column.lightCoords(), halfWidth),
                vertex(cx + halfWidth, top, cz, u1, v1, columnAlpha, column.lightCoords(), halfWidth),
                vertex(cx + halfWidth, bottom, cz, u1, v0, columnAlpha, column.lightCoords(), halfWidth)));
        out.add(quad(kind,
                vertex(cx, bottom, cz - halfWidth, u0, v0, columnAlpha, column.lightCoords(), halfWidth),
                vertex(cx, top, cz - halfWidth, u0, v1, columnAlpha, column.lightCoords(), halfWidth),
                vertex(cx, top, cz + halfWidth, u1, v1, columnAlpha, column.lightCoords(), halfWidth),
                vertex(cx, bottom, cz + halfWidth, u1, v0, columnAlpha, column.lightCoords(), halfWidth)));
    }

    private static Vertex vertex(float x, float y, float z, float u, float v, float alpha,
                                 int lightCoords, float halfWidth) {
        return new Vertex(x, y, z, u, v, alpha, lightCoords, halfWidth);
    }

    private static Quad quad(Kind kind, Vertex a, Vertex b, Vertex c, Vertex d) {
        return new Quad(kind, List.of(a, b, c, d));
    }
}
