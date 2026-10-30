import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public final class CameraCallbackDispatcherTests {
    static void require(boolean value) {if (!value) throw new AssertionError();}
    public static void main(String[] args) throws Exception {
        AtomicInteger failures = new AtomicInteger();
        List<Integer> lifecycle = Collections.synchronizedList(new ArrayList<>());
        CountDownLatch blocked = new CountDownLatch(1), release = new CountDownLatch(1), done = new CountDownLatch(1);
        try (CameraCallbackDispatcher dispatcher = new CameraCallbackDispatcher(8, failures::incrementAndGet)) {
            dispatcher.execute(() -> {blocked.countDown();try {release.await();} catch (InterruptedException e) {Thread.currentThread().interrupt();}});
            require(blocked.await(1, TimeUnit.SECONDS));
            // Configure, request, close, replacement configure retain admission order.
            for (int i=0; i<4; i++) {final int event=i;dispatcher.execute(() -> lifecycle.add(event));}
            dispatcher.execute(done::countDown);release.countDown();
            require(done.await(1, TimeUnit.SECONDS));require(lifecycle.equals(Arrays.asList(0,1,2,3)));require(failures.get()==0);
        } finally {release.countDown();}
        CountDownLatch entered = new CountDownLatch(1), hold = new CountDownLatch(1);
        AtomicInteger saturated = new AtomicInteger();
        try (CameraCallbackDispatcher dispatcher = new CameraCallbackDispatcher(1, saturated::incrementAndGet)) {
            dispatcher.execute(() -> {entered.countDown();try {hold.await();} catch (InterruptedException e) {Thread.currentThread().interrupt();}});
            require(entered.await(1, TimeUnit.SECONDS));
            dispatcher.execute(() -> {throw new AssertionError("Failed queue still dispatched");});
            dispatcher.execute(() -> {});dispatcher.execute(() -> {});
            require(saturated.get()==1);
        } finally {hold.countDown();}
        System.out.println("PASS serial lifecycle/request order and bounded fail-once dispatch; no Android device");
    }
}
