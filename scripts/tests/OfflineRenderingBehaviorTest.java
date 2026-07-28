import dev.comfyfluffy.caustica.rt.offline.OfflineAccumulationState;
import dev.comfyfluffy.caustica.rt.offline.OfflineFreezeOwnership;
import dev.comfyfluffy.caustica.rt.offline.OfflineLightMixtureMath;
import dev.comfyfluffy.caustica.rt.offline.OfflineLocalLightIndex;
import dev.comfyfluffy.caustica.rt.offline.OfflineModePolicy;
import dev.comfyfluffy.caustica.rt.offline.PathBouncePolicy;
import dev.comfyfluffy.caustica.rt.offline.OfflineRenderSignature;
import dev.comfyfluffy.caustica.rt.offline.OfflineSampleSequence;
import dev.comfyfluffy.caustica.rt.offline.OfflineSampleWeights;
import dev.comfyfluffy.caustica.rt.offline.OfflineStaticLightMath;

public final class OfflineRenderingBehaviorTest {
    public static void main(String[] args) {
        waitsTwoSecondsBeforeAccumulatingAndPreservesWeights();
        preFrozenWorldWaitsTwoSecondsBeforeAccumulating();
        sparseAndDenseObservationsReachTheSameDecision();
        movementAndInvalidationRestartTheFullDelay();
        multiplayerRequiresManualFreeze();
        disablingClearsState();
        temporalFeaturesFollowActualAccumulationWithoutChangingPreference();
        selectsRealtimeAndOfflineBounceRanges();
        currentServerFreezeStateIsAuthoritative();
        restoresOnlyFreezesOwnedByCaustica();
        sanitizesGpuSampleWeights();
        renderSignatureChangesWhenTracedSceneChanges();
        staticLightMathIsFiniteAndSceneSynchronized();
        lightMixtureMathPreservesProbabilityAndRejectsInvalidInputs();
        localLightIndexBuildsSortedNeighborhoodDirectories();
        localLightIndexRejectsInvalidTopology();
        localLightMixtureNormalizesAndSharesSelectionPdf();
        particleWithoutStaticNeeSkipsReciprocalMis();
        offlineSampleSequenceIsDeterministicAndPixelRotated();
        offlineSampleSequenceHasNoShortPhaseRepeat();
        offlineSampleSequenceRetainsHighIndexPrecision();
        offlinePhaseToUnitCoversFullHigh24Range();
        System.out.println("Offline rendering behavior: PASS");
    }

    private static void waitsTwoSecondsBeforeAccumulatingAndPreservesWeights() {
        OfflineAccumulationState state = new OfflineAccumulationState();

        assertEquals(OfflineAccumulationState.Phase.HOLD_STILL,
                state.observe(true, true, 0L, 10L, true, false, 4).phase(),
                "first camera frame must hold");
        assertEquals(OfflineAccumulationState.Phase.HOLD_STILL,
                state.observe(true, false, 1_999_999_999L, 10L, true, false, 4).phase(),
                "one nanosecond before the delay must hold");

        OfflineAccumulationState.Decision arm =
                state.observe(true, false, 2_000_000_000L, 10L, true, false, 4);
        assertEquals(OfflineAccumulationState.Phase.FREEZING, arm.phase(),
                "exactly two seconds must request freeze");
        assertTrue(arm.requestFreeze(), "exactly two seconds must request an automatic freeze");
        assertFalse(arm.accumulate(), "unconfirmed freeze must not accumulate");
        assertFalse(state.observe(true, false, 2_000_000_001L, 10L, true, false, 4).requestFreeze(),
                "automatic freeze must only be requested once");

        OfflineAccumulationState.Decision first =
                state.observe(true, false, 2_000_000_002L, 10L, true, true, 4);
        assertEquals(OfflineAccumulationState.Phase.ACCUMULATING, first.phase(),
                "confirmed freeze must accumulate");
        assertTrue(first.accumulate(), "first frozen frame must accumulate");
        assertTrue(first.resetHistory(), "first frozen frame must replace stale GPU history");
        assertEquals(0L, first.previousSamples(), "first frame has no previous samples");
        assertEquals(4, first.currentSamples(), "current SPP is the frame weight");
        assertEquals(4L, state.accumulatedSamples(), "sample total after first frame");

        OfflineAccumulationState.Decision second =
                state.observe(true, false, 2_000_000_003L, 10L, true, true, 8);
        assertTrue(second.accumulate(), "subsequent frozen frame must accumulate");
        assertFalse(second.resetHistory(), "subsequent frame must retain GPU history");
        assertEquals(4L, second.previousSamples(), "second frame sees prior weighted samples");
        assertEquals(8, second.currentSamples(), "changed SPP becomes the new frame weight");
        assertEquals(12L, state.accumulatedSamples(), "sample total must be SPP weighted");
    }

