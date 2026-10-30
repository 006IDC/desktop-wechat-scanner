public final class CameraPreviewInterleaveTests {
    static void require(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        require(CameraPreviewInterleave.calibrationColor(0) == 0xff000000);
        require(CameraPreviewInterleave.calibrationColor(1) == 0xffffffff);
        require(CameraPreviewInterleave.calibrationColor(2) == null); // Do not unbox null through a nested int ternary.
        CameraPreviewInterleave p = new CameraPreviewInterleave();
        require(p.next(5, 8, true, 1, 2) == CameraPreviewInterleave.Phase.UNCHANGED);
        p.enable(5, 8, 17);
        CameraPreviewInterleave.Phase[] phases = new CameraPreviewInterleave.Phase[600];
        int consecutiveKeys = 0;
        boolean previousSource = false;
        for (int i = 0; i < phases.length; i++) {
            CameraPreviewInterleave.Phase phase = p.next(5, 8, true, 1, 2);
            phases[i] = phase;
            if (phase == CameraPreviewInterleave.Phase.KEY) { consecutiveKeys++; require(consecutiveKeys <= 2); previousSource = false; }
            else { require(phase == CameraPreviewInterleave.Phase.SOURCE && !previousSource); consecutiveKeys = 0; previousSource = true; }
            p.posted(phase, 5, 8);
        }
        require(p.keyPosts() + p.sourcePosts() == phases.length && p.sourcePosts() > 150);
        for (int stride : new int[]{2,3,4,5,7,10}) {
            for (int offset = 0; offset < stride; offset++) {
                boolean sourceSeen = false, keySeen = false;
                for (int i = offset; i < phases.length; i += stride) {
                    sourceSeen |= phases[i] == CameraPreviewInterleave.Phase.SOURCE;
                    keySeen |= phases[i] == CameraPreviewInterleave.Phase.KEY;
                }
                require(sourceSeen && keySeen);
            }
        }
        for (int i = 0; i < 100; i++) {
            require(p.next(5, 8, true, 1, 500_000_001) == CameraPreviewInterleave.Phase.KEY);
            require(p.next(5, 8, false, 1, 2) == CameraPreviewInterleave.Phase.KEY);
            require(p.next(5, 8, true, 3, 2) == CameraPreviewInterleave.Phase.KEY);
        }
        // Old owner/epoch work cannot enter a replacement lease or its counters.
        require(p.next(6, 8, true, 1, 2) == CameraPreviewInterleave.Phase.UNCHANGED);
        require(p.next(5, 9, true, 1, 2) == CameraPreviewInterleave.Phase.UNCHANGED);
        p.enable(6, 9); p.posted(CameraPreviewInterleave.Phase.SOURCE, 5, 8);
        require(p.sourcePosts() == 0 && p.keyPosts() == 0);
        p.disable();
        require(p.next(6, 9, true, 1, 2) == CameraPreviewInterleave.Phase.UNCHANGED);
        System.out.println("PASS bounded cadence/decimator coverage, source expiry, absent/future source and lease replacement");
    }
}
