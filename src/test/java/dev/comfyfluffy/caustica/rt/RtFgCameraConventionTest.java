package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;
import org.joml.Matrix4f;
import org.joml.Vector4f;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertEquals;

final class RtFgCameraConventionTest {
    @Test
    void temporalTransformsMatchDirectProjectionOfWorldPointsIncludingCameraTranslation() {
        Matrix4f previousProjection = new Matrix4f().perspective((float) Math.toRadians(70), 16f / 9f,
                10000f, 0.05f, true); // reversed-Z, as used by the runtime guides
        // Change both orientation and projection, as with movement plus fullscreen/aspect/FOV changes.
        Matrix4f currentProjection = new Matrix4f().perspective((float) Math.toRadians(63), 2560f / 1600f,
                10000f, 0.05f, true);
        Matrix4f previousVp = new Matrix4f(previousProjection).rotateY(-0.15f).rotateX(0.07f);
        Matrix4f currentVp = new Matrix4f(currentProjection).rotateY(0.2f).rotateX(-0.05f);
        RtFgCamera camera = new RtFgCamera();
        camera.prepare(currentProjection, currentVp, previousVp, 2.3f, -0.7f, 1.2f);
        for (float x : new float[] {-5, 0, 6}) {
            for (float z : new float[] {-8, -30, -100}) {
                Vector4f currentPoint = new Vector4f(x, 1.5f, z, 1);
                Vector4f currentClip = currentVp.transform(new Vector4f(currentPoint));
                Vector4f previousPoint = new Vector4f(currentPoint).add(2.3f, -0.7f, 1.2f, 0);
                Vector4f expectedPrevious = previousVp.transform(previousPoint);
                assertNdc(expectedPrevious, camera.clipToPrev.transform(new Vector4f(currentClip)));
                assertNdc(currentClip, camera.prevToClip.transform(new Vector4f(expectedPrevious)));
                assertNdc(currentPoint, camera.clipToView.transform(
                        camera.viewToClip.transform(new Vector4f(currentPoint))));
            }
        }
    }

    @Test
    void firstAndStaticFramesPreserveClipPositions() {
        Matrix4f projection = new Matrix4f().perspective((float) Math.toRadians(70), 16f / 9f,
                10000f, 0.05f, true);
        Matrix4f vp = new Matrix4f(projection).rotateY(0.3f);
        RtFgCamera camera = new RtFgCamera();
        camera.prepare(projection, vp, vp, 0, 0, 0);
        Vector4f clip = vp.transform(new Vector4f(1, 3, -25, 1));
        assertNdc(clip, camera.clipToPrev.transform(new Vector4f(clip)));
        assertNdc(clip, camera.prevToClip.transform(new Vector4f(clip)));
    }

    private static void assertNdc(Vector4f expected, Vector4f actual) {
        assertEquals(expected.x / expected.w, actual.x / actual.w, 0.0001f);
        assertEquals(expected.y / expected.w, actual.y / actual.w, 0.0001f);
        assertEquals(expected.z / expected.w, actual.z / actual.w, 0.0001f);
    }

    @Test
    void fgConsumesThePreviousFrameSnapshotAndProjectionInsteadOfOverwrittenHistory() throws Exception {
        String composite = Files.readString(Path.of("src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java"));
        String backend = Files.readString(Path.of("src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtDlssFg.java"));
        assertFalse(composite.contains("fgClipToPrev.set(mvPrevProjView)"),
                "updateMotion has already advanced mvPrevProjView to the current frame before FG runs");
        assertTrue(composite.contains("fgCamera.prepare(frameProjection, mvCurProjView, mvPushMatrix,"));
        assertFalse(backend.contains("MemorySegment.NULL, MemorySegment.NULL, clipToPrev, prevToClip"),
                "DLSS-FG requires view/clip projection matrices alongside the temporal transforms");
    }
}
