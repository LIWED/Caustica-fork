import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import dev.comfyfluffy.caustica.rt.offline.OfflinePathProbeCodec;
import dev.comfyfluffy.caustica.rt.offline.OfflinePathProbeOwnership;

public final class OfflinePathProbeBehaviorTest {
    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        ByteBuffer b = ByteBuffer.allocate(16 + 5344).order(ByteOrder.LITTLE_ENDIAN);
        b.putInt(0, 1).putInt(4, 32);
        int r = 16;
        b.putInt(r + 48, 1).putInt(r + 56, 1);
        require(OfflinePathProbeCodec.decode(b, "\"frame\":7", 32).isEmpty(), "incomplete replay must be rejected");
        b.putInt(r + 60, 1).putInt(r + 8, -1).putInt(r + 12, 1);
        b.putFloat(r + 32, Float.POSITIVE_INFINITY);
        b.putFloat(r + 64, Float.NaN);
        var decoded = OfflinePathProbeCodec.decode(b, "\"frame\":7", 32);
        require(decoded.size() == 1, "complete bounded record decoded");
        require(decoded.getFirst().contains("\"sampleIndex\":\"8589934591\""), "unsigned sample halves preserved");
        require(decoded.getFirst().contains("\"+Infinity\"") && decoded.getFirst().contains("\"NaN\""), "nonfinite floats are JSON strings");
        require(decoded.getFirst().contains("\"frame\":7") && decoded.getFirst().contains("\"steps\":["), "metadata and step data included");
        b.putInt(0, -1);
        require(OfflinePathProbeCodec.decode(b, "", 32).size() == 1, "counter cannot read past mapped capacity");
        require(OfflinePathProbeCodec.decode(b, "", 0).isEmpty(), "output budget respected");
        b.limit(16 + 5344 - 1);
        require(OfflinePathProbeCodec.decode(b, "", 32).isEmpty(), "truncated record rejected");
        b.limit(b.capacity()).putInt(r + 48, 34);
        require(OfflinePathProbeCodec.decode(b, "", 32).isEmpty(), "invalid step count rejected");
        b.putInt(r + 48, 1).putInt(r + 56, 2);
        require(OfflinePathProbeCodec.decode(b, "", 32).isEmpty(), "unknown ABI rejected");
        require(OfflinePathProbeCodec.decode(ByteBuffer.allocate(8), "", 32).isEmpty(), "truncated header rejected");

        OfflinePathProbeOwnership owner = new OfflinePathProbeOwnership();
        require(owner.available(), "new slot available");
        owner.acquire();
        require(!owner.available() && !owner.readable(Long.MAX_VALUE), "recording slot cannot be read");
        owner.submitted(42);
        require(!owner.readable(42), "completion alone cannot replace a signal attachment");
        owner.signalAttached(41);
        require(!owner.readable(100), "unrelated signal cannot release slot");
        owner.signalAttached(42);
        require(!owner.readable(41), "slot remains GPU-owned before exact completion");
        require(owner.readable(42), "actual completion releases slot for host read");
        owner.release(42);
        require(owner.available(), "completed slot reusable");
        owner.acquire();
        owner.submitted(44);
        owner.signalAttached(44);
        try { owner.release(43); throw new AssertionError("early reuse accepted"); }
        catch (IllegalStateException expected) { }
        System.out.println("Offline path probe decoder/ownership tests passed");
    }
}
