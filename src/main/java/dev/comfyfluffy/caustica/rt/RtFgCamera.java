package dev.comfyfluffy.caustica.rt;

import org.joml.Matrix4f;
import org.joml.Matrix4fc;

/** Jitter-free camera transforms for FG, from the same frame snapshot used by the motion guides. */
final class RtFgCamera {
    final Matrix4f viewToClip = new Matrix4f();
    final Matrix4f clipToView = new Matrix4f();
    final Matrix4f clipToPrev = new Matrix4f();
    final Matrix4f prevToClip = new Matrix4f();

    void prepare(Matrix4fc projection, Matrix4fc currentVp, Matrix4fc previousVp,
            float cameraDeltaX, float cameraDeltaY, float cameraDeltaZ) {
        viewToClip.set(projection);
        clipToView.set(projection).invert();
        // A point relative to the current camera becomes relative to the previous camera by adding
        // currentCamera - previousCamera, exactly as in guides.slang. Camera motion in the MV texture
        // does not remove the requirement for correct camera transforms.
        prevToClip.set(currentVp).invert(); // temporary inverse, reused below
        clipToPrev.set(previousVp).translate(cameraDeltaX, cameraDeltaY, cameraDeltaZ).mul(prevToClip);
        prevToClip.set(clipToPrev).invert();
    }
}