    private static void sparseAndDenseObservationsReachTheSameDecision() {
        OfflineAccumulationState dense = new OfflineAccumulationState();
        OfflineAccumulationState sparse = new OfflineAccumulationState();
        dense.observe(true, true, 100L, 10L, true, false, 1);
        dense.observe(true, false, 1_000_000_100L, 10L, true, false, 1);
        OfflineAccumulationState.Decision denseDecision =
                dense.observe(true, false, 2_000_000_100L, 10L, true, false, 1);
        sparse.observe(true, true, 100L, 10L, true, false, 1);
        OfflineAccumulationState.Decision sparseDecision =
                sparse.observe(true, false, 2_000_000_100L, 10L, true, false, 1);
        assertEquals(denseDecision.phase(), sparseDecision.phase(),
                "observation density must not change the stability decision");
        assertEquals(denseDecision.requestFreeze(), sparseDecision.requestFreeze(),
                "observation density must not change freeze requests");
    }

    private static void preFrozenWorldWaitsTwoSecondsBeforeAccumulating() {
        OfflineAccumulationState state = new OfflineAccumulationState();
        assertFalse(state.observe(true, true, 0L, 10L, true, true, 1).accumulate(),
                "a pre-frozen world must begin a fresh stability delay");
        assertFalse(state.observe(true, false, 1_999_999_999L, 10L, true, true, 1).accumulate(),
                "a pre-frozen world cannot accumulate before two seconds");
        assertTrue(state.observe(true, false, 2_000_000_000L, 10L, true, true, 1).accumulate(),
                "a pre-frozen world may accumulate after two seconds");
    }

    private static void movementAndInvalidationRestartTheFullDelay() {
        OfflineAccumulationState state = new OfflineAccumulationState();
        state.observe(true, true, 0L, 10L, true, false, 1);
        OfflineAccumulationState.Decision moved =
                state.observe(true, true, 1_900_000_000L, 10L, true, false, 1);
        assertTrue(moved.resetHistory(), "movement must invalidate GPU history");
        assertEquals(OfflineAccumulationState.Phase.HOLD_STILL,
                state.observe(true, false, 3_899_999_999L, 10L, true, false, 1).phase(),
                "movement at 1.9 seconds restarts the full delay");
        assertTrue(state.observe(true, false, 3_900_000_000L, 10L, true, false, 1).requestFreeze(),
                "the restarted delay must finish exactly two seconds after movement");

        OfflineAccumulationState reset = new OfflineAccumulationState();
        reset.observe(true, true, 0L, 10L, true, false, 1);
        assertTrue(reset.observe(true, false, 1_000_000_000L, 11L, true, false, 1).resetHistory(),
                "render-signature changes reset history");
        assertEquals(OfflineAccumulationState.Phase.HOLD_STILL,
                reset.observe(true, false, 2_999_999_999L, 11L, true, false, 1).phase(),
                "render-signature changes reset the timer");
        reset.observe(false, false, 3_000_000_000L, 11L, true, false, 1);
        assertEquals(OfflineAccumulationState.Phase.HOLD_STILL,
                reset.observe(true, false, 4_999_999_999L, 11L, true, false, 1).phase(),
                "disable resets timer and history");
        reset.clear();
        assertEquals(OfflineAccumulationState.Phase.HOLD_STILL,
                reset.observe(true, false, 6_999_999_999L, 11L, true, false, 1).phase(),
                "clear resets timer and history");
        assertFalse(reset.observe(true, false, 6_999_999_998L, 11L, true, false, 1).requestFreeze(),
                "clock rollback restarts the timer");
    }

    private static void multiplayerRequiresManualFreeze() {
        OfflineAccumulationState state = new OfflineAccumulationState();
        state.observe(true, true, 0L, 10L, false, false, 1);

        OfflineAccumulationState.Decision waiting =
                state.observe(true, false, 2_000_000_000L, 10L, false, false, 1);
        assertEquals(OfflineAccumulationState.Phase.MANUAL_FREEZE_REQUIRED, waiting.phase(),
                "remote world must request a manual freeze");
        assertFalse(waiting.requestFreeze(), "remote world must never request automatic freeze");
        assertFalse(waiting.accumulate(), "unfrozen remote world must not accumulate");

        OfflineAccumulationState.Decision frozen =
                state.observe(true, false, 2_000_000_001L, 10L, false, true, 1);
        assertEquals(OfflineAccumulationState.Phase.ACCUMULATING, frozen.phase(),
                "server-confirmed manual freeze permits accumulation");
        assertTrue(frozen.accumulate(), "manually frozen remote world must accumulate");
    }

