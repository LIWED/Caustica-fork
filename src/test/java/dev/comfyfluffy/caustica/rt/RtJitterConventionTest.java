package dev.comfyfluffy.caustica.rt;

import dev.comfyfluffy.caustica.client.CausticaJitter;
import org.joml.Matrix4f;
import org.joml.Vector4f;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Verify the image displacement from an inverse-projected jittered ray, rather than guessing signs. */
final class RtJitterConventionTest {
    @Test
    void raySamplingOffsetIsOppositeImageDisplacementAndStaticMotionIsZero() {
        for (int renderWidth : new int[] {1920, 1280, 960, 640}) {
            int renderHeight = renderWidth * 9 / 16;
            Matrix4f projection = new Matrix4f().perspective((float) Math.toRadians(70),
                    (float) renderWidth / renderHeight, 0.05f, 10000f, true);
            Matrix4f viewProjection = projection.mul(new Matrix4f().rotateY(0.3f).rotateX(-0.2f));
            Matrix4f inverse = new Matrix4f(viewProjection).invert();
            for (int frame = 0; frame < 64; frame++) {
                CausticaJitter.INSTANCE.prepare(renderWidth, renderHeight, 1920);
                for (float signX : new float[] {-1, 1}) {
                    for (float signY : new float[] {-1, 1}) {
                        float jx = CausticaJitter.INSTANCE.jitterPixelsX() * signX;
                        float jy = CausticaJitter.INSTANCE.jitterPixelsY() * signY;
                        float centreX = 0.13f, centreY = -0.27f;
                        float sampleX = centreX + 2 * jx / renderWidth;
                        float sampleY = centreY + 2 * jy / renderHeight;
                        Vector4f point = inverse.transform(new Vector4f(sampleX, sampleY, 0.4f, 1));
                        point.div(point.w);
                        Vector4f clip = viewProjection.transform(point);
                        float currentX = clip.x / clip.w, currentY = clip.y / clip.w;
                        // A projected image must shift by -sample jitter to land at the storage pixel.
                        assertEquals(centreX, currentX - 2 * jx / renderWidth, 1e-6f);
                        assertEquals(centreY, currentY - 2 * jy / renderHeight, 1e-6f);
                        // Unjittered previous VP and current ray NDC produce zero static scene motion.
                        assertEquals(0f, (currentX - sampleX) * 0.5f * renderWidth, 0.001f);
                        assertEquals(0f, (currentY - sampleY) * 0.5f * renderHeight, 0.001f);
                    }
                }
            }
        }
    }

    @Test
    void productionWiringUsesRenderPixelsAndDoesNotIncludeJitterInMotion() throws Exception {
        String composite = Files.readString(Path.of("src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java"));
        String primary = Files.readString(Path.of("shaders/world/world_primary.rgen.slang"));
        String guides = Files.readString(Path.of("shaders/world/guides.slang"));
        assertTrue(composite.contains("new Float2(jitterX, jitterY)"));
        assertTrue(composite.contains("-jitterX, -jitterY, frameViewRotation, frameProjection"));
        assertTrue(primary.contains("(uv + worldPush.jitter / size) * 2.0 - 1.0"));
        assertTrue(guides.contains("(prevClip.xy / prevClip.w - curNdc) * 0.5 * size"));
    }
}
