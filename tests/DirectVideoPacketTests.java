import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.Arrays;

/** Pure JVM framing tests; no Android class or device is loaded. */
public final class DirectVideoPacketTests {
    private static final class CountingOutput extends ByteArrayOutputStream {
        int writes;
        @Override public synchronized void write(byte[] bytes, int offset, int length) {
            writes++;
            super.write(bytes, offset, length);
        }
        @Override public synchronized void write(int value) {
            throw new AssertionError("Packet was split into byte writes");
        }
    }
    private static final class CountingSink extends java.io.OutputStream {
        int writes, bytes;
        @Override public void write(int value) { throw new AssertionError("Packet was split into byte writes"); }
        @Override public void write(byte[] packet, int offset, int length) {
            writes++;
            bytes += length;
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private static void rejects(Runnable action, String message) {
        try { action.run(); } catch (IllegalArgumentException expected) { return; }
        throw new AssertionError(message);
    }

    public static void main(String[] unused) throws Exception {
        CountingOutput config = new CountingOutput();
        DirectVideoPacket.write(config, ByteBuffer.wrap(new byte[]{0, 0, 0, 1, 0x67}), 1L << 62, 5);
        require(config.writes == 1, "Config frame required more than one output write");
        require(Arrays.equals(config.toByteArray(), new byte[]{
                0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 1, 0x67
        }), "Config frame changed scrcpy header or payload order");

        CountingOutput keyFrame = new CountingOutput();
        ByteBuffer source = ByteBuffer.wrap(new byte[]{99, 0, 0, 1, 0x65, 88});
        source.position(1); source.limit(5);
        DirectVideoPacket.write(keyFrame, source, (1L << 61) | 5, 4);
        require(keyFrame.writes == 1 && source.position() == 5,
                "Key frame did not consume exactly one payload in one write");
        require(Arrays.equals(keyFrame.toByteArray(), new byte[]{
                0x20, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 4, 0, 0, 1, 0x65
        }), "Key frame flags, PTS or payload changed");

        CountingOutput ordinary = new CountingOutput();
        DirectVideoPacket.write(ordinary, ByteBuffer.wrap(new byte[]{7, 8}), 10, 2);
        require(ordinary.writes == 1 && Arrays.equals(ordinary.toByteArray(), new byte[]{
                0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 0, 2, 7, 8
        }), "Ordinary frame format changed");

        rejects(() -> {
            try { DirectVideoPacket.write(new CountingOutput(), ByteBuffer.allocate(0), 0, 0); }
            catch (java.io.IOException failure) { throw new AssertionError(failure); }
        }, "Empty packet accepted");
        rejects(() -> {
            try { DirectVideoPacket.write(new CountingOutput(), ByteBuffer.allocate(1), 0, 2); }
            catch (java.io.IOException failure) { throw new AssertionError(failure); }
        }, "Truncated payload accepted");
        rejects(() -> {
            try { DirectVideoPacket.write(new CountingOutput(), ByteBuffer.allocate(0), 0, 8 * 1024 * 1024 + 1); }
            catch (java.io.IOException failure) { throw new AssertionError(failure); }
        }, "Oversized packet accepted");
        CountingSink maximum = new CountingSink();
        DirectVideoPacket.write(maximum, ByteBuffer.allocate(8 * 1024 * 1024), 0, 8 * 1024 * 1024);
        require(maximum.writes == 1 && maximum.bytes == 12 + 8 * 1024 * 1024,
                "Largest permitted packet was truncated or split");
        System.out.println("PASS direct video packet framing, single write and payload bounds");
    }
}
