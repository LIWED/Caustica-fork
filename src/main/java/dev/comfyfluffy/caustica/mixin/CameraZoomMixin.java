package dev.comfyfluffy.caustica.mixin;

import com.llamalad7.mixinextras.injector.ModifyReturnValue;
import dev.comfyfluffy.caustica.client.RtZoom;
import net.minecraft.client.Camera;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;

@Mixin(Camera.class)
public abstract class CameraZoomMixin {
    @ModifyReturnValue(method = "calculateFov(F)F", at = @At("RETURN"))
    private float caustica$zoomWorldFov(float original) {
        return RtZoom.fieldOfView(original);
    }
}
