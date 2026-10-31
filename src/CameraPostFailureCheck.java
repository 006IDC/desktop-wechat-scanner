import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.RejectedExecutionException;

/** One coalesced grace check per current scope, using the existing painter. */
final class CameraPostFailureCheck {
    private CameraRequestScope scope;
    private ScheduledFuture<?> pending;
    private long revision;
    synchronized boolean schedule(ScheduledExecutorService painter,CameraRequestScope requested,Runnable currentFailure) {
        if (pending!=null && requested.matches(scope)) return true;
        if (pending!=null) pending.cancel(false);
        pending=null;scope=requested;long admitted=++revision;
        try {
            pending=painter.schedule(() -> {
                synchronized(this) {
                    if(admitted!=revision) return;
                    pending=null;
                }
                // Never hold this monitor across the server's stateLock.
                currentFailure.run();
            },100,TimeUnit.MILLISECONDS);
            return true;
        }catch(RejectedExecutionException closed) {return false;}
    }
}
