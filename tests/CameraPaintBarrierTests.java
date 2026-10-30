import java.io.IOException;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

public final class CameraPaintBarrierTests {
    static void require(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        ExecutorService painter = Executors.newSingleThreadExecutor();
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicBoolean posted = new AtomicBoolean(), ack = new AtomicBoolean();
        painter.execute(() -> {
            entered.countDown();
            try { release.await(); posted.set(true); }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        });
        require(entered.await(1, TimeUnit.SECONDS));
        Thread waiter = new Thread(() -> {
            try { CameraPaintBarrier.await(painter); require(posted.get()); ack.set(true); }
            catch (IOException failure) { throw new AssertionError(failure); }
        });
        try {
            waiter.start();
            try { CameraPaintBarrier.await(painter, 25); throw new AssertionError("Blocked post was acknowledged"); }
            catch (IOException expected) { require(!posted.get() && !ack.get()); }
            release.countDown(); waiter.join(1_000); require(!waiter.isAlive() && ack.get());
            Thread.currentThread().interrupt();
            try { CameraPaintBarrier.await(painter); throw new AssertionError("Interrupted drain accepted"); }
            catch (IOException expected) { require(Thread.currentThread().isInterrupted()); }
            finally { Thread.interrupted(); }
        } finally {
            release.countDown(); painter.shutdownNow(); painter.awaitTermination(1, TimeUnit.SECONDS);
        }
        try { CameraPaintBarrier.await(painter); throw new AssertionError("Closed painter accepted"); }
        catch (IOException expected) {}
        System.out.println("PASS producer post precedes clear ACK; timeout/interruption/closed executor fail closed");
    }
}
