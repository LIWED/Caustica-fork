import java.nio.file.*;
import java.util.regex.*;
import dev.comfyfluffy.caustica.rt.offline.OfflineRenderSignature;
import dev.comfyfluffy.caustica.rt.offline.OfflineAccumulationState;

public final class OfflineDiagnosticsBehaviorTest {
    private static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    private static String block(String source, String anchor) {
        int marker = source.indexOf(anchor);
        require(marker >= 0, "missing block: " + anchor);
        int start = source.indexOf('{', marker), end = start + 1, depth = 1;
        while (end < source.length() && depth > 0) {
            char c = source.charAt(end++);
            if (c == '{') depth++;
            if (c == '}') depth--;
        }
        require(depth == 0, "unclosed block: " + anchor);
        return source.substring(start + 1, end - 1);
    }
    private static void flagWiring(String shader) {
        String path = shader.substring(shader.indexOf("float3 tracePath("), shader.indexOf("[shader(\"raygeneration\")]"));
        String glass = block(path, "if (material == MATERIAL_GLASS)");
        String water = block(path, "if (material == MATERIAL_WATER)");
        for (String[] branch : new String[][]{{glass, "2", "1"}, {water, "8", "4"}}) {
            String reflection = block(branch[0], "if (rndf(seed) < F)");
            String choice = branch[0].substring(branch[0].indexOf("if (rndf(seed) < F)"));
            String transmission = block(choice, "else");
            require(reflection.contains("pathFlags |= " + branch[1] + "u;"), "reflection flag belongs to actual sampled reflection branch");
            require(transmission.contains("pathFlags |= " + branch[2] + "u;"), "transmission flag belongs to actual sampled transmission branch");
            require(reflection.contains("rd = reflect(rd, n);"), "reflection flag must accompany reflection direction");
        }
        String glassReflect = block(glass, "if (rndf(seed) < F)");
        String glassTransmit = block(glass.substring(glass.indexOf("if (rndf(seed) < F)")), "else");
        require(glassReflect.contains("previousCelestialDelta = true;") && glassReflect.contains("previousCelestialBsdfPdf = 0.0;"), "glass reflection resets celestial MIS");
        require(!glassTransmit.contains("previousCelestial"), "straight glass transmission preserves predecessor celestial MIS");
        require(!glass.substring(0, glass.indexOf("if (rndf(seed) < F)")).contains("previousCelestial"), "glass must not reset celestial state before the branch");
        String beforeWaterChoice = water.substring(0, water.indexOf("if (rndf(seed) < F)"));
        require(beforeWaterChoice.contains("previousCelestialDelta = true;") && beforeWaterChoice.contains("previousCelestialBsdfPdf = 0.0;"), "both water directions reset celestial MIS");
        require(path.contains("uint pathFlags = 0u;"), "each new path starts with no interface flags");
        String skyMiss = block(path, "if (payload.hitT < 0.0)");
        require(skyMiss.contains("if (waterCelestialGuidedLeg) pathFlags |= 16u;"), "protected-leg flag must describe the final celestial leg");
        require(!Pattern.compile("pathFlags\\s*=(?!=)").matcher(path.substring(path.indexOf("uint pathFlags = 0u;") + "uint pathFlags = 0u;".length())).find(), "interface history must not be overwritten");
    }
    private static void wiring(String shader) {
        String path = shader.substring(shader.indexOf("float3 tracePath("), shader.indexOf("[shader(\"raygeneration\")]"));
        Matcher sums = Pattern.compile("L\\s*\\+=\\s*([^;]+);", Pattern.DOTALL).matcher(path);
        int count = 0;
        while (sums.find()) {
            String expression = sums.group(1);
            require(expression.startsWith("offlineContribution("), "unfiltered contribution: " + expression);
            int category = expression.contains("throughput * sky") ? 13
                    : expression.contains("throughput * celestialSky") ? 14
                    : expression.contains("EMISSIVE_STRENGTH") ? 9
                    : expression.contains("pc.lightRadiance.xyz") ? 10 : 8;
            require(expression.matches("(?s).*, " + category + "u, bounce, pathFlags\\)$"), "wrong contribution category/depth: " + expression);
            count++;
        }
        require(count == 10, "all ten tracePath contribution sites must be tested");
        require(!path.contains("pc.debugView"), "path control and random sequence must not depend on diagnostic view");
        require(shader.contains("#ifdef CAUSTICA_OFFLINE_FP32\n    if (!offlineContributionVisible(pc.debugView, category, bounce, pathFlags, int(pc.maxBounces))) return float3(0.0);\n#endif\n    return value;"), "filter must affect only offline variant and return original radiance otherwise");
        require(shader.split("if \\(pc.debugView >= 1u && pc.debugView <= 7u\\)", -1).length == 3, "both entries restrict guide overrides to 1..7");
        Matcher sampleLoops = Pattern.compile("(?s)for \\(uint s.*?frameRadiance \\+= tracePath\\(").matcher(shader);
        int loops = 0;
        while (sampleLoops.find()) loops++;
        require(loops == 2, "both entries must accumulate filtered tracePath output per SPP");
    }
    @FunctionalInterface
    interface Policy { boolean visible(int view, int category, int bounce, int flags, int maxBounces); }
    private static void checkPolicy(Policy policy) {
        for (int view = 0; view <= 21; view++)
            for (int category : new int[]{8, 9, 10, 13, 14})
                for (int max : new int[]{0, 1, 8})
                    for (int bounce = 0; bounce <= max; bounce++)
                        for (int flags = 0; flags < 32; flags++) {
                            boolean expected;
                            if (view < 8) expected = true;
                            else if (view == 11) expected = category == 13 || category == 14;
                            else if (view == 12) expected = bounce > 0;
                            else if (view >= 15 && view <= 18) expected = category == 14 && (flags & (1 << (view - 15))) != 0;
                            else if (view == 19) expected = category == 10 && bounce == max;
                            else if (view == 20 || view == 21) expected = category == 14 && (flags & 12) != 0 && (((flags & 16) != 0) == (view == 20));
                            else expected = category == view;
                            require(policy.visible(view, category, bounce, flags, max) == expected,
                                    "view/category/bounce/flags/max policy " + view + "/" + category + "/" + bounce + "/" + flags + "/" + max);
                        }
    }
    public static void main(String[] args) throws Exception {
        checkPolicy(ExtractedOfflineDiagnostic::offlineContributionVisible);
        try { checkPolicy(ExtractedOfflineDiagnostic::missingFlags); throw new IllegalStateException("missing path flags mutation survived"); }
        catch (AssertionError expected) { System.out.println("PASS: missing path flags mutation rejected"); }
        Path root = Path.of(args[0]);
        String shader = Files.readString(root.resolve("shaders/world/world.rgen.slang")).replace("\r\n", "\n");
        wiring(shader);
        flagWiring(shader);
        for (int bit : new int[]{1, 2, 4, 8, 16}) {
            String mutant = shader.replace("pathFlags |= " + bit + "u;", "pathFlags |= 0u;");
            require(!mutant.equals(shader), "real path flag update must exist");
            try { flagWiring(mutant); throw new IllegalStateException("missing interface flag mutation survived"); }
            catch (AssertionError expected) { /* Required rejection of each actual branch mutation. */ }
        }
        System.out.println("PASS: four interface and final protected-leg flag mutations rejected");
        Matcher sites = Pattern.compile("L \\+= offlineContribution\\(([^;]+), (8|9|10|13|14)u, bounce, pathFlags\\);", Pattern.DOTALL).matcher(shader);
        int mutants = 0;
        while (sites.find()) {
            String bypass = shader.substring(0, sites.start()) + "L += " + sites.group(1) + ";" + shader.substring(sites.end());
            try { wiring(bypass); throw new IllegalStateException("unfiltered output mutation survived"); }
            catch (AssertionError expected) { mutants++; }
        }
        require(mutants == 10, "all real contribution sites require negative mutation coverage");
        System.out.println("PASS: all ten unfiltered output mutations rejected");
        String composite = Files.readString(root.resolve("src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java"));
        require(composite.contains("boolean radianceView = debugView == 0 || debugView >= 8;") && composite.contains("RtDlssRr.enabled() && radianceView") && composite.contains("offlineAccumulating && radianceView"), "diagnostic views preserve RR/jitter during normal rendering");
        require(composite.contains("debugView(),"), "debug view must enter signature");
        for (int from = 0; from <= 21; from++) for (int to = 0; to <= 21; to++) {
            long oldSignature = OfflineRenderSignature.create(1920, 1080, 1, 1, from, 8, 32, 0, 0, 0);
            long newSignature = OfflineRenderSignature.create(1920, 1080, 1, 1, to, 8, 32, 0, 0, 0);
            OfflineAccumulationState state = new OfflineAccumulationState();
            state.observe(true, false, 0, oldSignature, true, true, 4);
            require(state.observe(true, false, 2_000_000_000L, oldSignature, true, true, 4).accumulate(), "test must start accumulating");
            var switched = state.observe(true, false, 2_000_000_001L, newSignature, true, true, 4);
            require(switched.resetHistory() == (from != to), "switching views resets history; unchanged view preserves it");
            if (from != to) require(!switched.accumulate() && switched.previousSamples() == 0, "switch clears samples and restarts stability delay");
        }
        String options = Files.readString(root.resolve("src/main/java/dev/comfyfluffy/caustica/client/RtVideoOptions.java"));
        require(options.contains("List.of(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21)") && options.contains("Math.clamp(setting.value(), 0, 21)"), "UI enum and clamp");
        for (String locale : new String[]{"en_us", "zh_cn"}) {
            String lang = Files.readString(root.resolve("src/main/resources/assets/caustica/lang/" + locale + ".json"));
            for (int view = 8; view <= 21; view++) require(lang.contains("\"caustica.options.rt.debugView." + view + "\""), "missing translation");
        }
        System.out.println("PASS: offline contribution policy, ten output sites, entry routing, signature and UI");
    }
}
