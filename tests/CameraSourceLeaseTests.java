public final class CameraSourceLeaseTests {
    static void require(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        CameraSourceLease p = new CameraSourceLease();
        long decoding = p.revision(), first = p.begin(7, 8);
        require(!p.accepts(decoding)); // A decode begun before enable cannot replace calibration.
        decoding = p.revision(); p.invalidate();
        require(!p.accepts(decoding)); // Clear, calibration or owner invalidation fences a pending decode.
        require(!p.end(first, 7, 8, 8, 8)); // Old epoch cannot clear a replacement.
        require(!p.end(first, 7, 8, 7, 9)); // Changed owner retains its tombstone.
        require(p.end(first, 7, 8, 7, 8));
        long second = p.begin(7, 8); // Even re-opening the same epoch/owner has a distinct token.
        decoding = p.revision();
        require(!p.current(first, 7, 8, 7, 8)); // Old calibration/source packet cannot target B.
        require(p.current(second, 7, 8, 7, 8));
        require(!p.current(second, 7, 8, 8, 8) && !p.current(second, 7, 8, 7, 9));
        require(!p.end(first, 7, 8, 7, 8) && p.accepts(decoding));
        require(!p.end(second, 6, 8, 7, 8) && !p.end(second, 7, 9, 7, 8));
        require(p.end(second, 7, 8, 7, 8) && !p.accepts(decoding));
        require(!p.end(second, 7, 8, 7, 8));
        System.out.println("PASS pending decode fences and retired preview cannot close a replacement lease");
    }
}
