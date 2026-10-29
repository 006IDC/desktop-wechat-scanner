import java.util.ArrayDeque;
import java.util.Arrays;

/** Numeric, session-local observation only; never retains pixels or app identity. */
final class CameraPaintTiming {
    static final int LIMIT = 128;
    static final class Ticket {
        final long acceptedAt;
        Ticket(long acceptedAt) { this.acceptedAt = acceptedAt; }
    }
    static final class Snapshot {
        final int samples;
        final double lastAcceptedToPost, p95AcceptedToPost, maximumAcceptedToPost;
        final double lastCanvasLock, lastDraw, lastPost;
        Snapshot(int count, double last, double p95, double maximum, double lock, double draw, double post) {
            samples = count; lastAcceptedToPost = last; p95AcceptedToPost = p95;
            maximumAcceptedToPost = maximum; lastCanvasLock = lock; lastDraw = draw; lastPost = post;
        }
    }
    private final ArrayDeque<double[]> samples = new ArrayDeque<>();
    private Ticket current, recorded;
    synchronized Ticket accept(long time) {
        current = new Ticket(time); return current;
    }
    synchronized Ticket current() { return current; }
    synchronized void invalidate() { current = null; }
    synchronized void reset() { current = null; recorded = null; samples.clear(); }
    synchronized void posted(Ticket ticket, long lockBegan, long locked, long drawn, long posted) {
        // Only the first successful post of the still-current source counts.
        // A clear/replacement invalidates an already queued draw's observation.
        if (ticket == null || ticket != current || ticket == recorded ||
                locked < lockBegan || drawn < locked || posted < drawn || posted < ticket.acceptedAt) return;
        double total = (posted - ticket.acceptedAt) / 1_000_000.0;
        if (!Double.isFinite(total) || total > 60_000) return;
        recorded = ticket;
        if (samples.size() == LIMIT) samples.removeFirst();
        samples.addLast(new double[]{total, (locked-lockBegan)/1_000_000.0,
                (drawn-locked)/1_000_000.0, (posted-drawn)/1_000_000.0});
    }
    synchronized Snapshot snapshot() {
        if (samples.isEmpty()) return new Snapshot(0, 0, 0, 0, 0, 0, 0);
        double[] totals = samples.stream().mapToDouble(sample -> sample[0]).toArray();
        Arrays.sort(totals);
        double[] last = samples.peekLast();
        return new Snapshot(totals.length, last[0], totals[(int)Math.ceil(totals.length*0.95)-1],
                totals[totals.length-1], last[1], last[2], last[3]);
    }
}
