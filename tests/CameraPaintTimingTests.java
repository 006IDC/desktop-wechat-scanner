public final class CameraPaintTimingTests {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        CameraPaintTiming timing = new CameraPaintTiming();
        check(timing.snapshot().samples == 0);
        CameraPaintTiming.Ticket first = timing.accept(1_000_000);
        timing.posted(first, 0, 2_000_000, 3_000_000, 5_000_000);
        CameraPaintTiming.Snapshot s = timing.snapshot();
        check(s.samples == 1 && s.lastAcceptedToPost == 4 && s.lastCanvasLock == 2 && s.lastDraw == 1 && s.lastPost == 2);
        timing.posted(first, 0, 2_000_000, 3_000_000, 9_000_000); // idle repaint
        check(timing.snapshot().samples == 1);
        CameraPaintTiming.Ticket stale = timing.accept(10_000_000);
        timing.accept(11_000_000);
        timing.posted(stale, 10_000_000, 11_000_000, 12_000_000, 13_000_000);
        check(timing.snapshot().samples == 1);
        CameraPaintTiming.Ticket cleared = timing.current(); timing.invalidate();
        timing.posted(cleared, 11_000_000, 12_000_000, 13_000_000, 14_000_000);
        check(timing.snapshot().samples == 1);
        timing.reset(); check(timing.snapshot().samples == 0);
        timing.posted(first, 1_000_000, 2_000_000, 3_000_000, 4_000_000);
        check(timing.snapshot().samples == 0);
        for (int i=0;i<140;i++) {
            CameraPaintTiming.Ticket ticket = timing.accept(1_000_000_000);
            timing.posted(ticket, 1_000_000_000, 1_000_000_001, 1_000_000_002, 1_000_000_000L+(i+1)*1_000_000L);
        }
        s = timing.snapshot(); check(s.samples == 128 && s.maximumAcceptedToPost == 140 && s.p95AcceptedToPost == 134);
        CameraPaintTiming.Ticket invalid = timing.accept(10);
        timing.posted(invalid, 20, 19, 30, 40); // invalid ordering is excluded
        check(timing.snapshot().samples == 128);
        System.out.println("PASS first current post, replacement/clear/reset fencing, bounded nearest-rank timing; no Android device");
    }
}
