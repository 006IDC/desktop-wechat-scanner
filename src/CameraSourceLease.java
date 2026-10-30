/** Access only under cameraLock. Fences decoding separately from owner identity. */
final class CameraSourceLease {
    private long revision, sequence, token, epoch = -1, capture = -1;
    long revision() { return revision; }
    void invalidate() { revision++; }
    boolean accepts(long expected) { return revision == expected; }
    long begin(long epoch, long capture) {
        invalidate(); this.epoch = epoch; this.capture = capture; token = ++sequence;
        return token;
    }
    boolean owns(long token, long epoch, long capture) {
        return token > 0 && this.token == token && this.epoch == epoch && this.capture == capture;
    }
    boolean current(long token, long epoch, long capture, long currentEpoch, long currentCapture) {
        return epoch == currentEpoch && capture == currentCapture && owns(token, epoch, capture);
    }
    boolean end(long token, long epoch, long capture, long currentEpoch, long currentCapture) {
        if (!current(token, epoch, capture, currentEpoch, currentCapture)) return false;
        invalidate(); this.token = 0; return true;
    }
}
