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
    void rainAndSnowBecomeRebasedCrossQuadsWithAnimatedOriginalUvs() {
        RtWeatherSnapshot snapshot = new RtWeatherSnapshot(
                List.of(new RtWeatherSnapshot.Column(110, 220, 64, 72, 0.25f, 0.5f, 0x00F000A0)),
                List.of(new RtWeatherSnapshot.Column(111, 221, 80, 84, 0.125f, 0.75f, 0x006000F0)),
                0.8f, 10, 20L);

        RtWeatherSnapshot.Mesh mesh = snapshot.mesh(100, 60, 200, 110.5, 220.5);

        assertEquals(4, mesh.quads().size());
        assertEquals(RtWeatherSnapshot.Kind.RAIN, mesh.quads().get(0).kind());
        assertEquals(RtWeatherSnapshot.Kind.SNOW, mesh.quads().get(2).kind());
        RtWeatherSnapshot.Vertex rainBottom = mesh.quads().get(0).vertices().getFirst();
        assertEquals(10.15f, rainBottom.x(), 1.0e-5f);
        assertEquals(4.0f, rainBottom.y(), 1.0e-5f);
        assertEquals(20.5f, rainBottom.z(), 1.0e-5f);
        assertEquals(0.25f, rainBottom.u(), 1.0e-5f);
        assertEquals(16.5f, rainBottom.v(), 1.0e-5f); // vanilla vOffset already includes game-time animation
        assertEquals(0.336f, rainBottom.alpha(), 1.0e-5f);
        assertEquals(0.35f, rainBottom.halfWidth(), 1.0e-5f);
        assertEquals(0x00F000A0, rainBottom.lightCoords());
        assertEquals(0.5f, mesh.quads().get(2).vertices().getFirst().halfWidth(), 1.0e-5f);
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
        assertEquals(0.48f, mesh.quads().get(4).vertices().getFirst().alpha(), 1.0e-5f);
        assertEquals(0.3f, mesh.quads().get(6).vertices().getFirst().alpha(), 1.0e-5f);
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
}
