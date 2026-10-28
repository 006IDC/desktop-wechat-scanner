import java.io.IOException;
import java.nio.ByteBuffer;

public final class CalibrationFrameRequestTests {
    private static byte[] body(long epoch, int tag) {
        return ByteBuffer.allocate(9).putLong(epoch).put((byte) tag).array();
    }
    private static void require(boolean valid, String message) {
        if (!valid) throw new AssertionError(message);
    }
    private static void rejects(byte[] bytes) throws Exception {
        try { CalibrationFrameRequest.parse(bytes); }
        catch (IOException expected) { return; }
        throw new AssertionError("Malformed calibration request accepted");
    }
    public static void main(String[] args) throws Exception {
        CalibrationFrameRequest black=CalibrationFrameRequest.parse(body(0,0));
        require(black.epoch==0 && !black.blue,"Black calibration failed");
        CalibrationFrameRequest blue=CalibrationFrameRequest.parse(body(Long.MAX_VALUE,1));
        require(blue.epoch==Long.MAX_VALUE && blue.blue,"Maximum epoch or blue tag failed");
        long pattern=0x0102030405060708L;
        CalibrationFrameRequest endian=CalibrationFrameRequest.parse(new byte[]{1,2,3,4,5,6,7,8,1});
        require(endian.epoch==pattern && endian.blue,"Wire epoch is not big endian");
        rejects(null);rejects(new byte[0]);rejects(new byte[8]);rejects(new byte[10]);
        rejects(body(-1,0));rejects(body(Long.MIN_VALUE,1));
        rejects(body(0,2));rejects(body(0,255));
        System.out.println("PASS fixed nine-byte calibration request, endian, epoch and color bounds");
    }
}
