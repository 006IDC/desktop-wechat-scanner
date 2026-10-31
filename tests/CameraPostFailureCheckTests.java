import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
public final class CameraPostFailureCheckTests {
    public static void main(String[] args) throws Exception {
        ScheduledExecutorService painter=Executors.newSingleThreadScheduledExecutor();
        CameraPostFailureCheck check=new CameraPostFailureCheck();
        CameraRequestScope old=new CameraRequestScope(1,1,1),replacement=new CameraRequestScope(2,2,2);
        AtomicInteger oldRuns=new AtomicInteger(),newRuns=new AtomicInteger();
        CountDownLatch done=new CountDownLatch(1);
        for(int i=0;i<100;i++) if(!check.schedule(painter,old,oldRuns::incrementAndGet)) throw new AssertionError();
        if(!check.schedule(painter,replacement,()->{newRuns.incrementAndGet();done.countDown();})) throw new AssertionError("Old scope starved replacement grace");
        if(!done.await(1,TimeUnit.SECONDS) || oldRuns.get()!=0 || newRuns.get()!=1) throw new AssertionError("Old checks ran or new check lost");
        CountDownLatch success=new CountDownLatch(1);
        if(!check.schedule(painter,replacement,success::countDown) || !success.await(1,TimeUnit.SECONDS)) throw new AssertionError("Completed check prevented next observation");
        painter.shutdown();if(!painter.awaitTermination(1,TimeUnit.SECONDS)) throw new AssertionError();
        if(check.schedule(painter,replacement,()->{})) throw new AssertionError("Closed executor accepted");
        System.out.println("PASS coalesced scoped grace: old saturation cannot starve replacement; completion reopens; rejection fails closed");
    }
}
