package dev.comfyfluffy.caustica.rt.entity;

import net.minecraft.client.renderer.rendertype.RenderTypes;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/** Vanilla's depth-only boat water patch must never become visible RT geometry. */
final class RtBoatWaterMaskTest {
    @Test
    void waterMaskSubmissionDoesNotResolveMaterialsOrDrawAModel() {
        RtEntityCollector collector = new RtEntityCollector();
        RtEntityCapture capture = new RtEntityCapture();
        collector.begin(capture, false);
        collector.order(3);

        // A mask has no colour texture. Null model/pose also ensure capture returns before posing it.
        assertDoesNotThrow(() -> collector.submitModel(null, null, null, RenderTypes.waterMask(),
                0, 0, 0, null, 0xffabcdef, null));
        assertTrue(capture.verts.isEmpty());
        assertTrue(capture.idx.isEmpty());
        assertTrue(capture.prim.isEmpty());
        assertEquals(0, collector.outlineColor());
    }
}
