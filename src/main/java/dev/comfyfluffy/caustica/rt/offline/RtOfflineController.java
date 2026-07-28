package dev.comfyfluffy.caustica.rt.offline;

import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.CausticaMod;
import net.minecraft.client.Minecraft;
import net.minecraft.client.server.IntegratedServer;
import net.minecraft.network.chat.Component;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;

/**
 * Client-side coordinator for Offline Rendering stability, tick freezing, and
 * user-visible accumulation state.
 */
public final class RtOfflineController {
    public static final RtOfflineController INSTANCE = new RtOfflineController();

    private static final double POSITION_EPSILON = 1.0e-7;
    private static final float MATRIX_EPSILON = 1.0e-6f;

    private final OfflineAccumulationState accumulation = new OfflineAccumulationState();
    private final OfflineFreezeOwnership freezeOwnership = new OfflineFreezeOwnership();
    private final Matrix4f previousProjection = new Matrix4f();
    private final Matrix4f previousViewRotation = new Matrix4f();

    private boolean sessionActive;
    private boolean hasPreviousCamera;
    private volatile boolean currentFrameAccumulating;
    private volatile boolean freezeRequestScheduled;
    private volatile boolean thawRequestScheduled;
    private volatile boolean thawPending;
    private boolean frozenWaterTimeCaptured;
    private boolean hasRenderSignature;
    private long frozenInputRevision;
    private long previousRenderSignature;
    private double previousCameraX;
    private double previousCameraY;
    private double previousCameraZ;
    private float frozenWaterTime;
    private volatile long freezeGeneration;
    private volatile long sessionToken;
    private IntegratedServer managedServer;

    private RtOfflineController() {
    }

    public static boolean enabled() {
        return CausticaConfig.Rt.ENABLED.value() && CausticaConfig.Rt.Offline.ENABLED.value();
    }

    public static boolean accumulating() {
        return INSTANCE.currentFrameAccumulating;
    }

    /**
     * Reconcile setting/world lifecycle every client tick. This runs even when
     * the RT runtime is being torn down so an owned server freeze is restored.
     */
    public void clientTick(Minecraft client, boolean rtRuntimeRequested) {
        if (!enabled() || !rtRuntimeRequested || client.level == null) {
            endSession();
            return;
        }
        if (!sessionActive) {
            synchronized (this) {
                sessionActive = true;
                accumulation.clear();
                hasPreviousCamera = false;
                currentFrameAccumulating = false;
                freezeRequestScheduled = false;
                thawRequestScheduled = false;
                if (!freezeOwnership.ownsFreeze()) {
                    thawPending = false;
                    managedServer = null;
                }
                frozenWaterTimeCaptured = false;
                hasRenderSignature = false;
                frozenInputRevision++;
                freezeGeneration++;
                sessionToken++;
            }
        }
    }

    public OfflineAccumulationState.Decision beforeTrace(
            Matrix4fc projection,
            Matrix4fc viewRotation,
            double cameraX,
            double cameraY,
            double cameraZ,
            long renderSignature,
            int spp) {
        Minecraft client = Minecraft.getInstance();
        if (!enabled() || client.level == null) {
            endSession();
            return accumulation.observe(
                    false, false, System.nanoTime(), renderSignature, false, false, spp);
        }
        if (!sessionActive) {
            clientTick(client, true);
        }

        boolean cameraChanged = cameraChanged(projection, viewRotation, cameraX, cameraY, cameraZ);
        rememberCamera(projection, viewRotation, cameraX, cameraY, cameraZ);
        if (cameraChanged) {
            synchronized (this) {
                currentFrameAccumulating = false;
                frozenWaterTimeCaptured = false;
                frozenInputRevision++;
                if (!thawPending) {
                    freezeGeneration++;
                    freezeRequestScheduled = false;
                    thawRequestScheduled = false;
                    if (freezeOwnership.ownsFreeze()) {
                        thawPending = true;
                    }
                }
            }
        }
        if (!hasRenderSignature || previousRenderSignature != renderSignature) {
            hasRenderSignature = true;
            previousRenderSignature = renderSignature;
            frozenWaterTimeCaptured = false;
            frozenInputRevision++;
        }

        IntegratedServer localServer = client.getSingleplayerServer();
        boolean localAutoFreezeAvailable = localServer != null && localServer.isRunning();
        IntegratedServer thawServer = localServer != null ? localServer : managedServer;
        if (thawPending && freezeOwnership.ownsFreeze()
                && thawServer != null && thawServer.isRunning()) {
            requestIntegratedServerThaw(thawServer);
        }
        boolean frozen = thawPending
                ? false
                : OfflineModePolicy.worldFrozen(client.level.tickRateManager().isFrozen());
        if (frozen) {
            freezeRequestScheduled = false;
        }
        OfflineAccumulationState.Decision decision = accumulation.observe(
                true, cameraChanged, System.nanoTime(),
                renderSignature, localAutoFreezeAvailable, frozen, spp);
        currentFrameAccumulating = decision.accumulate();

        if (localAutoFreezeAvailable
                && (decision.requestFreeze()
                || (decision.phase() == OfflineAccumulationState.Phase.FREEZING && !frozen))) {
            requestIntegratedServerFreeze(localServer);
        }
        return decision;
    }

