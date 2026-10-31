import java.io.IOException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Fence the actual old-source post, not a key/white paint waiting for a Canvas.
 * begin/snapshot run under the bitmap lock. complete runs only after the post
 * attempt finishes. This does not drain encoded frames or consumer analysis.
 */
final class CameraSourcePostFence {
    static final class Ticket {
        private final CameraSourcePostFence owner;
        private final CountDownLatch completed = new CountDownLatch(1);
        private Ticket(CameraSourcePostFence owner) {this.owner=owner;}
    }
    private final Object cameraLock;
    private Ticket active;
    CameraSourcePostFence(Object cameraLock) {
        if (cameraLock==null) throw new IllegalArgumentException();
        this.cameraLock=cameraLock;
    }
    private void requireBitmapLock() {
        if (!Thread.holdsLock(cameraLock)) throw new IllegalStateException("Bitmap lock required");
    }
    Ticket begin() {
        requireBitmapLock();
        synchronized (this) {
            if (active!=null) throw new IllegalStateException("Concurrent source posts");
            active=new Ticket(this);return active;
        }
    }
    Ticket snapshot() {requireBitmapLock();synchronized(this) {return active;}}
    void complete(Ticket ticket) {
        if (ticket==null) return;
        if (ticket.owner!=this) throw new IllegalArgumentException();
        synchronized (this) {if (active==ticket) active=null;}
        ticket.completed.countDown();
    }
    void await(Ticket ticket) throws IOException {await(ticket,2_000);}
    void await(Ticket ticket,long milliseconds) throws IOException {
        if (Thread.holdsLock(cameraLock)) throw new IOException("Cannot wait while holding bitmap lock");
        if (ticket==null) return;
        if (ticket.owner!=this || milliseconds<=0) throw new IOException("Invalid source post fence");
        try {
            if (!ticket.completed.await(milliseconds,TimeUnit.MILLISECONDS))
                throw new IOException("Old source post is not yet drained");
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();throw new IOException("Source post wait interrupted",interrupted);
        }
    }
}
