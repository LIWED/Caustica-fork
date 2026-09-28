import dev.comfyfluffy.caustica.rt.offline.OfflinePathProbeBudget;

public final class OfflinePathProbeBudgetTest {
    private static void require(boolean value, String reason) {
        if (!value) throw new AssertionError(reason);
    }
    public static void main(String[] args) {
        var budget = new OfflinePathProbeBudget(256, 2048);
        budget.observe(false, 0);
        budget.observe(true, 0);
        long first = budget.generation();
        budget.observe(true, 500);
        require(budget.generation() == first, "stable accumulation shares quota");
        budget.accept(first, 256);
        require(budget.remaining(first) == 0, "per-accumulation cap");
        budget.observe(true, 0);
        long second = budget.generation();
        require(second != first && budget.remaining(second) == 256, "sample reset rearms capture");
        require(budget.remaining(first) == 0, "late GPU results cannot charge new accumulation");
        budget.accept(first, 100);
        require(budget.remaining(second) == 256, "stale results ignored");
        budget.accept(second, 200);
        budget.observe(false, 100);
        budget.observe(false, 0);
        budget.observe(true, 500);
        require(budget.remaining(budget.generation()) == 256, "movement/re-entry rearms even if first seen SPP is high");
        while (budget.remaining(budget.generation()) > 0) {
            budget.accept(budget.generation(), 256);
            budget.observe(false, 0);
            budget.observe(true, 500);
        }
        require(budget.totalAccepted() == 2048, "rearming cannot exceed process cap");
        budget.observe(true, 0);
        require(budget.remaining(budget.generation()) == 0, "process cap persists after reset");
        System.out.println("PASS capture rearming, stale-slot isolation and process cap");
    }
}
