import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import java.io.ByteArrayOutputStream;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InputStream;
import java.util.concurrent.*;

/** Same activity/activities dump as dumpsys; no task selection or mutation. */
final class ActivityTaskDump implements AutoCloseable {
    static final int MAX_BYTES = 2 * 1024 * 1024;
    static final String UNAVAILABLE = "Activity task dump unavailable";
    static final String TIMEOUT = "Activity task dump timed out";
    interface Source { void dump(FileDescriptor output) throws Exception; }
    private final Object lock = new Object();
    private final Source source;
    private final int maximumBytes;
    private final long timeoutMillis;
    private final ExecutorService workers = Executors.newFixedThreadPool(2, runnable -> {
        Thread thread = new Thread(runnable, "Owned activity task dump");
        thread.setDaemon(true);
        return thread;
    });
    private boolean retired;
    private Job active;

    ActivityTaskDump() {
        this(output -> {
            Object service = Class.forName("android.os.ServiceManager")
                    .getMethod("getService", String.class).invoke(null, "activity");
            if (!(service instanceof IBinder)) throw new IOException(UNAVAILABLE);
            ((IBinder) service).dump(output, new String[]{"activities"});
        }, MAX_BYTES, 2_000);
    }

    // Fake sources exercise the real pipe, limits, timeout and close on Android.
    ActivityTaskDump(Source source, int maximumBytes, long timeoutMillis) {
        if (source == null || maximumBytes <= 0 || maximumBytes > MAX_BYTES
                || timeoutMillis <= 0 || timeoutMillis > 2_000) throw new IllegalArgumentException();
        this.source = source;
        this.maximumBytes = maximumBytes;
        this.timeoutMillis = timeoutMillis;
    }

    boolean available() { synchronized (lock) { return !retired; } }

    private static final class Job {
        final ParcelFileDescriptor read, write;
        Future<byte[]> reader;
        Future<?> writer;
        Job() throws IOException {
            ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
            read = pipe[0]; write = pipe[1];
        }
        void close() {
            // Closing the pipe releases the collector even if a remote Binder
            // transaction ignores Java interruption. Never wait for that worker.
            try { read.close(); } catch (IOException ignored) {}
            try { write.close(); } catch (IOException ignored) {}
            if (reader != null) reader.cancel(true);
            if (writer != null) writer.cancel(true);
        }
    }

    byte[] read() throws IOException {
        final Job job;
        synchronized (lock) {
            if (retired || active != null) throw new IOException(UNAVAILABLE);
            try {
                job = new Job();
                active = job;
                job.reader = workers.submit(() -> {
                    try (InputStream input = new ParcelFileDescriptor.AutoCloseInputStream(job.read);
                         ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
                        byte[] buffer = new byte[8192];
                        int count;
                        while ((count = input.read(buffer)) >= 0) {
                            if (bytes.size() + count > maximumBytes) throw new IOException(UNAVAILABLE);
                            bytes.write(buffer, 0, count);
                        }
                        return bytes.toByteArray();
                    }
                });
                job.writer = workers.submit(() -> {
                    try { source.dump(job.write.getFileDescriptor()); }
                    finally { try { job.write.close(); } catch (IOException ignored) {} }
                    return null;
                });
            } catch (Exception failure) {
                retired = true;
                if (active != null) active.close();
                active = null;
                workers.shutdownNow();
                throw new IOException(UNAVAILABLE);
            }
        }
        final long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis);
        try {
            job.writer.get(Math.max(1, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
            byte[] bytes = job.reader.get(Math.max(1, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
            if (System.nanoTime() >= deadline) throw new TimeoutException();
            synchronized (lock) {
                if (retired || active != job) throw new IOException(UNAVAILABLE);
            }
            if (bytes.length == 0) throw new IOException(UNAVAILABLE);
            return bytes;
        } catch (TimeoutException timeout) {
            close();
            throw new IOException(TIMEOUT);
        } catch (Exception failure) {
            close();
            if (failure instanceof InterruptedException) Thread.currentThread().interrupt();
            // No service exception message, task text, intent or package is logged.
            throw new IOException(UNAVAILABLE);
        } finally {
            job.close();
            synchronized (lock) { if (active == job) active = null; }
        }
    }

    @Override public void close() {
        Job job;
        synchronized (lock) { retired = true; job = active; active = null; }
        if (job != null) job.close();
        workers.shutdownNow();
    }
}
