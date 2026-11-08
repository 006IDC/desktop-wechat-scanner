import java.io.IOException;
import java.lang.reflect.InvocationTargetException;

public final class OwnedInputInjectorTests {
    public static final class Modern {
        static int calls;
        public static Modern getInstance() { return new Modern(); }
        public boolean injectInputEvent(Object event, int mode) { calls++; return event != null && mode == 0; }
    }
    public static final class MissingMethod { public static MissingMethod getInstance() { return new MissingMethod(); } }
    public static final class Denied {
        public boolean injectInputEvent(Object event, int mode) { throw new SecurityException("fixture"); }
    }
    public static void main(String[] args) throws Exception {
        OwnedInputInjector modern = OwnedInputInjector.create(new Modern(), Object.class);
        modern.inject(new Object()); modern.inject(new Object());
        if (Modern.calls != 2) throw new AssertionError("Modern events lost");
        try { modern.inject(null); throw new AssertionError("Rejection swallowed"); } catch (IOException expected) {}
        try {OwnedInputInjector.create(null,Object.class);throw new AssertionError("Missing service accepted");}catch(IOException expected){}
        try {OwnedInputInjector.create(new MissingMethod(),Object.class);throw new AssertionError("Missing API accepted");}catch(NoSuchMethodException expected){}
        try {
            OwnedInputInjector.create(new Denied(),Object.class).inject(new Object());
            throw new AssertionError("Permission failure swallowed");
        } catch (InvocationTargetException expected) {
            if (!(expected.getCause() instanceof SecurityException)) throw expected;
        }
        System.out.println("PASS native service instance, rejection, missing service/API and permission propagation; no Android device/input");
    }
}
