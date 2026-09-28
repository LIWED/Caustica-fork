package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertTrue;

/** Guards the image-lifetime boundary that a reused Vulkan handle alone cannot identify. */
final class RtDescriptorRebindContractTest {
    private static final Path JAVA = Path.of("src", "main", "java", "dev", "comfyfluffy", "caustica", "rt");

    @Test
    void resizedImagesForceFreshDescriptorsBeforeOldViewsAreDestroyed() throws IOException {
        String composite = Files.readString(JAVA.resolve("RtComposite.java"));
        String resize = method(composite, "private void ensureOutput(");
        assertInOrder(resize, "ctx.waitIdle();", "displayPipeline.invalidateBindings();",
                "exposure.invalidateBindings();", "hdrCompositePipeline.invalidateBindings();",
                "displayImage.destroy();", "displayPipeline.setImages(");

        String menuPresent = method(composite, "public boolean presentSdrToPq(");
        assertInOrder(menuPresent, "ctx.waitIdle();", "sdrPresentPipeline.invalidateBindings();",
                "sdrPresentImage.destroy();", "sdrPresentPipeline.setImages(");

        for (String source : new String[] {"RtDisplayPipeline.java", "RtHdrCompositePipeline.java",
                "RtSdrPresentPipeline.java", "RtExposurePipeline.java"}) {
            String pipeline = Files.readString(JAVA.resolve("pipeline").resolve(source));
            assertTrue(method(pipeline, "public void invalidateBindings(").contains("bindingsDirty = true;"),
                    source + " must forget descriptor bindings even if numeric handles are reused");
        }
        String exposure = Files.readString(JAVA.resolve("pipeline").resolve("RtExposure.java"));
        assertTrue(method(exposure, "public void invalidateBindings(")
                .contains("pipeline.invalidateBindings();"));
    }

    private static String method(String source, String signature) {
        int start = source.indexOf(signature);
        assertTrue(start >= 0, "missing method " + signature);
        int open = source.indexOf('{', start);
        int depth = 0;
        for (int i = open; i < source.length(); i++) {
            if (source.charAt(i) == '{') depth++;
            if (source.charAt(i) == '}' && --depth == 0) return source.substring(open, i + 1);
        }
        throw new AssertionError("unclosed method " + signature);
    }

    private static void assertInOrder(String source, String... markers) {
        int previous = -1;
        for (String marker : markers) {
            int next = source.indexOf(marker, previous + 1);
            assertTrue(next > previous, "missing or out of order: " + marker);
            previous = next;
        }
    }
}
