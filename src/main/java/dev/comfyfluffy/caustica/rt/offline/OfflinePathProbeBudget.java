package dev.comfyfluffy.caustica.rt.offline;

/** Render-thread capture quota, independent of GPU buffer ownership. */
public final class OfflinePathProbeBudget {
    private final int perAccumulation;
    private final int perProcess;
    private boolean accumulating;
    private long previousSamples;
    private long generation;
    private int accepted;
    private int totalAccepted;

    public OfflinePathProbeBudget(int perAccumulation, int perProcess) {
        if (perAccumulation <= 0 || perProcess <= 0) throw new IllegalArgumentException("Positive quotas required");
        this.perAccumulation = perAccumulation;
        this.perProcess = perProcess;
    }

    public void observe(boolean active, long samples) {
        if (active && (!accumulating || samples < previousSamples)) {
            generation++;
            accepted = 0;
        }
        accumulating = active;
        previousSamples = samples;
    }

    public long generation() { return generation; }
    public int totalAccepted() { return totalAccepted; }
    public int remaining(long capturedGeneration) {
        if (capturedGeneration != generation) return 0;
        return Math.min(perAccumulation - accepted, perProcess - totalAccepted);
    }
    public void accept(long capturedGeneration, int records) {
        int count = Math.min(Math.max(records, 0), remaining(capturedGeneration));
        accepted += count;
        totalAccepted += count;
    }
}
