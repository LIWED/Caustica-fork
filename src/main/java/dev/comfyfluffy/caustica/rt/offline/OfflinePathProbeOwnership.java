package dev.comfyfluffy.caustica.rt.offline;
public final class OfflinePathProbeOwnership {
    private boolean acquired;
    private long graphicsValue;
    private boolean signalAttached;

    public boolean available() { return !acquired; }

    public void acquire() {
        if (acquired) throw new IllegalStateException("Probe slot is still owned by a frame");
        acquired = true;
        graphicsValue = 0;
        signalAttached = false;
    }

    public void submitted(long value) {
        if (!acquired || graphicsValue != 0 || value <= 0) throw new IllegalStateException("Invalid probe submission");
        graphicsValue = value;
    }

    public void signalAttached(long value) {
        if (acquired && value != 0 && graphicsValue == value) signalAttached = true;
    }

    public boolean readable(long completed) {
        return acquired && signalAttached && graphicsValue > 0 && completed >= graphicsValue;
    }

    public void release(long completed) {
        if (!readable(completed)) throw new IllegalStateException("Probe slot GPU work is incomplete");
        acquired = false;
    }
}
