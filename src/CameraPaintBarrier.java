import java.io.IOException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

/** Source is cleared before entering this barrier. Every Canvas post runs on
 * the same serial painter; this drains producer work, not encoded camera frames.
 */
final class CameraPaintBarrier {
    static void await(ExecutorService painter) throws IOException { await(painter, 2_000); }
    static void await(ExecutorService painter, long milliseconds) throws IOException {
        Future<?> fence = null;
        try {
            fence = painter.submit(() -> {});
            fence.get(milliseconds, TimeUnit.MILLISECONDS);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IOException("Camera paint wait interrupted", interrupted);
        } catch (Exception failure) {
            throw new IOException("Camera paint drain failed", failure);
        } finally {
            if (fence != null && !fence.isDone()) fence.cancel(false);
        }
    }
}
