package dev.comfyfluffy.caustica.client;

import com.mojang.blaze3d.platform.InputConstants;
import dev.comfyfluffy.caustica.CausticaConfig;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.keymapping.v1.KeyMappingHelper;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import org.lwjgl.glfw.GLFW;

/** Toggle a narrower world field of view without changing the HUD or the held item. */
public final class RtZoom {
    private static KeyMapping toggleKey;
    private static boolean zoomed;
    private static boolean wasActive;
    private static boolean wheelChanged;

    private RtZoom() {
    }

    public static void register() {
        toggleKey = KeyMappingHelper.registerKeyMapping(new KeyMapping(
                "key.caustica.zoom", InputConstants.Type.KEYSYM, GLFW.GLFW_KEY_C, KeyMapping.Category.MISC));
        ClientTickEvents.END_CLIENT_TICK.register(client -> {
            while (toggleKey.consumeClick()) {
                if (client.level != null && client.mouseHandler.isMouseGrabbed()
                        && VanillaRenderController.rtRuntimeWorkRequested()) {
                    zoomed = !zoomed;
                }
            }
            if (client.level == null) {
                zoomed = false;
            }
            boolean active = isActive();
            if (wasActive && !active && wheelChanged) {
                CausticaConfig.save();
                wheelChanged = false;
            }
            wasActive = active;
        });
    }

    public static boolean isActive() {
        Minecraft client = Minecraft.getInstance();
        return zoomed && client.level != null && client.mouseHandler.isMouseGrabbed()
                && VanillaRenderController.rtRuntimeWorkRequested();
    }

    public static float fieldOfView(float originalDegrees) {
        if (!isActive()) return originalDegrees;
        double halfAngle = Math.toRadians(originalDegrees) * 0.5;
        double factor = CausticaConfig.Rt.Composite.ZOOM_FACTOR.value();
        return (float) Math.toDegrees(2.0 * Math.atan(Math.tan(halfAngle) / factor));
    }

    /** Scroll adjusts magnification; Shift-scroll adjusts distant DOF focus while zoom is active. */
    public static boolean adjustFromWheel(double wheelY) {
        if (!isActive() || wheelY == 0.0) return false;
        if (Minecraft.getInstance().hasShiftDown()
                && CausticaConfig.Rt.Composite.DEPTH_OF_FIELD.value()
                && CausticaConfig.Rt.Composite.DEPTH_OF_FIELD_MODE.value() == 1) {
            int previous = CausticaConfig.Rt.Composite.DEPTH_OF_FIELD_FOCUS_DISTANCE.value();
            int next = (int) Math.clamp(Math.round(previous * Math.pow(1.12, wheelY)), 8L, 512L);
            CausticaConfig.Rt.Composite.DEPTH_OF_FIELD_FOCUS_DISTANCE.set(next);
            wheelChanged |= next != previous;
            return true;
        }
        float previous = CausticaConfig.Rt.Composite.ZOOM_FACTOR.value();
        float next = (float) Math.clamp(previous * Math.pow(1.15, wheelY), 1.0, 8.0);
        CausticaConfig.Rt.Composite.ZOOM_FACTOR.set(next);
        wheelChanged |= next != previous;
        return true;
    }
}