    /**
     * Return a render-local frozen water clock after accumulation starts.
     * Minecraft's tick freeze does not stop the shader's System.nanoTime input.
     */
    public float waterTime(float liveTime) {
        if (frozenWaterTimeCaptured) {
            return frozenWaterTime;
        }
        if (accumulation.phase() != OfflineAccumulationState.Phase.ACCUMULATING) {
            return liveTime;
        }
        frozenWaterTime = liveTime;
        frozenWaterTimeCaptured = true;
        return frozenWaterTime;
    }

    public long frozenInputRevision() {
        return frozenInputRevision;
    }

    public long accumulatedSamples() {
        return accumulation.accumulatedSamples();
    }

    public Component hudText() {
        if (!enabled() || !sessionActive) {
            return null;
        }
        return switch (accumulation.phase()) {
            case DISABLED, HOLD_STILL -> Component.translatable("caustica.offline.holdStill");
            case FREEZING -> Component.translatable("caustica.offline.freezing");
            case MANUAL_FREEZE_REQUIRED -> Component.translatable("caustica.offline.manualFreeze");
            case ACCUMULATING -> Component.translatable(
                    "caustica.offline.samples", accumulation.accumulatedSamples());
        };
    }

    public void shutdown() {
        endSession();
    }

    private boolean cameraChanged(Matrix4fc projection, Matrix4fc viewRotation,
                                  double cameraX, double cameraY, double cameraZ) {
        if (!hasPreviousCamera) {
            return true;
        }
        return Math.abs(cameraX - previousCameraX) > POSITION_EPSILON
                || Math.abs(cameraY - previousCameraY) > POSITION_EPSILON
                || Math.abs(cameraZ - previousCameraZ) > POSITION_EPSILON
                || !previousProjection.equals(projection, MATRIX_EPSILON)
                || !previousViewRotation.equals(viewRotation, MATRIX_EPSILON);
    }

    private void rememberCamera(Matrix4fc projection, Matrix4fc viewRotation,
                                double cameraX, double cameraY, double cameraZ) {
        previousProjection.set(projection);
        previousViewRotation.set(viewRotation);
        previousCameraX = cameraX;
        previousCameraY = cameraY;
        previousCameraZ = cameraZ;
        hasPreviousCamera = true;
    }

    private void requestIntegratedServerFreeze(IntegratedServer server) {
        long requestToken;
        long requestGeneration;
        synchronized (this) {
            if (freezeRequestScheduled || thawPending) {
                return;
            }
            freezeRequestScheduled = true;
            managedServer = server;
            requestToken = sessionToken;
            requestGeneration = freezeGeneration;
        }
        server.executeIfPossible(() -> {
            synchronized (RtOfflineController.this) {
                if (requestToken != sessionToken
                        || requestGeneration != freezeGeneration
                        || !sessionActive) {
                    return;
                }
                try {
                    boolean alreadyFrozen = server.tickRateManager().isFrozen();
                    server.tickRateManager().setFrozen(true);
                    freezeOwnership.onFreezeConfirmed(alreadyFrozen);
                    freezeRequestScheduled = false;
                } catch (Throwable t) {
                    freezeRequestScheduled = false;
                    CausticaMod.LOGGER.warn("Offline Rendering could not freeze integrated-server ticks", t);
                }
            }
        });
    }

    private void requestIntegratedServerThaw(IntegratedServer server) {
        long requestToken;
        long requestGeneration;
        synchronized (this) {
            if (!thawPending || thawRequestScheduled || !freezeOwnership.ownsFreeze()) {
                return;
            }
            thawRequestScheduled = true;
            managedServer = server;
            requestToken = sessionToken;
            requestGeneration = freezeGeneration;
        }
        server.executeIfPossible(() -> {
            synchronized (RtOfflineController.this) {
                if (requestToken != sessionToken || requestGeneration != freezeGeneration) {
                    return;
                }
                try {
                    server.tickRateManager().setFrozen(false);
                    freezeOwnership.consumeRestoreRequired();
                    thawPending = false;
                    thawRequestScheduled = false;
                    if (!sessionActive) {
                        managedServer = null;
                    }
                } catch (Throwable t) {
                    thawRequestScheduled = false;
                    CausticaMod.LOGGER.warn("Offline Rendering could not thaw integrated-server ticks", t);
                }
            }
        });
    }

    private void endSession() {
        if (!sessionActive) {
            currentFrameAccumulating = false;
            accumulation.clear();
            IntegratedServer retryServer = managedServer;
            if (thawPending && freezeOwnership.ownsFreeze()
                    && retryServer != null && retryServer.isRunning()) {
                requestIntegratedServerThaw(retryServer);
            } else if (!freezeOwnership.ownsFreeze()) {
                managedServer = null;
            }
            return;
        }

        IntegratedServer server;
        synchronized (this) {
            sessionActive = false;
            sessionToken++;
            freezeGeneration++;
            currentFrameAccumulating = false;
            freezeRequestScheduled = false;
            thawRequestScheduled = false;
            server = managedServer;
            if (freezeOwnership.ownsFreeze() && server != null && server.isRunning()) {
                thawPending = true;
            } else {
                thawPending = false;
                if (freezeOwnership.ownsFreeze()) {
                    freezeOwnership.clearWithoutRestore();
                }
                managedServer = null;
            }
        }
        if (thawPending) {
            requestIntegratedServerThaw(server);
        }

        accumulation.clear();
        hasPreviousCamera = false;
        frozenWaterTimeCaptured = false;
        hasRenderSignature = false;
        frozenInputRevision++;
    }
}