    private static void disablingClearsState() {
        OfflineAccumulationState state = accumulatingState();

        OfflineAccumulationState.Decision disabled =
                state.observe(false, false, 3_000_000_000L, 10L, true, true, 2);

        assertEquals(OfflineAccumulationState.Phase.DISABLED, disabled.phase(),
                "disabled mode reports disabled phase");
        assertEquals(0L, state.accumulatedSamples(), "disabled mode clears samples");
        assertEquals(OfflineAccumulationState.Phase.DISABLED, state.phase(),
                "stored phase is disabled");
    }

    private static void temporalFeaturesFollowActualAccumulationWithoutChangingPreference() {
        assertTrue(OfflineModePolicy.temporalFeatureEnabled(true, false),
                "enabled temporal preference must remain active while moving or holding still");
        assertTrue(OfflineModePolicy.temporalFeatureEnabled(true, false),
                "enabled temporal preference must remain active while an automatic freeze is pending");
        assertTrue(OfflineModePolicy.temporalFeatureEnabled(true, false),
                "enabled temporal preference must remain active while a manual freeze is required");
        assertFalse(OfflineModePolicy.temporalFeatureEnabled(true, true),
                "only actual accumulation may suppress an enabled temporal preference");
        assertFalse(OfflineModePolicy.temporalFeatureEnabled(false, false),
                "disabled temporal preference remains disabled outside accumulation");
        assertFalse(OfflineModePolicy.temporalFeatureEnabled(false, true),
                "disabled temporal preference remains disabled during accumulation");
        assertTrue(OfflineModePolicy.nativeResolutionRequired(true),
                "actual accumulation requires native-resolution tracing");
        assertFalse(OfflineModePolicy.nativeResolutionRequired(false),
                "all non-accumulating phases may select the DLSS render resolution");
    }

    private static void selectsRealtimeAndOfflineBounceRanges() {
        assertEquals(2, PathBouncePolicy.clampRealtime(1), "realtime lower clamp");
        assertEquals(2, PathBouncePolicy.clampRealtime(2), "realtime lower bound");
        assertEquals(16, PathBouncePolicy.clampRealtime(16), "realtime upper bound");
        assertEquals(16, PathBouncePolicy.clampRealtime(17), "realtime upper clamp");
        assertEquals(2, PathBouncePolicy.clampOffline(1), "offline lower clamp");
        assertEquals(32, PathBouncePolicy.clampOffline(32), "offline upper bound");
        assertEquals(32, PathBouncePolicy.clampOffline(33), "offline upper clamp");
        assertEquals(12, PathBouncePolicy.effective(false, 12, 24),
                "waiting or moving frames use realtime bounces");
        assertEquals(24, PathBouncePolicy.effective(true, 12, 24),
                "accumulating frames use offline bounces");
        assertEquals(2, PathBouncePolicy.effective(false, -1, 99),
                "effective realtime selection clamps defensively");
        assertEquals(32, PathBouncePolicy.effective(true, -1, 99),
                "effective offline selection clamps defensively");
    }

    private static void currentServerFreezeStateIsAuthoritative() {
        assertTrue(OfflineModePolicy.worldFrozen(true),
                "server-synchronized frozen state permits accumulation");
        assertFalse(OfflineModePolicy.worldFrozen(false),
                "a later server unfreeze must override any earlier confirmation");

        OfflineAccumulationState state = accumulatingState();
        OfflineAccumulationState.Decision lostFreeze =
                state.observe(true, false, 2_000_000_010L, 10L, true, false, 4);
        assertEquals(OfflineAccumulationState.Phase.FREEZING, lostFreeze.phase(),
                "losing frozen state returns to freezing phase");
        assertFalse(lostFreeze.accumulate(),
                "losing frozen state stops accumulation immediately");
    }

