import java.io.IOException;
import java.lang.reflect.Method;

/** Resolve input APIs once. Callers must still validate their owned display per event. */
final class OwnedInputInjector {
    private final Object manager;
    private final Method inject;

    private OwnedInputInjector(Object manager, Method inject) {
        this.manager = manager;
        this.inject = inject;
    }

    static OwnedInputInjector create(Object manager, Class<?> eventType) throws Exception {
        // The caller obtains the native Context.INPUT_SERVICE. Do not depend on
        // hidden singleton factories that move between Android releases.
        if (manager == null) throw new IOException("Owned input service unavailable");
        Method inject = manager.getClass().getMethod("injectInputEvent", eventType, int.class);
        return new OwnedInputInjector(manager, inject);
    }

    void inject(Object event) throws Exception {
        if (!Boolean.TRUE.equals(inject.invoke(manager, event, 0)))
            throw new IOException("Owned display input rejected");
    }
}
