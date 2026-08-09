package dev.comfyfluffy.caustica.mixin;

import net.minecraft.client.multiplayer.ClientLevel;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Invoker;

/** Exposes the hideLightningFlash-aware sky flash countdown to the RT weather push. */
@Mixin(ClientLevel.class)
public interface ClientLevelInvoker {
    @Invoker("getSkyFlashTime")
    int caustica$getSkyFlashTime();
}