    private static void restoresOnlyFreezesOwnedByCaustica() {
        OfflineFreezeOwnership owned = new OfflineFreezeOwnership();
        assertTrue(owned.onFreezeConfirmed(false),
                "freezing a running world must establish Caustica ownership");
        assertTrue(owned.ownsFreeze(), "owned freezes must be observable before cleanup");
        assertTrue(owned.onFreezeConfirmed(true),
                "a repeated already-frozen confirmation must not erase existing ownership");
        assertTrue(owned.consumeRestoreRequired(),
                "owned freeze must request one restore");
        assertFalse(owned.consumeRestoreRequired(),
                "owned freeze restore must be consumed exactly once");

        OfflineFreezeOwnership borrowed = new OfflineFreezeOwnership();
        assertFalse(borrowed.onFreezeConfirmed(true),
                "an already frozen world remains user-owned");
        assertFalse(borrowed.ownsFreeze(), "borrowed freezes are never owned by Caustica");
        assertFalse(borrowed.consumeRestoreRequired(),
                "user-owned frozen state must never be restored by Caustica");

        OfflineFreezeOwnership cancelled = new OfflineFreezeOwnership();
        cancelled.onFreezeConfirmed(false);
        cancelled.clearWithoutRestore();
        assertFalse(cancelled.consumeRestoreRequired(),
                "world teardown clears ownership without touching a dead server");
    }

    private static void sanitizesGpuSampleWeights() {
        OfflineSampleWeights empty = OfflineSampleWeights.of(-5L, 0, false);
        assertEquals(0, empty.previousSamples(), "negative history clamps to zero");
        assertEquals(1, empty.currentSamples(), "zero SPP clamps to one");

        OfflineSampleWeights normal = OfflineSampleWeights.of(12L, 8, false);
        assertEquals(12, normal.previousSamples(), "normal history remains exact");
        assertEquals(8, normal.currentSamples(), "normal current weight remains exact");

        OfflineSampleWeights reset = OfflineSampleWeights.of(12L, 8, true);
        assertEquals(0, reset.previousSamples(), "reset discards previous GPU history weight");
        assertEquals(8, reset.currentSamples(), "reset retains current frame weight");

        OfflineSampleWeights capped = OfflineSampleWeights.of(Long.MAX_VALUE, Integer.MAX_VALUE, false);
        assertEquals(16_777_208, capped.previousSamples(),
                "history weight caps below float integer precision limit");
        assertEquals(16_777_208, capped.currentSamples(),
                "current weight also caps below float integer precision limit");
    }

    private static void renderSignatureChangesWhenTracedSceneChanges() {
        long base = OfflineRenderSignature.create(
                1920, 1080, 100L, 7L, 0, 4, 0b1111,
                Float.floatToIntBits(0.6f), Float.floatToIntBits(1.5f),
                Float.floatToIntBits(30.0f));
        assertEquals(base, OfflineRenderSignature.create(
                        1920, 1080, 100L, 7L, 0, 4, 0b1111,
                        Float.floatToIntBits(0.6f), Float.floatToIntBits(1.5f),
                        Float.floatToIntBits(30.0f)),
                "identical traced scene must retain its signature");
        assertNotEquals(base, OfflineRenderSignature.create(
                        1280, 720, 100L, 7L, 0, 4, 0b1111,
                        Float.floatToIntBits(0.6f), Float.floatToIntBits(1.5f),
                        Float.floatToIntBits(30.0f)),
                "output resize changes the signature");
        assertNotEquals(base, OfflineRenderSignature.create(
                        1920, 1080, 101L, 7L, 0, 4, 0b1111,
                        Float.floatToIntBits(0.6f), Float.floatToIntBits(1.5f),
                        Float.floatToIntBits(30.0f)),
                "dimension/world identity changes the signature");
        assertNotEquals(base, OfflineRenderSignature.create(
                        1920, 1080, 100L, 8L, 0, 4, 0b1111,
                        Float.floatToIntBits(0.6f), Float.floatToIntBits(1.5f),
                        Float.floatToIntBits(30.0f)),
                "published terrain changes the signature");
        assertNotEquals(base, OfflineRenderSignature.create(
                        1920, 1080, 100L, 7L, 0, 5, 0b1111,
                        Float.floatToIntBits(0.6f), Float.floatToIntBits(1.5f),
                        Float.floatToIntBits(30.0f)),
                "bounce count changes the signature");
        assertNotEquals(base, OfflineRenderSignature.create(
                        1920, 1080, 100L, 7L, 0, 4, 0b0111,
                        Float.floatToIntBits(0.6f), Float.floatToIntBits(1.5f),
                        Float.floatToIntBits(30.0f)),
                "traced feature flags change the signature");
    }

