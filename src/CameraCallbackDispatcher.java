import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.Executor;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicBoolean;

/** Serial camera lifecycle/request dispatch, separate from activity callbacks. */
final class CameraCallbackDispatcher implements Executor, AutoCloseable {
    private final ThreadPoolExecutor worker;
    private final AtomicBoolean failed = new AtomicBoolean(), closed = new AtomicBoolean();
    private final Runnable onFailure;
    CameraCallbackDispatcher(int capacity, Runnable onFailure) {
        if (capacity < 1) throw new IllegalArgumentException();
        this.onFailure = onFailure;
        worker = new ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(capacity));
    }
    private void fail() {
        if (!closed.get() && failed.compareAndSet(false, true)) onFailure.run();
    }
    @Override public void execute(Runnable command) {
        if (closed.get() || failed.get()) return;
        try {
            worker.execute(() -> {
                if (closed.get() || failed.get()) return;
                try { command.run(); } catch (RuntimeException failure) { fail(); }
            });
        } catch (RejectedExecutionException rejected) { fail(); }
    }
    @Override public void close() {closed.set(true);worker.shutdownNow();}
}
