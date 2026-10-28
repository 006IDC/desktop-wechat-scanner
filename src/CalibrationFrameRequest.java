import java.io.IOException;
import java.nio.ByteBuffer;

/** Fixed-size synthetic input only; never an arbitrary image or Android permission. */
final class CalibrationFrameRequest {
    final long epoch;
    final boolean blue;
    private CalibrationFrameRequest(long epoch, boolean blue) {
        this.epoch = epoch;
        this.blue = blue;
    }
    static CalibrationFrameRequest parse(byte[] body) throws IOException {
        if (body == null || body.length != Long.BYTES + 1)
            throw new IOException("Calibration needs an epoch and one color tag");
        long epoch = ByteBuffer.wrap(body, 0, Long.BYTES).getLong();
        int color = body[Long.BYTES] & 255;
        if (epoch < 0 || color > 1) throw new IOException("Invalid calibration epoch or color");
        return new CalibrationFrameRequest(epoch, color == 1);
    }
}