    private static void staticLightMathIsFiniteAndSceneSynchronized() {
        assertEquals(0.0f, OfflineStaticLightMath.pointIntensity(0), 1.0e-6f,
                "level zero light block must not emit");
        assertEquals(0.5890486f, OfflineStaticLightMath.pointIntensity(15), 1.0e-6f,
                "level fifteen light block uses the virtual-sphere energy");
        assertTrue(OfflineStaticLightMath.pointIntensity(1)
                        < OfflineStaticLightMath.pointIntensity(8),
                "light block intensity must increase with its level");
        assertEquals(OfflineStaticLightMath.pointIntensity(15),
                OfflineStaticLightMath.pointIntensity(20), 1.0e-6f,
                "light block levels above fifteen clamp safely");

        assertEquals(1.0f, OfflineStaticLightMath.areaWeight(2.0f, 0.5f), 1.0e-6f,
                "area light selection weight is area times emission");
        assertEquals(0.0f, OfflineStaticLightMath.areaWeight(-2.0f, 0.5f), 1.0e-6f,
                "invalid negative area cannot create selection weight");

        float[] cumulative = {1.0f, 3.0f, 6.0f};
        assertEquals(0, OfflineStaticLightMath.selectCdf(cumulative, 0.0f),
                "CDF start selects the first light");
        assertEquals(1, OfflineStaticLightMath.selectCdf(cumulative, 0.49f),
                "CDF middle selects the second light");
        assertEquals(2, OfflineStaticLightMath.selectCdf(cumulative, 0.999999f),
                "CDF end selects the final light");
        assertEquals(-1, OfflineStaticLightMath.selectCdf(new float[0], 0.5f),
                "empty CDF has no selectable light");

        assertEquals(0.5f, OfflineStaticLightMath.powerHeuristic(2.0f, 2.0f), 1.0e-6f,
                "equal PDFs receive equal MIS weight");
        assertEquals(1.0f, OfflineStaticLightMath.powerHeuristic(2.0f, 0.0f), 1.0e-6f,
                "a unique light-sampling path receives full weight");
        assertEquals(0.0f, OfflineStaticLightMath.powerHeuristic(0.0f, 0.0f), 1.0e-6f,
                "two impossible techniques produce no contribution");

        assertTrue(OfflineStaticLightMath.mayAccumulate(true, 9L, 9L),
                "matching light and terrain revisions may accumulate");
        assertFalse(OfflineStaticLightMath.mayAccumulate(true, 8L, 9L),
                "stale light data must not enter history");
        assertFalse(OfflineStaticLightMath.mayAccumulate(false, 9L, 9L),
                "waiting offline frames must not enable light sampling");
    }

    private static void lightMixtureMathPreservesProbabilityAndRejectsInvalidInputs() {
        float globalFirst = OfflineLightMixtureMath.selectionPdf(1.0f, 4.0f, false, 0.0f);
        float globalSecond = OfflineLightMixtureMath.selectionPdf(3.0f, 4.0f, false, 0.0f);
        assertEquals(1.0f, globalFirst + globalSecond, 1.0e-6f,
                "global-only lights must normalize to one");

        float localFirst = OfflineLightMixtureMath.selectionPdf(1.0f, 4.0f, true, 1.0f);
        float localSecond = OfflineLightMixtureMath.selectionPdf(3.0f, 4.0f, false, 1.0f);
        assertEquals(1.0f, localFirst + localSecond, 1.0e-6f,
                "local/global mixture must normalize to one");
        assertTrue(localSecond > 0.0f,
                "non-local lights must retain a positive global probability");

        assertEquals(0.5f, OfflineLightMixtureMath.areaSolidAnglePdf(0.25f, 8.0f, 2.0f, 2.0f),
                1.0e-6f, "area PDF must convert selection PDF to solid angle");
        assertEquals(0.0f, OfflineLightMixtureMath.alphaCoverageWeight(2.0f, 3.0f, 0.0f),
                1.0e-6f, "zero coverage must remove an area light");
        assertEquals(3.0f, OfflineLightMixtureMath.alphaCoverageWeight(2.0f, 3.0f, 0.5f),
                1.0e-6f, "half coverage must halve area-light weight");
        assertEquals(6.0f, OfflineLightMixtureMath.alphaCoverageWeight(2.0f, 3.0f, 1.0f),
                1.0e-6f, "full coverage must retain area-light weight");

        assertEquals(0.0f, OfflineLightMixtureMath.selectionPdf(Float.NaN, 4.0f, false, 0.0f),
                0.0f, "non-finite selection inputs must return zero");
        assertEquals(0.0f, OfflineLightMixtureMath.areaSolidAnglePdf(0.25f, -1.0f, 1.0f, 1.0f),
                0.0f, "invalid area conversion inputs must return zero");
        assertEquals(0.0f, OfflineLightMixtureMath.alphaCoverageWeight(1.0f, Float.POSITIVE_INFINITY, 1.0f),
                0.0f, "non-finite alpha-weight inputs must return zero");
    }

