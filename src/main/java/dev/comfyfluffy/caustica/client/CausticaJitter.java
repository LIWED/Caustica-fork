package dev.comfyfluffy.caustica.client;

/**
 * Sub-pixel camera jitter for DLSS Ray Reconstruction.
 *
 * <p>Generates a Halton(2,3) low-discrepancy sequence in render-pixel space, with the DLSS phase-count
 * rule {@code ceil(8 * (display/render)^2)} and RR's recommended floor of 32 phases.
 * {@link dev.comfyfluffy.caustica.rt.RtComposite} reads the per-frame offset, applies it to the primary ray in the
 * path-tracing shader, and reports the opposite projection/image displacement to DLSS-RR.
 */
public final class CausticaJitter {
	public static final CausticaJitter INSTANCE = new CausticaJitter();

	private int frameIndex;
	private float pixelsX;
	private float pixelsY;

	private CausticaJitter() {
	}

	/** Advance one frame. Call once per RT frame before the primary-ray dispatch. */
	public void prepare(int renderWidth, int renderHeight, int displayWidth) {
		int phaseCount = jitterPhaseCount(renderWidth, displayWidth);
		int index = (this.frameIndex++ % phaseCount) + 1; // Halton(0) is degenerate
		this.pixelsX = halton(index, 2) - 0.5f;
		this.pixelsY = halton(index, 3) - 0.5f;
	}

	/** Sample-location offset in render pixels; RR evaluate receives the opposite image displacement. */
	public float jitterPixelsX() {
		return this.pixelsX;
	}

	public float jitterPixelsY() {
		return this.pixelsY;
	}

	private static int jitterPhaseCount(int renderWidth, int displayWidth) {
		float ratio = (float) displayWidth / Math.max(1, renderWidth);
		return Math.max(32, (int) Math.ceil(8.0f * ratio * ratio));
	}

	private static float halton(int index, int base) {
		float f = 1.0f;
		float result = 0.0f;
		int i = index;
		while (i > 0) {
			f /= base;
			result += f * (i % base);
			i /= base;
		}
		return result;
	}
}
