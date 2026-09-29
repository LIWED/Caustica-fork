package dev.comfyfluffy.caustica.rt.entity;

import net.minecraft.client.renderer.WeatherEffectRenderer.ColumnInstance;
import net.minecraft.client.renderer.state.level.WeatherRenderState;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

final class RtWeatherCaptureTest {
    @Test
    void snapshotDefensivelyCopiesBothColumnKindsAndScalars() {
        WeatherRenderState state = new WeatherRenderState();
        state.intensity = 0.75f;
        state.radius = 12;
        state.rainColumns.add(new ColumnInstance(10, 20, 64, 72, 0.25f, 0.5f, 0x00F000A0));
        state.snowColumns.add(new ColumnInstance(-3, 4, 80, 86, 0.125f, 0.75f, 0x006000F0));

        RtWeatherSnapshot snapshot = RtWeatherSnapshot.capture(state, 99L);
        state.reset();

        assertEquals(0.75f, snapshot.intensity());
        assertEquals(12, snapshot.radius());
        assertEquals(99L, snapshot.frameId());
        assertEquals(new RtWeatherSnapshot.Column(10, 20, 64, 72, 0.25f, 0.5f, 0x00F000A0),
                snapshot.rainColumns().getFirst());
        assertEquals(new RtWeatherSnapshot.Column(-3, 4, 80, 86, 0.125f, 0.75f, 0x006000F0),
                snapshot.snowColumns().getFirst());
        assertThrows(UnsupportedOperationException.class,
                () -> snapshot.rainColumns().add(snapshot.rainColumns().getFirst()));
    }

    @Test
    void nullAndEmptyWeatherAreSafe() {
        RtWeatherSnapshot nullSnapshot = RtWeatherSnapshot.capture(null, 7L);
        RtWeatherSnapshot emptySnapshot = RtWeatherSnapshot.capture(new WeatherRenderState(), 8L);

        assertTrue(nullSnapshot.isEmpty());
        assertTrue(emptySnapshot.isEmpty());
        assertEquals(7L, nullSnapshot.frameId());
        assertTrue(emptySnapshot.mesh(0, 0, 0, 0.0, 0.0).quads().isEmpty());
    }

    @Test
    void rainAndSnowBecomeRebasedCrossQuadsWithCompactRainStreaks() {
        RtWeatherSnapshot snapshot = new RtWeatherSnapshot(
                List.of(new RtWeatherSnapshot.Column(110, 220, 64, 72, 0.25f, 0.5f, 0x00F000A0)),
                List.of(new RtWeatherSnapshot.Column(111, 221, 80, 84, 0.125f, 0.75f, 0x006000F0)),
                0.8f, 10, 20L);

        RtWeatherSnapshot.Mesh mesh = snapshot.mesh(100, 60, 200, 110.5, 220.5);

        assertEquals(6, mesh.quads().size()); // rain 2; four-block snow column bends across 2 sections
        assertEquals(RtWeatherSnapshot.Kind.RAIN, mesh.quads().get(0).kind());
        assertEquals(RtWeatherSnapshot.Kind.SNOW, mesh.quads().get(2).kind());
        RtWeatherSnapshot.Vertex rainBottom = mesh.quads().get(0).vertices().getFirst();
        assertEquals(10.38f, rainBottom.x(), 1.0e-5f);
        assertEquals(4.0f, rainBottom.y(), 1.0e-5f);
        assertEquals(20.5f, rainBottom.z(), 1.0e-5f);
        assertEquals(0.25f, rainBottom.u(), 1.0e-5f);
        assertEquals(29.3f, rainBottom.v(), 1.0e-5f); // preserve vanilla's animated offset with shorter repeated streaks
        assertEquals(0.336f, rainBottom.alpha(), 1.0e-5f);
        assertEquals(0.12f, rainBottom.halfWidth(), 1.0e-5f);
        assertEquals(0x00F000A0, rainBottom.lightCoords());
        assertEquals(0.4f, mesh.quads().get(2).vertices().getFirst().halfWidth(), 1.0e-5f);
    }

    @Test
    void weatherMeshUsesParticlePrimaryMaskAndZeroFirstFrameMotion() {
        RtWeatherSnapshot snapshot = new RtWeatherSnapshot(
                List.of(new RtWeatherSnapshot.Column(1, 2, 3, 4, 0f, 0f, 0)),
                List.of(), 1f, 4, 1L);

        RtWeatherSnapshot.Mesh mesh = snapshot.mesh(0, 0, 0, 0.0, 0.0);

        assertEquals(RtEntities.PARTICLE_BIT, mesh.instanceBit());
        assertEquals(RtEntities.PARTICLE_MASK, mesh.visibilityMask());
        assertEquals(new RtWeatherSnapshot.Motion(0f, 0f, 0f), mesh.motion());
    }

    @Test
    void rainIsLighterAndNarrowerWhileSnowKeepsItsDistanceFade() {
        RtWeatherSnapshot snapshot = new RtWeatherSnapshot(
                List.of(
                        new RtWeatherSnapshot.Column(0, 0, 2, 3, 0f, 0f, 0),
                        new RtWeatherSnapshot.Column(10, 0, 2, 3, 0f, 0f, 0)),
                List.of(
                        new RtWeatherSnapshot.Column(0, 0, 2, 3, 0f, 0f, 0),
                        new RtWeatherSnapshot.Column(10, 0, 2, 3, 0f, 0f, 0)),
                0.6f, 10, 2L);

        RtWeatherSnapshot.Mesh mesh = snapshot.mesh(0, 0, 0, 0.5, 0.5);

        assertEquals(0.252f, mesh.quads().get(0).vertices().getFirst().alpha(), 1.0e-5f);
        assertEquals(0.096f, mesh.quads().get(2).vertices().getFirst().alpha(), 1.0e-5f);
        assertEquals(0.372f, mesh.quads().get(4).vertices().getFirst().alpha(), 1.0e-5f);
        assertEquals(0.228f, mesh.quads().get(6).vertices().getFirst().alpha(), 1.0e-5f);
    }

