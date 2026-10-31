import java.io.IOException;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public final class CameraSourcePostFenceTests {
    static void require(boolean value) {if(!value) throw new AssertionError();}
    public static void main(String[] args) throws Exception {
        Object bitmap=new Object();CameraSourcePostFence fence=new CameraSourcePostFence(bitmap);
        ExecutorService painter=Executors.newSingleThreadExecutor();
        CountDownLatch canvasEntered=new CountDownLatch(1),canvasRelease=new CountDownLatch(1);
        AtomicBoolean oldSource=new AtomicBoolean(true),drewOld=new AtomicBoolean();
        try {
            painter.execute(() -> {
                canvasEntered.countDown();
                try {canvasRelease.await();} catch (InterruptedException e) {Thread.currentThread().interrupt();return;}
                synchronized(bitmap) {if(oldSource.get()) drewOld.set(true);}
            });
            require(canvasEntered.await(1,TimeUnit.SECONDS));
            CameraSourcePostFence.Ticket none;
            synchronized(bitmap) {oldSource.set(false);none=fence.snapshot();}
            require(none==null);fence.await(none,25); // A blocked no-source Canvas must not delay discard.
            canvasRelease.countDown();painter.submit(() -> {}).get(1,TimeUnit.SECONDS);require(!drewOld.get());
            CountDownLatch posted=new CountDownLatch(1),releasePost=new CountDownLatch(1);
            CameraSourcePostFence.Ticket ticket;
            synchronized(bitmap) {ticket=fence.begin();require(fence.snapshot()==ticket);}
            painter.execute(() -> {try {releasePost.await();posted.countDown();} catch(InterruptedException e) {Thread.currentThread().interrupt();}finally{fence.complete(ticket);}});
            try {fence.await(ticket,25);throw new AssertionError("Old source post skipped");}catch(IOException expected){require(posted.getCount()==1);}
            releasePost.countDown();fence.await(ticket,1_000);require(posted.getCount()==0);
            CameraSourcePostFence.Ticket replacement;
            synchronized(bitmap) {replacement=fence.begin();}
            fence.complete(ticket); // A late/idempotent old completion cannot release its replacement.
            synchronized(bitmap) {require(fence.snapshot()==replacement);}
            try {fence.await(replacement,25);throw new AssertionError();}catch(IOException expected){}
            Thread.currentThread().interrupt();
            try {fence.await(replacement,100);throw new AssertionError();}catch(IOException expected){require(Thread.currentThread().isInterrupted());}finally{Thread.interrupted();}
            synchronized(bitmap) {
                try {fence.await(replacement,25);throw new AssertionError("Deadlock-prone wait allowed");}catch(IOException expected){}
            }
            fence.complete(replacement);
            synchronized(bitmap) {require(fence.snapshot()==null);}
            try {fence.begin();throw new AssertionError("Unfenced draw allowed");}catch(IllegalStateException expected){}
            System.out.println("PASS source-before-post wait, no-source Canvas bypass, old completion isolation, interrupt/timeout and bitmap lock contract");
        } finally {canvasRelease.countDown();painter.shutdownNow();painter.awaitTermination(1,TimeUnit.SECONDS);}
    }
}
