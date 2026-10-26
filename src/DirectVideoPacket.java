import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** scrcpy-compatible 12-byte big-endian header followed by one encoded packet. */
final class DirectVideoPacket {
    private static final int HEADER_SIZE = 12;
    private static final int MAX_PAYLOAD_SIZE = 8 * 1024 * 1024;

    private DirectVideoPacket() {}

    static void write(OutputStream output, ByteBuffer encoded, long flags, int size) throws IOException {
        if (size <= 0 || size > MAX_PAYLOAD_SIZE || encoded.remaining() < size)
            throw new IllegalArgumentException("Invalid encoded packet size");
        byte[] packet = new byte[HEADER_SIZE + size];
        ByteBuffer.wrap(packet).order(ByteOrder.BIG_ENDIAN).putLong(flags).putInt(size);
        encoded.get(packet, HEADER_SIZE, size);
        // LocalSocket has no Java buffering here. Keep the header and payload in
        // one write without adding a frame queue or waiting for a later flush.
        output.write(packet, 0, packet.length);
    }
}