    private static void localLightIndexBuildsSortedNeighborhoodDirectories() {
        OfflineLocalLightIndex.Source[] sources = {
                new OfflineLocalLightIndex.Source(2, 0, 0, 3, 4.0f),
                new OfflineLocalLightIndex.Source(0, 2, -2, 2, 1.0f),
                new OfflineLocalLightIndex.Source(3, 0, 0, -3, 8.0f),
                new OfflineLocalLightIndex.Source(1, 0, 0, 0, 2.0f)
        };
        OfflineLocalLightIndex.Receiver[] receivers = {
                new OfflineLocalLightIndex.Receiver(3, 0, 0, 0),
                new OfflineLocalLightIndex.Receiver(1, 20, 20, 20)
        };

        OfflineLocalLightIndex.Build built = OfflineLocalLightIndex.build(5, receivers, sources);
        assertEquals(5, built.directories().length,
                "directory count must equal the section-table slot capacity");
        assertEquals(new OfflineLocalLightIndex.Directory(0, 0, 0.0f), built.directories()[0],
                "unused slots must contain the zero directory");
        assertEquals(new OfflineLocalLightIndex.Directory(0, 0, 0.0f), built.directories()[1],
                "receivers with no local lights must contain the zero directory");
        assertEquals(new OfflineLocalLightIndex.Directory(0, 2, 3.0f), built.directories()[3],
                "Chebyshev delta two is local while delta three is excluded");
        assertEquals(2, built.references().length,
                "only radius-two sources must enter the receiver directory");
        assertEquals(new OfflineLocalLightIndex.Reference(0, 1.0f), built.references()[0],
                "references must be sorted by ascending global index");
        assertEquals(new OfflineLocalLightIndex.Reference(1, 3.0f), built.references()[1],
                "cumulative weights must be exact and monotonic");

        OfflineLocalLightIndex.Build empty = OfflineLocalLightIndex.build(
                2, new OfflineLocalLightIndex.Receiver[0], new OfflineLocalLightIndex.Source[0]);
        assertEquals(2, empty.directories().length,
                "empty inputs still produce the requested zero-filled directory capacity");
        assertEquals(0, empty.references().length, "empty inputs produce no references");
    }

    private static void localLightIndexRejectsInvalidTopology() {
        OfflineLocalLightIndex.Source valid =
                new OfflineLocalLightIndex.Source(0, 0, 0, 0, 1.0f);
        assertThrowsIllegalArgument(() -> OfflineLocalLightIndex.build(1,
                        new OfflineLocalLightIndex.Receiver[]{
                                new OfflineLocalLightIndex.Receiver(-1, 0, 0, 0)
                        }, new OfflineLocalLightIndex.Source[]{valid}),
                "negative receiver slots must be rejected");
        assertThrowsIllegalArgument(() -> OfflineLocalLightIndex.build(1,
                        new OfflineLocalLightIndex.Receiver[]{
                                new OfflineLocalLightIndex.Receiver(1, 0, 0, 0)
                        }, new OfflineLocalLightIndex.Source[]{valid}),
                "receiver slots outside capacity must be rejected");
        assertThrowsIllegalArgument(() -> OfflineLocalLightIndex.build(2,
                        new OfflineLocalLightIndex.Receiver[]{
                                new OfflineLocalLightIndex.Receiver(1, 0, 0, 0),
                                new OfflineLocalLightIndex.Receiver(1, 1, 1, 1)
                        }, new OfflineLocalLightIndex.Source[]{valid}),
                "duplicate receiver slots must be rejected");
        assertThrowsIllegalArgument(() -> OfflineLocalLightIndex.build(1,
                        new OfflineLocalLightIndex.Receiver[0],
                        new OfflineLocalLightIndex.Source[]{
                                new OfflineLocalLightIndex.Source(-1, 0, 0, 0, 1.0f)
                        }),
                "negative global light indices must be rejected");
        assertThrowsIllegalArgument(() -> OfflineLocalLightIndex.build(1,
                        new OfflineLocalLightIndex.Receiver[0],
                        new OfflineLocalLightIndex.Source[]{
                                new OfflineLocalLightIndex.Source(1, 0, 0, 0, 1.0f)
                        }),
                "global light indices outside the source array must be rejected");
        assertThrowsIllegalArgument(() -> OfflineLocalLightIndex.build(1,
                        new OfflineLocalLightIndex.Receiver[0],
                        new OfflineLocalLightIndex.Source[]{
                                new OfflineLocalLightIndex.Source(0, 0, 0, 0, 0.0f)
                        }),
                "non-positive source weights must be rejected");
        assertThrowsIllegalArgument(() -> OfflineLocalLightIndex.build(1,
                        new OfflineLocalLightIndex.Receiver[0],
                        new OfflineLocalLightIndex.Source[]{
                                new OfflineLocalLightIndex.Source(0, 0, 0, 0, Float.NaN)
                        }),
                "non-finite source weights must be rejected");
    }

