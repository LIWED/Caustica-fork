package dev.comfyfluffy.caustica.mixin;

import dev.comfyfluffy.caustica.client.RtZoom;
import net.minecraft.client.MouseHandler;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(MouseHandler.class)
public abstract class MouseZoomMixin {
    @Inject(method = "onScroll(JDD)V", at = @At("HEAD"), cancellable = true)
    private void caustica$adjustZoom(long window, double scrollX, double scrollY, CallbackInfo ci) {
        if (RtZoom.adjustFromWheel(scrollY)) {
            ci.cancel();
        }
    }
}
