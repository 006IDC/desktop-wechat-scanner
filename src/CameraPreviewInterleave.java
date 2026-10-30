/** Optional input policy; accessed only while the server holds cameraLock.
 * It owns no Android Views or resources. A key frame carries native UI; a
 * fresh source frame lets the original camera client perform its own analysis.
 */
final class CameraPreviewInterleave {
    enum Phase { UNCHANGED, KEY, SOURCE }
    static final long SOURCE_LIFETIME_NANOS = 500_000_000L;
    private boolean enabled;
    private long generation = -1, epoch = -1, phaseState, keyPosts, sourcePosts;
    private int keysRemaining;

    void enable(long generation, long epoch) { enable(generation, epoch, System.nanoTime()); }
    void enable(long generation, long epoch, long seed) {
        if (generation < 0 || epoch < 0) throw new IllegalArgumentException("Invalid preview lease");
        this.generation = generation; this.epoch = epoch;
        keyPosts = sourcePosts = 0; keysRemaining = 2;
        phaseState = seed == 0 ? 0x6a09e667f3bcc909L : seed; enabled = true;
    }
    static Integer calibrationColor(int phase) {
        switch (phase) {
            case 0: return 0xff000000;
            case 1: return 0xffffffff;
            case 2: return null;
            default: throw new IllegalArgumentException("Invalid calibration phase");
        }
    }
    void disable() { enabled = false; }
    boolean active(long generation, long epoch) {
        return enabled && this.generation == generation && this.epoch == epoch;
    }
    Phase next(long generation, long epoch, boolean hasSource, long acceptedAt, long now) {
        if (!active(generation, epoch)) return Phase.UNCHANGED;
        // An absent, future-dated or expired source must never be replayed.
        if (!hasSource || now < acceptedAt || now - acceptedAt >= SOURCE_LIFETIME_NANOS)
            return Phase.KEY;
        if (keysRemaining > 0) { keysRemaining--; return Phase.KEY; }
        // Camera clients may analyse every Nth frame. A fixed K/K/S cycle can
        // phase-lock with that decimator and never deliver a real source to it.
        // Vary the key run between one and two; never emit adjacent sources.
        phaseState ^= phaseState << 13; phaseState ^= phaseState >>> 7; phaseState ^= phaseState << 17;
        keysRemaining = 1 + (int) (phaseState & 1);
        return Phase.SOURCE;
    }
    void posted(Phase phase, long generation, long epoch) {
        if (!active(generation, epoch)) return;
        if (phase == Phase.KEY) keyPosts++;
        else if (phase == Phase.SOURCE) sourcePosts++;
    }
    long keyPosts() { return keyPosts; }
    long sourcePosts() { return sourcePosts; }
}