    private static void localLightMixtureNormalizesAndSharesSelectionPdf() {
        float[] weights = {1.0f, 2.0f, 3.0f, 4.0f};
        boolean[] local = {true, true, false, false};
        float globalTotal = 10.0f;
        float localTotal = 3.0f;
        float total = 0.0f;
        for (int i = 0; i < weights.length; i++) {
            float selectionPdf = OfflineLightMixtureMath.selectionPdf(
                    weights[i], globalTotal, local[i], localTotal);
            total += selectionPdf;
            if (!local[i]) {
                assertTrue(selectionPdf > 0.0f,
                        "every non-local light must retain positive global probability");
            }
            float neeSelectionPdf = OfflineLightMixtureMath.areaSolidAnglePdf(
                    selectionPdf, 7.0f, 0.5f, 2.0f) * (0.5f * 2.0f) / 7.0f;
            float bsdfHitSelectionPdf = OfflineLightMixtureMath.selectionPdf(
                    weights[i], globalTotal, local[i], localTotal);
            assertEquals(bsdfHitSelectionPdf, neeSelectionPdf, 1.0e-6f,
                    "NEE and BSDF-hit helpers must consume the same selection PDF");
        }
        assertEquals(1.0f, total, 1.0e-6f,
                "local/global mixture must normalize over local and non-local lights");
    }

    private static void particleWithoutStaticNeeSkipsReciprocalMis() {
        float selectionPdf = OfflineLightMixtureMath.selectionPdf(
                2.0f, 10.0f, false, 0.0f);
        float bsdfPdf = 0.1f;
        float neeWeight = OfflineStaticLightMath.powerHeuristic(selectionPdf, bsdfPdf);
        float pairedBsdfHitWeight = OfflineStaticLightMath.powerHeuristic(bsdfPdf, selectionPdf);
        assertEquals(1.0f, neeWeight + pairedBsdfHitWeight, 1.0e-6f,
                "matching static-light NEE and BSDF-hit reciprocal MIS must form a paired partition");

        float particleBsdfHitWeight = 1.0f;
        assertEquals(1.0f, particleBsdfHitWeight, 0.0f,
                "a particle path without matching static-light NEE must retain full emitter weight");
    }

    private static void offlineSampleSequenceIsDeterministicAndPixelRotated() {
        OfflineSampleSequence.Sample first = OfflineSampleSequence.sample2D(0x12345678, 37L);
        OfflineSampleSequence.Sample repeated = OfflineSampleSequence.sample2D(0x12345678, 37L);
        OfflineSampleSequence.Sample adjacent = OfflineSampleSequence.sample2D(0x12345678, 38L);
        OfflineSampleSequence.Sample otherPixel = OfflineSampleSequence.sample2D(0x12345679, 37L);

        assertEquals(first, repeated,
                "the same pixel hash and global sample index must reproduce the same primary sample");
        assertTrue(Double.isFinite(first.x()) && first.x() >= 0.0 && first.x() < 1.0,
                "R2 x coordinate must be finite and inside [0,1)");
        assertTrue(Double.isFinite(first.y()) && first.y() >= 0.0 && first.y() < 1.0,
                "R2 y coordinate must be finite and inside [0,1)");
        assertFalse(first.equals(adjacent),
                "adjacent offline SPP values must use distinct primary-ray positions");
        assertFalse(first.equals(otherPixel),
                "different pixel hashes must receive different Cranley-Patterson rotations");
    }

    private static void offlineSampleSequenceHasNoShortPhaseRepeat() {
        java.util.HashSet<OfflineSampleSequence.Sample> positions = new java.util.HashSet<>();
        OfflineSampleSequence.Sample[] firstPhase = new OfflineSampleSequence.Sample[32];
        for (int sample = 0; sample < 6000; sample++) {
            OfflineSampleSequence.Sample position =
                    OfflineSampleSequence.sample2D(0x6d2b79f5, sample);
            assertTrue(positions.add(position),
                    "the first 6000 offline primary samples must not repeat a two-dimensional position");
            if (sample < firstPhase.length) {
                firstPhase[sample] = position;
            } else {
                assertFalse(position.equals(firstPhase[sample & 31]),
                        "offline primary sampling must not repeat on the old 32-frame phase");
            }
        }
    }

