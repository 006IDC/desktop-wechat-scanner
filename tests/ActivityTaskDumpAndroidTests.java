import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Fake sources only. Real Android pipes, with no ActivityManager/camera calls. */
public final class ActivityTaskDumpAndroidTests {
    static int checks;
    static void require(boolean condition) { if (!condition) throw new AssertionError(); }
    static void failure(ActivityTaskDump dump, String message) throws Exception {
        try { dump.read(); throw new AssertionError("Read unexpectedly succeeded"); }
        catch (IOException expected) { require(message.equals(expected.getMessage())); }
    }
    static void write(java.io.FileDescriptor fd, byte[] bytes) throws Exception {
        // The helper owns the descriptor and closes it after the source returns.
        FileOutputStream output = new FileOutputStream(fd);
        output.write(bytes); output.flush();
    }
    public static void main(String[] args) throws Exception {
        Thread watchdog = new Thread(() -> {
            try { Thread.sleep(15_000); Runtime.getRuntime().halt(124); }
            catch (InterruptedException ignored) {}
        });
        watchdog.setDaemon(true); watchdog.start();
        byte[] fixture = "Display #7 (activities from top to bottom):\n".getBytes(StandardCharsets.UTF_8);
        AtomicInteger calls = new AtomicInteger();
        try (ActivityTaskDump dump = new ActivityTaskDump(fd -> {
            calls.incrementAndGet(); write(fd, fixture);
        }, 4096, 1000)) {
            require(Arrays.equals(dump.read(), fixture));
            require(Arrays.equals(dump.read(), fixture) && calls.get() == 2 && dump.available());
        }
        checks++;

        byte[] boundary = new byte[64];
        try (ActivityTaskDump dump = new ActivityTaskDump(fd -> write(fd, boundary), 64, 1000)) {
            require(Arrays.equals(dump.read(), boundary));
        }
        checks++;

        calls.set(0);
        try (ActivityTaskDump dump = new ActivityTaskDump(fd -> {
            calls.incrementAndGet(); write(fd, new byte[65]);
        }, 64, 1000)) {
            failure(dump, ActivityTaskDump.UNAVAILABLE);
            require(!dump.available());
            failure(dump, ActivityTaskDump.UNAVAILABLE);
            require(calls.get() == 1);
        }
        checks++;

        try (ActivityTaskDump dump = new ActivityTaskDump(fd -> {}, 64, 1000)) {
            failure(dump, ActivityTaskDump.UNAVAILABLE); require(!dump.available());
        }
        checks++;

        try (ActivityTaskDump dump = new ActivityTaskDump(fd -> {
            throw new IOException("Synthetic private payload must not escape");
        }, 64, 1000)) {
            failure(dump, ActivityTaskDump.UNAVAILABLE); require(!dump.available());
        }
        checks++;

        long began = System.nanoTime();
        try (ActivityTaskDump dump = new ActivityTaskDump(fd -> Thread.sleep(10_000), 64, 100)) {
            failure(dump, ActivityTaskDump.TIMEOUT); require(!dump.available());
            require(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - began) < 1500);
        }
        checks++;

        ExecutorService caller = Executors.newSingleThreadExecutor();
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        try (ActivityTaskDump dump = new ActivityTaskDump(fd -> {
            entered.countDown(); release.await(); write(fd, fixture);
        }, 4096, 1000)) {
            Future<byte[]> first = caller.submit(dump::read);
            require(entered.await(1, TimeUnit.SECONDS));
            failure(dump, ActivityTaskDump.UNAVAILABLE);
            require(dump.available());
            release.countDown();
            require(Arrays.equals(first.get(1, TimeUnit.SECONDS), fixture));
        } finally { release.countDown(); caller.shutdownNow(); }
        checks++;

        ExecutorService pendingCaller = Executors.newSingleThreadExecutor();
        CountDownLatch blocked = new CountDownLatch(1), unblock = new CountDownLatch(1);
        ActivityTaskDump pending = new ActivityTaskDump(fd -> {
            blocked.countDown(); unblock.await(); write(fd, fixture);
        }, 4096, 1000);
        try {
            Future<byte[]> reply = pendingCaller.submit(pending::read);
            require(blocked.await(1, TimeUnit.SECONDS));
            pending.close(); require(!pending.available());
            try { reply.get(1, TimeUnit.SECONDS); throw new AssertionError("Closed job published data"); }
            catch (ExecutionException expected) {
                require(expected.getCause() instanceof IOException);
                require(ActivityTaskDump.UNAVAILABLE.equals(expected.getCause().getMessage()));
            }
        } finally { pending.close(); unblock.countDown(); pendingCaller.shutdownNow(); }
        checks++;

        AtomicInteger neverStarted = new AtomicInteger();
        ActivityTaskDump closed = new ActivityTaskDump(fd -> neverStarted.incrementAndGet(), 64, 1000);
        closed.close(); failure(closed, ActivityTaskDump.UNAVAILABLE); require(neverStarted.get() == 0);
        checks++;
        System.out.println("ACTIVITY_TASK_DUMP_TESTS {\"passed\":true,\"checks\":" + checks + "}");
    }
}