    @Test
    void zeroRadiusUsesFiniteFarDistanceAlpha() {
        RtWeatherSnapshot snapshot = new RtWeatherSnapshot(
                List.of(new RtWeatherSnapshot.Column(0, 0, 2, 3, 0f, 0f, 0)),
                List.of(), 0.6f, 0, 3L);

        float alpha = snapshot.mesh(0, 0, 0, 0.5, 0.5)
                .quads().getFirst().vertices().getFirst().alpha();

        assertTrue(Float.isFinite(alpha));
        assertEquals(0.096f, alpha, 1.0e-5f);
    }

    @Test
    void snowBendsInBothHorizontalDirectionsAndKeepsSegmentSeamsConnected() {
        RtWeatherSnapshot.Column column = new RtWeatherSnapshot.Column(17, -9, 64, 73, 0f, 0.4f, 0x00F000F0);
        RtWeatherSnapshot snapshot = new RtWeatherSnapshot(List.of(), List.of(column), 1f, 12, 3L, 2.5f);

        RtWeatherSnapshot.Mesh mesh = snapshot.mesh(0, 0, 0, 17.5, -8.5, 2.48f);
        assertEquals(6, mesh.quads().size()); // three paired segments
        RtWeatherSnapshot.Vertex first = mesh.quads().get(0).vertices().getFirst();
        RtWeatherSnapshot.Vertex middle = mesh.quads().get(2).vertices().getFirst();
        RtWeatherSnapshot.Vertex last = mesh.quads().get(4).vertices().getFirst();
        assertEquals(mesh.quads().get(0).vertices().get(1), middle);
        assertEquals(mesh.quads().get(2).vertices().get(1), last);
        assertNotEquals(middle.x() - first.x(), last.x() - middle.x(), 1.0e-4f);
        assertNotEquals(mesh.quads().get(1).vertices().get(1).z() - mesh.quads().get(1).vertices().getFirst().z(),
                mesh.quads().get(3).vertices().get(1).z() - mesh.quads().get(3).vertices().getFirst().z(), 1.0e-4f);
        assertTrue(Math.abs(first.motionX()) + Math.abs(first.motionZ()) > 1.0e-5f);
        assertEquals(column.topY() * 0.30f + column.vOffset(), first.v(), 1.0e-5f);
    }

    @Test
    void snowDriftIsWorldAnchoredAndRainRemainsStationary() {
        RtWeatherSnapshot.Column column = new RtWeatherSnapshot.Column(17, -9, 64, 73, 0f, 0f, 0x00F000F0);
        RtWeatherSnapshot snapshot = new RtWeatherSnapshot(List.of(column), List.of(column), 1f, 12, 3L, 2.5f);
        RtWeatherSnapshot.Mesh world = snapshot.mesh(0, 0, 0, 17.5, -8.5, 2.48f);
        RtWeatherSnapshot.Mesh rebased = snapshot.mesh(16, 64, -16, 17.5, -8.5, 2.48f);
        assertEquals(2, world.quads().stream().filter(q -> q.kind() == RtWeatherSnapshot.Kind.RAIN).count());
        for (int i = 0; i < world.quads().size(); i++) {
            for (int j = 0; j < 4; j++) {
                RtWeatherSnapshot.Vertex a = world.quads().get(i).vertices().get(j);
                RtWeatherSnapshot.Vertex b = rebased.quads().get(i).vertices().get(j);
                assertEquals(a.x(), b.x() + 16f, 1.0e-5f);
                assertEquals(a.y(), b.y() + 64f, 1.0e-5f);
                assertEquals(a.z(), b.z() - 16f, 1.0e-5f);
                assertEquals(a.motionX(), b.motionX(), 1.0e-5f);
            }
        }
        assertEquals(0f, world.quads().getFirst().vertices().getFirst().motionX());
    }

    @Test
    void snowUvsScrollDownWithVanillasNegativeTimeOffset() {
        RtWeatherSnapshot.Column initial = new RtWeatherSnapshot.Column(0, 0, 64, 68, 0f, 0f, 0);
        RtWeatherSnapshot.Column later = new RtWeatherSnapshot.Column(0, 0, 64, 68, 0f, -0.05f, 0);
        RtWeatherSnapshot.Mesh first = new RtWeatherSnapshot(List.of(), List.of(initial), 1f, 4, 1L)
                .mesh(0, 0, 0, 0.5, 0.5);
        RtWeatherSnapshot.Mesh second = new RtWeatherSnapshot(List.of(), List.of(later), 1f, 4, 2L)
                .mesh(0, 0, 0, 0.5, 0.5);

        float bottomUv = first.quads().getFirst().vertices().getFirst().v();
        float topUv = first.quads().getFirst().vertices().get(1).v();
        assertTrue(bottomUv > topUv); // vanilla maps topY to the lower V coordinate
        assertEquals(-0.05f, second.quads().getFirst().vertices().getFirst().v() - bottomUv, 1.0e-5f);
        assertEquals(1.2f, bottomUv - first.quads().get(3).vertices().get(1).v(), 1.0e-5f);
    }
}