    private static void offlineSampleSequenceRetainsHighIndexPrecision() {
        long[][] boundaries = {
                {16_777_214L, 16_777_215L, 16_777_216L, 16_777_217L},
                {4_294_967_294L, 4_294_967_295L, 4_294_967_296L, 4_294_967_297L},
                {Long.MAX_VALUE - 3L, Long.MAX_VALUE - 2L,
                        Long.MAX_VALUE - 1L, Long.MAX_VALUE}
        };
        for (long[] boundary : boundaries) {
            OfflineSampleSequence.Sample previous = null;
            for (long index : boundary) {
                OfflineSampleSequence.Sample sample =
                        OfflineSampleSequence.sample2D(0x12345678, index);
                assertEquals(sample, OfflineSampleSequence.sample2D(0x12345678, index),
                        "high-index offline samples must remain deterministic");
                assertTrue(Double.isFinite(sample.x()) && sample.x() >= 0.0 && sample.x() < 1.0,
                        "high-index R2 x coordinate must stay finite and inside [0,1)");
                assertTrue(Double.isFinite(sample.y()) && sample.y() >= 0.0 && sample.y() < 1.0,
                        "high-index R2 y coordinate must stay finite and inside [0,1)");
                assertHigh24BitLattice(sample.x(),
                        "CPU R2 x must match the shader's exact high-24-bit fixed-point conversion");
                assertHigh24BitLattice(sample.y(),
                        "CPU R2 y must match the shader's exact high-24-bit fixed-point conversion");
                if (previous != null) {
                    assertFalse(previous.equals(sample),
                            "adjacent high global sample indices must not collapse to one primary position");
                }
                previous = sample;
            }
        }
    }

    private static void offlinePhaseToUnitCoversFullHigh24Range() {
        int[] bins = {0x000000, 0x7fffff, 0x800000, 0xffffff};
        double[] expected = {
                0.0,
                0.4999999403953552,
                0.5,
                0.9999999403953552
        };
        for (int i = 0; i < bins.length; i++) {
            long phase = (long) bins[i] << 40;
            double actual = OfflineSampleSequence.phaseToUnit(phase);
            if (Double.doubleToLongBits(expected[i]) != Double.doubleToLongBits(actual)) {
                throw new AssertionError("phase high-24-bit conversion must cover the full [0,1) lattice"
                        + ": bin=0x" + Integer.toHexString(bins[i])
                        + ", expected=" + expected[i] + ", actual=" + actual);
            }
        }
    }

    private static void assertHigh24BitLattice(double coordinate, String message) {
        double bin = coordinate * 16_777_216.0;
        if (!Double.isFinite(bin) || Math.abs(bin - Math.rint(bin)) > 1.0e-9) {
            throw new AssertionError(message + ": coordinate=" + coordinate);
        }
    }

    private static OfflineAccumulationState accumulatingState() {
        OfflineAccumulationState state = new OfflineAccumulationState();
        state.observe(true, true, 0L, 10L, true, false, 4);
        state.observe(true, false, 2_000_000_000L, 10L, true, false, 4);
        state.observe(true, false, 2_000_000_001L, 10L, true, true, 4);
        return state;
    }

    private static void assertTrue(boolean value, String message) {
        if (!value) {
            throw new AssertionError(message);
        }
    }

    private static void assertFalse(boolean value, String message) {
        assertTrue(!value, message);
    }

    private static void assertEquals(long expected, long actual, String message) {
        if (expected != actual) {
            throw new AssertionError(message + ": expected=" + expected + ", actual=" + actual);
        }
    }

    private static void assertEquals(int expected, int actual, String message) {
        if (expected != actual) {
            throw new AssertionError(message + ": expected=" + expected + ", actual=" + actual);
        }
    }

    private static void assertEquals(float expected, float actual, float tolerance, String message) {
        if (!Float.isFinite(actual) || Math.abs(expected - actual) > tolerance) {
            throw new AssertionError(message + ": expected=" + expected + ", actual=" + actual);
        }
    }

    private static void assertEquals(Object expected, Object actual, String message) {
        if (!expected.equals(actual)) {
            throw new AssertionError(message + ": expected=" + expected + ", actual=" + actual);
        }
    }

    private static void assertNotEquals(long unexpected, long actual, String message) {
        if (unexpected == actual) {
            throw new AssertionError(message + ": both were " + actual);
        }
    }

    private static void assertThrowsIllegalArgument(Runnable action, String message) {
        try {
            action.run();
        } catch (IllegalArgumentException expected) {
            return;
        }
        throw new AssertionError(message + ": expected IllegalArgumentException");
    }
}
