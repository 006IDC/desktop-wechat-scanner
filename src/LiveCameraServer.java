import android.content.Context;
import android.content.Intent;
import android.content.pm.ResolveInfo;
import android.content.ComponentName;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.HashSet;
import java.util.List;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.hardware.camera2.CameraMetadata;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Process;
import android.os.UserHandle;
import android.os.UserManager;
import android.view.Display;
import android.view.Surface;

import java.io.BufferedOutputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicBoolean;

/** One authenticated USB-forwarded session, scoped to its own Android virtual device. */
public final class LiveCameraServer {
    private static final String PREFIX = "QR_LIVE ";
    private static final String WECHAT = "com.tencent.mm";
    private static final String ALIPAY = "com.eg.android.AlipayGphone";
    private static final int MAX_IMAGE_BYTES = 4 * 1024 * 1024;
    private static final int MAX_IMAGE_SIDE = 2048;
    private int displayWidth = 720;
    private int displayHeight = 1280;
    private int displayDpi = 320;
    private static final int SOCKET_IDLE_MS = 90_000;
    private static final int FIRST_CONNECTION_MS = 60_000;
    private static final String INDEPENDENT_LOCK_PERMISSION = "android.permission.ADD_ALWAYS_UNLOCKED_DISPLAY";
    private static final String CAMERA_OWNER_PERMISSION = "android.permission.CAMERA_OPEN_CLOSE_LISTENER";
    private boolean independentLockRequested;
    private boolean desktopHomeRequested;
    private boolean balancedDisplayRequested, displayBeforeCameraRequested, mirrorOnlyRequested, realtimeVideoRequested;
    // Android 16 DisplayManager.VIRTUAL_DISPLAY_FLAG_SHOULD_SHOW_SYSTEM_DECORATIONS.
    private static final int DISPLAY_SYSTEM_DECORATIONS = 1 << 9;

    private final Object cameraLock = new Object();
    private final CameraSourcePostFence sourcePostFence = new CameraSourcePostFence(cameraLock);
    private final CameraPaintTiming cameraPaintTiming = new CameraPaintTiming();
    private final Object cameraPermissionLock = new Object();
    private final Object frameLock = new Object();
    private final Object stateLock = new Object();
    private final Map<Integer, String> topActivities = new HashMap<>();
    // Device callbacks can precede createVirtualDisplay returning its owned ID.
    // Keep only a few candidates, then retain only the verified owned display.
    private final Map<Integer, String> earlyTopActivities = new HashMap<>();
    private static final int MAX_EARLY_ACTIVITY_IDS = 8;
    private long streamGeneration;
    // Every relevant owner/activity transition invalidates previously decoded
    // desktop pixels before another virtual-camera client can receive them.
    private volatile long cameraStateGeneration;
    private long frameStateGeneration = -1; // guarded by cameraLock
    private volatile int primaryOwnedDisplayId = -1;
    private Object activityListener;
    private final Map<Integer, Surface> streams = new ConcurrentHashMap<>();
    private final ExecutorService callbacks = Executors.newSingleThreadExecutor();
    private final ScheduledExecutorService painter = Executors.newSingleThreadScheduledExecutor();
    private final ExecutorService acceptor = Executors.newSingleThreadExecutor();
    private final ActivityTaskDump activityTaskDump = new ActivityTaskDump();
    // Legacy refreshes coalesce to one queued pass. Desktop-camera paints
    // instead follow actual capture requests, capped at 128 pending tasks.
    // Both paths share one painter: never concurrent Canvas access.
    private final AtomicBoolean paintPending = new AtomicBoolean();
    private final java.util.concurrent.atomic.AtomicInteger requestPaints = new java.util.concurrent.atomic.AtomicInteger();
    private final java.util.concurrent.atomic.AtomicInteger requestPeak = new java.util.concurrent.atomic.AtomicInteger();
    private final java.util.concurrent.atomic.AtomicLong cameraRequests = new java.util.concurrent.atomic.AtomicLong();
    private final java.util.concurrent.atomic.AtomicLong requestOverflows = new java.util.concurrent.atomic.AtomicLong();
    private final java.util.concurrent.atomic.AtomicLong requestPosts = new java.util.concurrent.atomic.AtomicLong();
    private final java.util.concurrent.atomic.AtomicLong requestIdentitySkips = new java.util.concurrent.atomic.AtomicLong();
    private final java.util.concurrent.atomic.AtomicLong requestPostFailures = new java.util.concurrent.atomic.AtomicLong();
    private final java.util.concurrent.atomic.AtomicLong requestRejected = new java.util.concurrent.atomic.AtomicLong();
    private final Object requestTimingLock = new Object();
    private final java.util.ArrayDeque<Double> requestPostTimes = new java.util.ArrayDeque<>();
    private void recordRequestedPost(long began) {
        double elapsed = (System.nanoTime() - began) / 1_000_000.0;
        requestPosts.incrementAndGet();
        synchronized (requestTimingLock) {
            if (requestPostTimes.size() == 128) requestPostTimes.removeFirst();
            requestPostTimes.addLast(elapsed);
        }
    }
    private double requestPostPercentile() {
        synchronized (requestTimingLock) {
            if (requestPostTimes.isEmpty()) return 0;
            double[] values = requestPostTimes.stream().mapToDouble(Double::doubleValue).toArray();
            Arrays.sort(values);return values[(int) Math.ceil(values.length * 0.95) - 1];
        }
    }
    private final AtomicBoolean requestDriverFailed = new AtomicBoolean();
    private final CameraPostFailureCheck postFailureChecks = new CameraPostFailureCheck();
    private final CameraCallbackDispatcher cameraCallbacks = new CameraCallbackDispatcher(128, this::failRequestDriver);
    private void failRequestDriver() {
        if (!desktopHomeRequested || stopping || !requestDriverFailed.compareAndSet(false, true)) return;
        long invalidation;
        synchronized (stateLock) {invalidation = markDesktopFrameInvalidLocked();}
        discardObsoleteDesktopFrame(invalidation);
    }
    private final AtomicBoolean clearPending = new AtomicBoolean();
    private volatile long lastCameraUpdateNanos = System.nanoTime();
    private volatile boolean stopping;
    private Image latestDisplayImage;
    private Context context;
    private Bitmap cameraFrame;
    private Integer cameraSolidColor; // guarded by cameraLock, same generation fence as Bitmap
    private Object device;
    private Object camera;
    private VirtualDisplay display;
    private ImageReader displayReader;
    private final Map<Integer, DirectDisplayStream> directStreams = new ConcurrentHashMap<>();
    private final Map<Integer, AppDisplay> appDisplays = new ConcurrentHashMap<>();
    private static final class AppDisplay {
        final VirtualDisplay display;
        final ImageReader reader;
        AppDisplay(VirtualDisplay display, ImageReader reader) { this.display = display; this.reader = reader; }
        void close() { try { display.release(); } finally { reader.close(); } }
    }
    private HandlerThread imageThread;
    private LocalServerSocket server;
    private LocalSocket client;
    private int deviceId = -1;
    private final HashSet<String> grantedCameraPackages = new HashSet<>();
    private CameraManager cameraManager;
    private CameraManager.AvailabilityCallback cameraOwnerListener;
    private String virtualCameraId;
    private String cameraOwner;
    private final DesktopCameraRouting desktopCameraRouting = new DesktopCameraRouting();
    private boolean cameraOwnerKnown;
    private long ownerGeneration;
    // A bounded reason for fail-closed camera ownership detection in CMD 5.
    private String ownerStatus = "uninitialized";
    private String ownerErrorClass, ownerErrorDetail;
    private int ownerVisibleCameraCount, ownerBackCameraCount;
    private int ownerDeviceKeyListedCount, ownerDeviceIdPresentCount, ownerDeviceIdMatchCount;
    // Only the authenticated command reader changes this value. A clear advances
    // the epoch so a frame captured before pause cannot revive the camera.
    private volatile long currentEpoch;
    private final CameraPreviewInterleave previewInterleave = new CameraPreviewInterleave();
    private long sourceAcceptedNanos; // cameraLock
    private NativePreviewPattern previewPattern; // cameraLock
    private final CameraSourceLease sourceLease = new CameraSourceLease();
    private boolean nativeSourceOnly; // stateLock + cameraLock; cleared by explicit disable or a new capture epoch


    private static void log(String key, Object value) {
        System.out.println(PREFIX + key + "=" + value);
        System.out.flush();
    }

    private static Object call(Object target, String method, Class<?>[] types, Object... values) throws Exception {
        return CameraProbe.call(target, method, types, values);
    }

    static final class SessionFlags {
        final boolean independentLock;
        final boolean desktopHome;
        final boolean balancedDisplay, displayBeforeCamera, mirrorOnly, realtimeVideo, desktopCameraSource;
        SessionFlags(boolean independentLock, boolean desktopHome, boolean balancedDisplay, boolean displayBeforeCamera, boolean mirrorOnly, boolean realtimeVideo, boolean desktopCameraSource) {
            this.independentLock = independentLock;
            this.desktopHome = desktopHome;
            this.balancedDisplay = balancedDisplay;
            this.displayBeforeCamera = displayBeforeCamera;
            this.mirrorOnly = mirrorOnly;
            this.realtimeVideo = realtimeVideo;
            this.desktopCameraSource = desktopCameraSource;
        }
        boolean needsCompatibilityCameraGrants() { return !mirrorOnly && !desktopCameraSource; }
    }

    static SessionFlags parseSessionFlags(String[] args) {
        if (args == null || args.length < 3 || args.length > 10 ||
                !args[1].matches("006idc_scan_[0-9a-f]{8}") || !args[2].matches("[0-9a-f]{32}"))
            throw new IllegalArgumentException("Expected associationId 006idc_scan_<8 hex> <32 hex token> [independent-lock] [desktop-home] [balanced-display] [display-before-camera] [mirror-only] [realtime-video] [desktop-camera-source]");
        boolean independentLock = false;
        boolean desktopHome = false;
        boolean balancedDisplay = false, displayBeforeCamera = false, mirrorOnly = false, realtimeVideo = false, desktopCameraSource = false;
        for (int index = 3; index < args.length; index++) {
            if ("independent-lock".equals(args[index]) && !independentLock) independentLock = true;
            else if ("desktop-home".equals(args[index]) && !desktopHome) desktopHome = true;
            else if ("balanced-display".equals(args[index]) && !balancedDisplay) balancedDisplay = true;
            else if ("display-before-camera".equals(args[index]) && !displayBeforeCamera) displayBeforeCamera = true;
            else if ("mirror-only".equals(args[index]) && !mirrorOnly) mirrorOnly = true;
            else if ("realtime-video".equals(args[index]) && !realtimeVideo) realtimeVideo = true;
            else if ("desktop-camera-source".equals(args[index]) && !desktopCameraSource) desktopCameraSource = true;
            else throw new IllegalArgumentException("Unsupported or duplicate virtual display flag");
        }
        if ((balancedDisplay || displayBeforeCamera || mirrorOnly || realtimeVideo) && !desktopHome)
            throw new IllegalArgumentException("Research display flags require desktop-home");
        if (desktopCameraSource && (!desktopHome || mirrorOnly))
            throw new IllegalArgumentException("Desktop camera source requires a camera-enabled desktop-home session");
        return new SessionFlags(independentLock, desktopHome, balancedDisplay, displayBeforeCamera, mirrorOnly, realtimeVideo, desktopCameraSource);
    }

    static boolean requestedIndependentLock(String[] args) {
        return parseSessionFlags(args).independentLock;
    }

    static boolean requestedDesktopHome(String[] args) {
        return parseSessionFlags(args).desktopHome;
    }

    static String[] cameraPackagesForMode(boolean desktopHome) {
        return desktopHome ? new String[]{WECHAT, ALIPAY} : new String[]{WECHAT};
    }

    static boolean isOwnedCameraEvent(String ownedCameraId, String eventCameraId) {
        return ownedCameraId != null && !ownedCameraId.isEmpty() && ownedCameraId.equals(eventCameraId);
    }

    static boolean isOwnedCameraEvent(String ownedCameraId, String verifiedMappedId, String eventCameraId) {
        return isOwnedCameraEvent(ownedCameraId, eventCameraId) ||
                isOwnedCameraEvent(verifiedMappedId, eventCameraId);
    }

    // INFO_DEVICE_ID is present for virtual cameras and absent for physical
    // cameras. It proves alias "0" independently of OEM access to the flag API.
    static String verifiedMappedBackCameraId(int ownedDeviceId, boolean customPolicy,
                                             String[] visibleIds, Map<String, Integer> facingById,
                                             Map<String, Integer> deviceById) {
        if (ownedDeviceId <= Context.DEVICE_ID_DEFAULT || !customPolicy || visibleIds == null ||
                facingById == null || deviceById == null) return null;
        String back = null;
        for (String id : visibleIds) {
            if (!Integer.valueOf(CameraMetadata.LENS_FACING_BACK).equals(facingById.get(id)) ||
                    !Integer.valueOf(ownedDeviceId).equals(deviceById.get(id))) continue;
            if (back != null) return null;
            back = id;
        }
        return "0".equals(back) ? back : null;
    }

    static boolean isVerifiedScanner(String component) {
        return "com.tencent.mm/.plugin.scanner.ui.BaseScanUI".equals(component) ||
                "com.tencent.mm/com.tencent.mm.plugin.scanner.ui.BaseScanUI".equals(component) ||
                "com.eg.android.AlipayGphone/com.alipay.mobile.scan.as.main.MainCaptureActivity".equals(component);
    }

    static void requireIndependentLockPrerequisites(int userId, boolean userUnlocked, boolean permissionGranted) {
        if (userId != 0) throw new SecurityException("Independent app displays require the primary Android user");
        if (!userUnlocked) throw new SecurityException("Unlock the primary phone user normally once after boot before enabling independent app displays");
        if (!permissionGranted) throw new SecurityException("Independent app displays require existing android.permission.ADD_ALWAYS_UNLOCKED_DISPLAY permission; no permission was granted");
    }

    static boolean verifyIndependentDisplayFlags(boolean requested, int displayId, boolean valid, int flags, int alwaysUnlockedFlag) {
        if (!requested) return false;
        // AOSP Android 16 android.view.Display.FLAG_ALWAYS_UNLOCKED is 1<<9.
        // This is NOT DisplayManager.VIRTUAL_DISPLAY_FLAG_ALWAYS_UNLOCKED (1<<12).
        if (alwaysUnlockedFlag != (1 << 9))
            throw new IllegalStateException("Unsupported actual Display.FLAG_ALWAYS_UNLOCKED value");
        if (!valid || displayId <= Display.DEFAULT_DISPLAY || (flags & alwaysUnlockedFlag) == 0)
            throw new IllegalStateException("Independent lock policy was requested but is not active on the created app display; display creation was cancelled");
        return true;
    }

    private boolean verifyIndependentLock(VirtualDisplay candidate) throws Exception {
        if (!independentLockRequested) return false;
        final int actualFlag;
        try { actualFlag = Display.class.getField("FLAG_ALWAYS_UNLOCKED").getInt(null); }
        catch (ReflectiveOperationException unsupported) {
            throw new IllegalStateException("System does not expose the required Display.FLAG_ALWAYS_UNLOCKED verification", unsupported);
        }
        Display actual = candidate == null ? null : candidate.getDisplay();
        return verifyIndependentDisplayFlags(true, actual == null ? -1 : actual.getDisplayId(),
                actual != null && actual.isValid(), actual == null ? 0 : actual.getFlags(), actualFlag);
    }

    static boolean independentDisplayOn(int displayId, boolean valid, int state) {
        if (!valid || displayId <= Display.DEFAULT_DISPLAY)
            throw new IllegalStateException("Independent display power verification requires a valid owned non-default display");
        return state == Display.STATE_ON;
    }

    static void verifyPrimaryDisplayPower(int before, int after) {
        if (before == Display.STATE_OFF && after == Display.STATE_ON)
            throw new IllegalStateException("Independent display wakeUp also turned the primary display ON; screen-off independent use is unsupported");
    }

    private int primaryDisplayState() {
        DisplayManager manager = context.getSystemService(DisplayManager.class);
        Display primary = manager == null ? null : manager.getDisplay(Display.DEFAULT_DISPLAY);
        if (primary == null || !primary.isValid())
            throw new IllegalStateException("Cannot read primary display power state for independent wake verification");
        return primary.getState();
    }

    private void wakeIndependentDisplay(VirtualDisplay candidate) throws Exception {
        if (!independentLockRequested) return;
        Display actual = candidate == null ? null : candidate.getDisplay();
        if (actual == null || actual.getDisplayId() <= Display.DEFAULT_DISPLAY || !actual.isValid())
            throw new IllegalStateException("Cannot wake an invalid independent app display");
        final int ownedId = actual.getDisplayId();
        final int primaryBefore = primaryDisplayState();
        log("primary_display_state_before", String.valueOf(primaryBefore));
        try {
            try {
                // AOSP Android 16 VirtualDevice.wakeUp() operates only this device's
                // trusted owned display groups. Never use PowerManager/display 0.
                call(device, "wakeUp", new Class[]{});
            } catch (NoSuchMethodException unsupported) {
                throw new UnsupportedOperationException("Independent virtual-device wakeUp is unsupported on this system", unsupported);
            } catch (InvocationTargetException rejected) {
                throw new IllegalStateException("Independent virtual-device wakeUp was rejected by the system", rejected.getCause());
            }
            final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
            int lastState = Integer.MIN_VALUE;
            do {
                actual = candidate.getDisplay();
                if (actual == null || actual.getDisplayId() != ownedId || !actual.isValid())
                    throw new IllegalStateException("Owned independent app display disappeared while waiting for power ON");
                int state = actual.getState();
                if (state != lastState) {
                    log("independent_display_state", "display_id:" + ownedId + ",state:" + state);
                    lastState = state;
                }
                if (independentDisplayOn(ownedId, actual.isValid(), state)) return;
                Thread.sleep(25);
            } while (System.nanoTime() < deadline);
            throw new IOException("Timed out after 2 seconds waiting for owned independent display ON; display_id=" + ownedId + ", state=" + lastState);
        } finally {
            // Read-only physical display check; never compensate by changing its power.
            int primaryAfter = primaryDisplayState();
            log("primary_display_state_after", String.valueOf(primaryAfter));
            verifyPrimaryDisplayPower(primaryBefore, primaryAfter);
        }
    }

    private void createVirtualDevice(int associationId) throws Exception {
        if (independentLockRequested) {
            UserManager users = context.getSystemService(UserManager.class);
            requireIndependentLockPrerequisites(Process.myUid() / 100000, users != null && users.isUserUnlocked(),
                    context.checkSelfPermission(INDEPENDENT_LOCK_PERMISSION) == PackageManager.PERMISSION_GRANTED);
        }
        Class<?> paramsClass = Class.forName("android.companion.virtual.VirtualDeviceParams");
        Object builder = Class.forName(paramsClass.getName() + "$Builder").getConstructor().newInstance();
        call(builder, "setName", new Class[]{String.class}, "006IDC desktop scanner");
        if (!mirrorOnlyRequested) {
            int cameraPolicy = paramsClass.getField("POLICY_TYPE_CAMERA").getInt(null);
            int customPolicy = paramsClass.getField("DEVICE_POLICY_CUSTOM").getInt(null);
            call(builder, "setDevicePolicy", new Class[]{int.class, int.class}, cameraPolicy, customPolicy);
        }
        if (independentLockRequested) {
            // Official SystemApi; scope is this temporary virtual device only.
            int lockState = paramsClass.getField("LOCK_STATE_ALWAYS_UNLOCKED").getInt(null);
            call(builder, "setLockState", new Class[]{int.class}, lockState);
        }
        Object params = call(builder, "build", new Class[]{});
        device = call(CameraProbe.manager(), "createVirtualDevice", new Class[]{int.class, paramsClass}, associationId, params);
        deviceId = (Integer) call(device, "getDeviceId", new Class[]{});
        if (deviceId <= 0) throw new IllegalStateException("Expected a non-default virtual device");
        log("device_id", deviceId);
        registerActivityListener();
    }

    static boolean isOwnedDisplayId(int displayId, int primaryOwnedDisplayId, Map<Integer, ?> appDisplays) {
        return displayId > Display.DEFAULT_DISPLAY &&
                (displayId == primaryOwnedDisplayId || appDisplays.containsKey(displayId));
    }

    private boolean isOwnedActivityDisplay(int displayId) {
        return isOwnedDisplayId(displayId, primaryOwnedDisplayId, appDisplays);
    }

    // A camera owner is a package, not a display; another foreground window
    // of that package makes routing ambiguous. Only verified scanner routes.
    static int scannerDisplayForOwner(String owner, Map<Integer, String> activities,
                                      int primaryDisplay, Map<Integer, ?> appDisplays) {
        if (!WECHAT.equals(owner) && !ALIPAY.equals(owner)) return -1;
        int target = -1;
        for (Map.Entry<Integer, String> entry : activities.entrySet()) {
            if (!isOwnedDisplayId(entry.getKey(), primaryDisplay, appDisplays)) continue;
            String component = entry.getValue();
            if (component == null || !component.startsWith(owner + "/")) continue;
            if (!isVerifiedScanner(component) || target >= 0) return -1;
            target = entry.getKey();
        }
        return target;
    }

    // Call only under stateLock.
    private int authorizedDesktopScannerLocked() {
        if (!cameraOwnerKnown || requestDriverFailed.get() || streams.isEmpty()) return -1;
        return desktopCameraRouting.enabled()
                ? desktopCameraRouting.authorizedDisplay(cameraOwner, topActivities, primaryOwnedDisplayId, appDisplays)
                : scannerDisplayForOwner(cameraOwner, topActivities, primaryOwnedDisplayId, appDisplays);
    }

    private long markDesktopFrameInvalidLocked() {
        synchronized (cameraLock) { sourceLease.invalidate(); previewInterleave.disable(); }
        return desktopHomeRequested ? ++cameraStateGeneration : -1;
    }

    private void discardObsoleteDesktopFrame(long obsoleteBefore) {
        if (obsoleteBefore < 0) return;
        // Invalidate paint immediately; release the old Bitmap on the painter
        // executor so a CameraManager/ActivityListener callback stays cheap.
        requestPaint();
        if (!clearPending.compareAndSet(false, true)) return;
        try {
            painter.execute(() -> {
                clearPending.set(false);
                Bitmap obsolete = null;
                long latestInvalidation = cameraStateGeneration;
                synchronized (cameraLock) {
                    if ((cameraFrame != null || cameraSolidColor != null) && frameStateGeneration < latestInvalidation) {
                        obsolete = cameraFrame;
                        cameraFrame = null;
                        cameraSolidColor = null;
                        frameStateGeneration = -1;
                        cameraPaintTiming.invalidate();
                    }
                }
                if (obsolete != null) obsolete.recycle();
            });
        } catch (RejectedExecutionException closed) {
            clearPending.set(false); // shutdown owns the Bitmap
        }
    }

    private void registerActivityListener() throws Exception {
        Class<?> listenerClass = Class.forName("android.companion.virtual.VirtualDeviceManager$ActivityListener");
        Object listener = Proxy.newProxyInstance(listenerClass.getClassLoader(), new Class[]{listenerClass},
                (proxy, method, args) -> {
                    if (method.getDeclaringClass() == Object.class) {
                        if ("hashCode".equals(method.getName())) return System.identityHashCode(proxy);
                        if ("equals".equals(method.getName())) return proxy == args[0];
                        return "006IDC owned activity listener";
                    }
                    if (args == null || args.length < 1 || !(args[0] instanceof Integer)) return null;
                    if (stopping) return null;
                    int id = (Integer) args[0];
                    boolean changed = false;
                    long invalidation = -1;
                    synchronized (stateLock) {
                        boolean owned = isOwnedActivityDisplay(id);
                        boolean early = !owned && primaryOwnedDisplayId < 0 && id > Display.DEFAULT_DISPLAY;
                        if (!owned && !early) return null;
                        if ("onTopActivityChanged".equals(method.getName()) && args.length >= 2 && args[1] instanceof ComponentName) {
                            String component = ((ComponentName) args[1]).flattenToString();
                            if (component != null && !component.isEmpty()) {
                                if (owned) changed = !component.equals(topActivities.put(id, component));
                                else if (earlyTopActivities.containsKey(id) || earlyTopActivities.size() < MAX_EARLY_ACTIVITY_IDS)
                                    earlyTopActivities.put(id, component);
                            }
                        } else if ("onDisplayEmpty".equals(method.getName())) {
                            if (owned) changed = topActivities.remove(id) != null;
                            else earlyTopActivities.remove(id);
                        }
                        if (changed) invalidation = markDesktopFrameInvalidLocked();
                    }
                    discardObsoleteDesktopFrame(invalidation);
                    return null;
                });
        call(device, "addActivityListener", new Class[]{Executor.class, listenerClass}, callbacks, listener);
        activityListener = listener;
    }

    private void grantSupportedCameras() throws Exception {
        synchronized (cameraPermissionLock) {
            Context virtualContext = context.createDeviceContext(deviceId);
            if (virtualContext.getDeviceId() != deviceId) throw new IllegalStateException("Virtual context mismatch");
            PackageManager pm = virtualContext.getPackageManager();
            for (String pkg : cameraPackagesForMode(desktopHomeRequested)) {
                try { pm.getPackageInfo(pkg, 0); }
                catch (PackageManager.NameNotFoundException absent) { continue; }
                pm.getClass().getMethod("grantRuntimePermission", String.class, String.class, UserHandle.class)
                        .invoke(pm, pkg, "android.permission.CAMERA", Process.myUserHandle());
                grantedCameraPackages.add(pkg);
                log("camera_permission", "granted_virtual_device_only");
            }

        }
    }

    private void revokeUnusedDesktopCamera(String pkg) throws Exception {
        synchronized (cameraPermissionLock) {
            if (pkg == null) return;
            synchronized (stateLock) {if (desktopCameraRouting.uses(pkg)) return;}
            if (!grantedCameraPackages.contains(pkg)) return;
            Context scoped=context.createDeviceContext(deviceId);
            if (scoped.getDeviceId()!=deviceId) throw new IOException("Virtual camera permission scope changed");
            scoped.getPackageManager().getClass().getMethod("revokeRuntimePermission",String.class,String.class,UserHandle.class)
                    .invoke(scoped.getPackageManager(),pkg,"android.permission.CAMERA",Process.myUserHandle());
            grantedCameraPackages.remove(pkg);

        }
    }

    private void revokeUnusedDesktopCameras() throws Exception {
        synchronized (cameraPermissionLock) {
            Exception failure=null;
            // Retry previously uncertain revokes even after their binding was removed.
            Set<String> unused;
            synchronized (stateLock) {unused=desktopCameraRouting.unusedPackages(grantedCameraPackages);}
            for(String pkg:unused) {
                try {revokeUnusedDesktopCamera(pkg);}
                catch(Exception cleanup) {if(failure==null) failure=cleanup;else failure.addSuppressed(cleanup);}
            }
            if(failure!=null) throw failure;
        }
    }

    private byte[] configureDesktopCamera(byte[] body) throws Exception {
        synchronized (cameraPermissionLock) {
            if (stopping) throw new IOException("Camera session is stopping");
            DesktopCameraRouting.Request request=DesktopCameraRouting.Request.parse(body);
            if (!desktopHomeRequested || mirrorOnlyRequested) throw new IOException("Desktop camera mode unavailable");
            if (request.action==2) {
                long invalidation;
                synchronized (stateLock) {
                    if (desktopCameraRouting.enabled()) return new byte[]{1};
                    if (!streams.isEmpty()) throw new IOException("Close the current camera before selecting its source");
                    desktopCameraRouting.enable();invalidation=markDesktopFrameInvalidLocked();
                }
                discardObsoleteDesktopFrame(invalidation);
                // Retire compatibility grants before accepting dynamic selections.
                revokeSupportedCameras();
                return new byte[]{1};
            }
            ownedDisplay(request.display);
            synchronized (stateLock) {if (!desktopCameraRouting.enabled()) throw new IOException("Desktop camera mode was not selected");}
            boolean requested=false;
            if (request.action==1) {
                JSONArray catalog=new JSONArray(new String(LauncherCatalog.query(context,request.packageName),StandardCharsets.UTF_8));
                boolean launchable=false;
                for (int i=0;i<catalog.length();i++) if(request.packageName.equals(catalog.getJSONObject(i).getString("packageName"))) {launchable=true;break;}
                if (!launchable) throw new IOException("Camera application is not in the primary-user launcher catalog");
                android.content.pm.PackageInfo info=context.getPackageManager().getPackageInfo(request.packageName,PackageManager.GET_PERMISSIONS);
                if (info.requestedPermissions!=null) for(String permission:info.requestedPermissions)
                    if ("android.permission.CAMERA".equals(permission)) requested=true;
            }
            synchronized (stateLock) {
                if (request.action==1 && requested && request.packageName.equals(desktopCameraRouting.snapshot().get(request.display)) &&
                        grantedCameraPackages.contains(request.packageName)) return new byte[]{1};
            }
            long invalidation;
            synchronized (stateLock) {
                desktopCameraRouting.clear(request.display);invalidation=markDesktopFrameInvalidLocked();
            }
            discardObsoleteDesktopFrame(invalidation);revokeUnusedDesktopCameras();
            if (request.action==0) return new byte[]{0};
            if (!requested) return new byte[]{2};
            Context scoped=context.createDeviceContext(deviceId);
            if (scoped.getDeviceId()!=deviceId) throw new IOException("Virtual camera permission scope changed");
            PackageManager pm=scoped.getPackageManager();
            DesktopCameraRouting.grantAndBind(() -> {
                // Record before Binder: an uncertain reply still needs compensating revoke.
                grantedCameraPackages.add(request.packageName);
                pm.getClass().getMethod("grantRuntimePermission",String.class,String.class,UserHandle.class)
                        .invoke(pm,request.packageName,"android.permission.CAMERA",Process.myUserHandle());
            }, () -> {
                long changed;
                synchronized (stateLock) {
                    if (stopping || !isOwnedActivityDisplay(request.display)) throw new IOException("Camera window is no longer owned");
                    desktopCameraRouting.bind(request.display,request.packageName);changed=markDesktopFrameInvalidLocked();
                }
                discardObsoleteDesktopFrame(changed);
            }, () -> revokeUnusedDesktopCamera(request.packageName));
            return new byte[]{1};

        }
    }

    private void revokeSupportedCameras() throws Exception {
        synchronized (cameraPermissionLock) {
            if (grantedCameraPackages.isEmpty() || deviceId <= 0) return;
            Context virtualContext = context.createDeviceContext(deviceId);
            if (virtualContext.getDeviceId() != deviceId) throw new IllegalStateException("Virtual context mismatch on revoke");
            PackageManager pm = virtualContext.getPackageManager();
            Exception firstFailure = null;
            for (String pkg : new HashSet<>(grantedCameraPackages)) {
                try {
                    pm.getClass().getMethod("revokeRuntimePermission", String.class, String.class, UserHandle.class)
                            .invoke(pm, pkg, "android.permission.CAMERA", Process.myUserHandle());
                    grantedCameraPackages.remove(pkg);
                    log("camera_permission", "revoked_virtual_device_only");
                } catch (Exception failure) {
                    if (firstFailure == null) firstFailure = failure;
                    else firstFailure.addSuppressed(failure);
                }
            }
            if (firstFailure != null) throw firstFailure;

        }
    }

    private void createVirtualCamera() throws Exception {
        Class<?> callbackClass = Class.forName("android.companion.virtual.camera.VirtualCameraCallback");
        Object callback = Proxy.newProxyInstance(callbackClass.getClassLoader(), new Class[]{callbackClass},
                (proxy, method, args) -> {
                    if (method.getDeclaringClass() == Object.class) {
                        if ("hashCode".equals(method.getName())) return System.identityHashCode(proxy);
                        if ("equals".equals(method.getName())) return proxy == args[0];
                        return "006IDC live camera callback";
                    }
                    if ("onStreamConfigured".equals(method.getName())) {
                        long invalidation = -1;
                        synchronized (stateLock) {
                            Surface previous = streams.put((Integer) args[0], (Surface) args[1]);
                            if (previous != args[1]) {
                                streamGeneration++;
                                invalidation = markDesktopFrameInvalidLocked();
                            }
                        }
                        discardObsoleteDesktopFrame(invalidation);
                        requestPaint();
                    } else if ("onProcessCaptureRequest".equals(method.getName()) && desktopHomeRequested && args != null && args.length >= 1 && args[0] instanceof Integer) {
                        requestDesktopFrame((Integer) args[0]);
                    } else if ("onStreamClosed".equals(method.getName())) {
                        long invalidation = -1;
                        synchronized (stateLock) {
                            if (streams.remove((Integer) args[0]) != null) {
                                streamGeneration++;
                                invalidation = markDesktopFrameInvalidLocked();
                            }
                        }
                        discardObsoleteDesktopFrame(invalidation);
                    }
                    return null;
                });
        Class<?> configClass = Class.forName("android.companion.virtual.camera.VirtualCameraConfig");
        Object builder = Class.forName(configClass.getName() + "$Builder").getConstructor(String.class)
                .newInstance("006IDC live desktop camera");
        call(builder, "addStreamConfig", new Class[]{int.class, int.class, int.class, int.class},
                1280, 720, PixelFormat.RGBA_8888, 30);
        call(builder, "setLensFacing", new Class[]{int.class}, CameraMetadata.LENS_FACING_BACK);
        call(builder, "setSensorOrientation", new Class[]{int.class}, 90);
        // Preserve lifecycle/request order on a separate bounded serial lane;
        // neither Canvas work nor the activity callback backlog runs here.
        call(builder, "setVirtualCameraCallback", new Class[]{Executor.class, callbackClass}, cameraCallbacks, callback);
        Object config = call(builder, "build", new Class[]{});
        log("setup_phase", "camera_register");
        camera = call(device, "createVirtualCamera", new Class[]{configClass}, config);
        log("setup_phase", "camera_identifier");
        virtualCameraId = (String) call(camera, "getId", new Class[]{});
        log("camera_id", virtualCameraId);
        log("setup_phase", "camera_owner_watch");
        watchCameraOwner();
        painter.scheduleWithFixedDelay(() -> {
            // Arrival-driven drawing already supplies the active 30fps stream.
            // Only refresh idle content; otherwise an unrelated tick could post
            // an old image just before the next arrival and add camera backpressure.
            if (previewInterleaveActive() || System.nanoTime() - lastCameraUpdateNanos >= TimeUnit.MILLISECONDS.toNanos(66))
                requestPaint();
        }, 33, 33, TimeUnit.MILLISECONDS);
    }

    private void watchCameraOwner() {
        // Shell on Android 16 may hold this SystemApi permission. If an OEM
        // withholds it, owner stays unknown and the Mac must not infer an owner.
        ownerStatus = "context";
        Context virtualContext;
        try { virtualContext = context.createDeviceContext(deviceId); }
        catch (RuntimeException unavailable) { ownerStatus = "context_error"; return; }
        try {
            if (virtualContext == null || virtualContext.getDeviceId() != deviceId
                    || virtualContext.getAttributionSource().getDeviceId() != deviceId
                    || !"com.android.shell".equals(virtualContext.getAttributionSource().getPackageName())) {
                ownerStatus = "context_mismatch"; return;
            }
        } catch (RuntimeException unavailable) { ownerStatus = "context_error"; return; }
        if (virtualCameraId == null || virtualCameraId.isEmpty()) {
            ownerStatus = "camera_id_missing"; return;
        }
        try {
            if (virtualContext.checkSelfPermission(CAMERA_OWNER_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
                ownerStatus = "permission_denied"; return;
            }
        } catch (RuntimeException unavailable) { ownerStatus = "permission_error"; return; }
        CameraManager manager;
        try {
            // ContextWrapper.getSystemService() delegates to the underlying
            // system Context, whose CameraManager is bound to package "android".
            // CameraManager's @hide Context constructor is the framework's
            // actual service constructor. Bind it to this shell-owned virtual
            // Context so attribution package and UID agree on every query.
            manager = CameraManager.class.getConstructor(Context.class).newInstance(virtualContext);
        } catch (Exception unavailable) {
            ownerStatus = "manager_error";
            return;
        }
        ownerStatus = "policy";
        try {
            Class<?> paramsClass = Class.forName("android.companion.virtual.VirtualDeviceParams");
            int cameraPolicy = paramsClass.getField("POLICY_TYPE_CAMERA").getInt(null);
            int customPolicy = paramsClass.getField("DEVICE_POLICY_CUSTOM").getInt(null);
            int actualPolicy = (Integer) call(CameraProbe.manager(), "getDevicePolicy",
                    new Class[]{int.class, int.class}, deviceId, cameraPolicy);
            if (actualPolicy != customPolicy) { ownerStatus = "policy_not_custom"; return; }
        } catch (Exception unavailable) { ownerStatus = "policy_error"; return; }
        String mapped = null;
        boolean probeFailed = false;
        CameraCharacteristics.Key<Integer> owningDeviceKey =
                new CameraCharacteristics.Key<>("android.info.deviceId", int.class);
        Method characteristicsWithoutRotation;
        try {
            // Android 16's public one-argument overload first reads desktop
            // rotation flags through a system-context Settings resolver, which
            // is unrelated to camera identity and fails in this shell process.
            // The framework's @TestApi overload skips that path while querying
            // the same CameraService with this virtual Context's attribution.
            characteristicsWithoutRotation = CameraManager.class.getMethod(
                    "getCameraCharacteristics", String.class, boolean.class);
        } catch (NoSuchMethodException unavailable) {
            ownerStatus = "characteristic_api_unavailable";
            return;
        }
        probe: for (int attempt = 0; attempt < 3 && mapped == null; attempt++) {
            ownerStatus = "ids";
            String[] ids;
            try { ids = manager.getCameraIdList(); }
            catch (Exception unavailable) {
                ownerStatus = "ids_error";
                probeFailed = true; break;
            }
            ownerVisibleCameraCount = ids.length;
            ownerBackCameraCount = 0;
            ownerDeviceKeyListedCount = 0;
            ownerDeviceIdPresentCount = 0;
            ownerDeviceIdMatchCount = 0;
            Map<String, Integer> facing = new HashMap<>();
            Map<String, Integer> owningDevices = new HashMap<>();
            ownerStatus = "characteristic";
            for (String id : ids) {
                CameraCharacteristics properties;
                try { properties = (CameraCharacteristics) characteristicsWithoutRotation.invoke(manager, id, false); }
                catch (Exception unavailable) {
                    ownerStatus = "characteristic_lookup_error";
                    Throwable failure = unavailable instanceof InvocationTargetException
                            && unavailable.getCause() != null ? unavailable.getCause() : unavailable;
                    ownerErrorClass = failure.getClass().getSimpleName().replaceAll("[^A-Za-z0-9_]", "");
                    String detail = failure.getMessage();
                    if (detail != null) {
                        detail = detail.replaceAll("[\\p{Cntrl}]", " ")
                                .replaceAll("(?i)\\b[0-9a-f]{12,}\\b", "[redacted]")
                                .replaceAll("[A-Za-z0-9_-]{24,}", "[redacted]")
                                .replaceAll("https?://\\S+|/(?:[^\\s/]+/)+[^\\s/]+", "[redacted]")
                                .replaceAll("\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b", "[redacted]");
                        ownerErrorDetail = detail.substring(0, Math.min(120, detail.length()));
                    }
                    probeFailed = true; break probe;
                }
                List<CameraCharacteristics.Key<?>> keys;
                try { keys = properties.getKeys(); }
                catch (Exception unavailable) {
                    ownerStatus = "characteristic_keys_error";
                    probeFailed = true; break probe;
                }
                if (!keys.contains(CameraCharacteristics.LENS_FACING)) {
                    ownerStatus = "lens_key_missing"; probeFailed = true; break probe;
                }
                Integer direction;
                try { direction = properties.get(CameraCharacteristics.LENS_FACING); }
                catch (Exception unavailable) {
                    ownerStatus = "lens_read_error";
                    probeFailed = true; break probe;
                }
                facing.put(id, direction);
                if (Integer.valueOf(CameraMetadata.LENS_FACING_BACK).equals(direction)) ownerBackCameraCount++;
                // getKeys() is filtered through availableCharacteristicsKeys;
                // a framework-injected hidden tag can be readable even when
                // absent from that advertised list. Read it directly, while
                // keeping null/invalid values fail-closed.
                if (keys.contains(owningDeviceKey)) ownerDeviceKeyListedCount++;
                Integer owningDevice;
                try { owningDevice = properties.get(owningDeviceKey); }
                catch (Exception unavailable) {
                    ownerStatus = "device_id_read_error";
                    probeFailed = true; break probe;
                }
                if (owningDevice != null) {
                    ownerDeviceIdPresentCount++;
                    owningDevices.put(id, owningDevice);
                    if (owningDevice == deviceId) ownerDeviceIdMatchCount++;
                }
            }
            mapped = verifiedMappedBackCameraId(deviceId, true, ids, facing, owningDevices);
            if (mapped == null && attempt < 2) {
                try { Thread.sleep(50); }
                catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt(); ownerStatus = "probe_interrupted";
                    probeFailed = true; break;
                }
            }
        }
        if (mapped == null && !probeFailed) ownerStatus = "mapped_id_unverified";
        final String verifiedMappedId = mapped;
        final boolean canAuthorizeOwner = mapped != null && !probeFailed;
        if (canAuthorizeOwner) ownerStatus = "register";
        CameraManager.AvailabilityCallback listener = new CameraManager.AvailabilityCallback() {
            // Android 16 SystemApi; public SDK stubs omit these methods. The
            // runtime framework invokes the matching virtual methods.
            public void onCameraOpened(String cameraId, String packageId) {
                boolean matched = isOwnedCameraEvent(virtualCameraId, verifiedMappedId, cameraId);
                if (!canAuthorizeOwner || !matched) return;
                long invalidation;
                synchronized (stateLock) {
                    cameraOwner = packageId != null && packageId.matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+")
                            ? packageId : null;
                    ownerGeneration++;
                    invalidation = markDesktopFrameInvalidLocked();
                }
                discardObsoleteDesktopFrame(invalidation);
            }
            public void onCameraClosed(String cameraId) {
                boolean matched = isOwnedCameraEvent(virtualCameraId, verifiedMappedId, cameraId);
                if (!canAuthorizeOwner || !matched) return;
                long invalidation;
                synchronized (stateLock) {
                    cameraOwner = null;
                    ownerGeneration++;
                    invalidation = markDesktopFrameInvalidLocked();
                }
                discardObsoleteDesktopFrame(invalidation);
            }
        };
        try {
            manager.registerAvailabilityCallback(callbacks, listener);
            cameraManager = manager;
            cameraOwnerListener = listener;
            synchronized (stateLock) {
                cameraOwnerKnown = canAuthorizeOwner;
                if (canAuthorizeOwner) ownerStatus = "ready";
            }
        } catch (RuntimeException unavailable) {
            try { manager.unregisterAvailabilityCallback(listener); } catch (RuntimeException ignored) {}
            synchronized (stateLock) {
                cameraOwner = null; cameraOwnerKnown = false;
                ownerStatus = "register_error";
            }
        }
    }

    private void requestDesktopFrame(int streamId) {
        final Surface requested;
        final CameraRequestScope scope;
        synchronized (stateLock) {
            requested=streams.get(streamId);
            scope=new CameraRequestScope(streamGeneration,cameraStateGeneration,currentEpoch);
        }
        if (stopping || requestDriverFailed.get() || requested == null) return;
        cameraRequests.incrementAndGet();
        int count = requestPaints.incrementAndGet();
        if (count > 128) {requestPaints.decrementAndGet();requestOverflows.incrementAndGet();failRequestDriver();return;}
        requestPeak.accumulateAndGet(count, Math::max);
        long requestedAt = System.nanoTime();
        try {
            painter.execute(() -> {
                try {
                    if (stopping || streams.get(streamId) != requested) {requestIdentitySkips.incrementAndGet();return;}
                    long before = requestPosts.get();paint(requested, requestedAt);
                    boolean surfaceValid=requested.isValid();
                    synchronized (stateLock) {
                        boolean current=streams.get(streamId)==requested && scope.matches(streamGeneration,cameraStateGeneration,currentEpoch);
                        CameraRequestOutcome.Value outcome=CameraRequestOutcome.classify(stopping,current,surfaceValid,requestPosts.get()!=before);
                        if (outcome==CameraRequestOutcome.Value.RETIRED) requestIdentitySkips.incrementAndGet();
                        else if (outcome==CameraRequestOutcome.Value.FAILED) {
                            requestPostFailures.incrementAndGet();
                            if (streams.size()==1) {
                                long postsBeforeRecovery=requestPosts.get();
                                boolean queued=postFailureChecks.schedule(painter,scope,()->{
                                    synchronized(stateLock) {
                                        if (!stopping && !requestDriverFailed.get() && streams.size()==1 && streams.get(streamId)==requested &&
                                            scope.matches(streamGeneration,cameraStateGeneration,currentEpoch) && requested.isValid() &&
                                            cameraOwnerKnown && cameraOwner!=null && requestPosts.get()==postsBeforeRecovery) failRequestDriver();
                                    }
                                });
                                if (!queued && !stopping) failRequestDriver();
                            } else failRequestDriver();
                        }
                    }
                } finally {requestPaints.decrementAndGet();}
            });
        } catch (RejectedExecutionException closed) {requestPaints.decrementAndGet();requestRejected.incrementAndGet();failRequestDriver();}
    }

    private void requestPaint() {
        // Desktop camera production follows actual Camera2 demand. Control
        // updates invalidate memory immediately; their ACK drains prior paints.
        if (desktopHomeRequested) return;
        if (stopping || !paintPending.compareAndSet(false, true)) return;
        try {
            painter.execute(() -> {
                // Release the slot before drawing: an arrival during a slow
                // lockCanvas/draw/post can request exactly one subsequent pass.
                // That pass reads the latest cameraFrame, never a captured Bitmap.
                paintPending.set(false);
                if (stopping) return;
                for (Surface surface : streams.values()) paint(surface);
            });
        } catch (RejectedExecutionException closed) {
            paintPending.set(false); // shutdown raced with a callback/command
        }
    }

    private void paint(Surface surface) {paint(surface, 0);}

    private void paint(Surface surface, long requestedAt) {
        if (stopping || (desktopHomeRequested && requestDriverFailed.get()) || !surface.isValid()) return;
        Canvas canvas = null;
        CameraPaintTiming.Ticket paintedTicket = null;
        CameraSourcePostFence.Ticket sourcePost = null;
        long lockBegan = System.nanoTime(), locked = 0, drawn = 0, paintedGeneration = -1;
        boolean drewSource = false;
        CameraPreviewInterleave.Phase previewPhase = CameraPreviewInterleave.Phase.UNCHANGED;
        long paintedEpoch = -1;
        try {
            canvas = surface.lockCanvas(null);
            locked = System.nanoTime();
            canvas.drawColor(Color.WHITE);
            synchronized (cameraLock) {
                boolean sourceCurrent = cameraFrame != null && cameraSolidColor == null && frameStateGeneration == cameraStateGeneration;
                paintedEpoch = currentEpoch;
                previewPhase = cameraSolidColor == null
                        ? previewInterleave.next(cameraStateGeneration, paintedEpoch, sourceCurrent, sourceAcceptedNanos, System.nanoTime())
                        : CameraPreviewInterleave.Phase.UNCHANGED;
                boolean keyed = previewPhase == CameraPreviewInterleave.Phase.KEY;
                boolean solid = cameraSolidColor != null && desktopHomeRequested && frameStateGeneration == cameraStateGeneration;
                if (keyed || solid || (cameraFrame != null && (!desktopHomeRequested || frameStateGeneration == cameraStateGeneration))) {
                    // Register before any source/solid draw: an exception may
                    // still leave source pixels on the Canvas that finally posts.
                    if (!keyed) sourcePost = sourcePostFence.begin();
                    paintedTicket = keyed ? null : cameraPaintTiming.current();
                    paintedGeneration = keyed ? cameraStateGeneration : frameStateGeneration;
                    int width = canvas.getWidth();
                    int height = canvas.getHeight();
                    canvas.save();
                    canvas.translate(width / 2f, height / 2f);
                    canvas.rotate(-90);
                    int portraitWidth = height, portraitHeight = width;
                    // Match the existing 720x1280 calibration PNG's rotation,
                    // aspect fit, rounding and white margins exactly.
                    int sourceWidth = keyed || solid ? 720 : cameraFrame.getWidth();
                    int sourceHeight = keyed || solid ? 1280 : cameraFrame.getHeight();
                    float scale = Math.min((float) portraitWidth / sourceWidth, (float) portraitHeight / sourceHeight);
                    int drawWidth = Math.round(sourceWidth * scale);
                    int drawHeight = Math.round(sourceHeight * scale);
                    Rect destination = new Rect(-drawWidth / 2, -drawHeight / 2,
                            drawWidth / 2, drawHeight / 2);
                    Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
                    if (keyed) {
                        if (previewPattern == null) throw new IllegalStateException("Native preview pattern unavailable");
                        for (int row = 0; row < NativePreviewPattern.ROWS; row++) {
                            for (int column = 0; column < NativePreviewPattern.COLUMNS; column++) {
                                paint.setColor(0xff000000 | previewPattern.blue(column, row));
                                float left = -drawWidth / 2f + (float) drawWidth * column / NativePreviewPattern.COLUMNS;
                                float top = -drawHeight / 2f + (float) drawHeight * row / NativePreviewPattern.ROWS;
                                canvas.drawRect(left, top, -drawWidth / 2f + (float) drawWidth * (column + 1) / NativePreviewPattern.COLUMNS,
                                        -drawHeight / 2f + (float) drawHeight * (row + 1) / NativePreviewPattern.ROWS, paint);
                            }
                        }
                    } else if (solid) {
                        paint.setColor(cameraSolidColor);
                        canvas.drawRect(destination, paint);
                    } else canvas.drawBitmap(cameraFrame, null, destination, paint);
                    canvas.restore();
                    drawn = System.nanoTime(); drewSource = !keyed;
                }
            }
        } catch (Exception e) {
            if (!stopping) log("paint_error", e.toString());
        } finally {
            if (canvas != null) try {
                surface.unlockCanvasAndPost(canvas);
                if (requestedAt > 0) recordRequestedPost(requestedAt);
                synchronized (cameraLock) { previewInterleave.posted(previewPhase, paintedGeneration, paintedEpoch); }
                if (drewSource && (!desktopHomeRequested || paintedGeneration == cameraStateGeneration))
                    cameraPaintTiming.posted(paintedTicket, lockBegan, locked, drawn, System.nanoTime());
            } catch (Exception ignored) {}
            // Complete only after unlock/post and its metadata attempt returned.
            sourcePostFence.complete(sourcePost);
        }
    }

    private void createVirtualDisplay() throws Exception {
        imageThread = new HandlerThread("006IDC-live-display");
        imageThread.start();
        android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
        DisplayManager manager = context.getSystemService(DisplayManager.class);
        android.view.Display primary = manager.getDisplay(android.view.Display.DEFAULT_DISPLAY);
        primary.getRealMetrics(metrics);
        displayWidth = metrics.widthPixels;
        displayHeight = metrics.heightPixels;
        displayDpi = metrics.densityDpi;
        if (balancedDisplayRequested) {
            DesktopDisplayGeometry geometry = DesktopDisplayGeometry.fromPrimary(displayWidth, displayHeight, displayDpi);
            displayWidth = geometry.width; displayHeight = geometry.height; displayDpi = geometry.dpi;
        }
        if (displayWidth <= 0 || displayHeight <= 0 || displayWidth > 4096 || displayHeight > 4096 || displayDpi <= 0)
            throw new IllegalStateException("Invalid primary display geometry");
        displayReader = ImageReader.newInstance(displayWidth, displayHeight, PixelFormat.RGBA_8888, 3);
        // Keep one GPU-backed image. Read pixels only for an explicit screenshot;
        // scrcpy consumes the display independently, with no full-frame CPU copy.
        displayReader.setOnImageAvailableListener(reader -> {
            try {
                Image image = reader.acquireLatestImage();
                if (image == null) return;
                synchronized (frameLock) {
                    if (stopping) { image.close(); return; }
                    if (latestDisplayImage != null) latestDisplayImage.close();
                    latestDisplayImage = image;
                }
            } catch (Exception e) {
                if (!stopping) log("display_error", e.toString());
            }
        }, new Handler(imageThread.getLooper()));
        int flags = DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY |
                CameraProbe.DISPLAY_SUPPORTS_TOUCH | CameraProbe.DISPLAY_TRUSTED | CameraProbe.DISPLAY_OWN_FOCUS;
        if (desktopHomeRequested) {
            // Android 16 SystemApi: HOME may launch only on a trusted display
            // with its own content and system decorations. No physical HOME is moved.
            Class<?> configClass = Class.forName("android.hardware.display.VirtualDisplayConfig");
            Object builder = Class.forName(configClass.getName() + "$Builder")
                    .getConstructor(String.class, int.class, int.class, int.class)
                    .newInstance("006IDC Android desktop", displayWidth, displayHeight, displayDpi);
            call(builder, "setFlags", new Class[]{int.class}, flags | DISPLAY_SYSTEM_DECORATIONS);
            call(builder, "setSurface", new Class[]{Surface.class}, displayReader.getSurface());
            call(builder, "setHomeSupported", new Class[]{boolean.class}, true);
            Object config = call(builder, "build", new Class[]{});
            if (!Boolean.TRUE.equals(call(config, "isHomeSupported", new Class[]{})))
                throw new UnsupportedOperationException("Android HOME on a virtual display is disabled on this phone");
            display = (VirtualDisplay) call(device, "createVirtualDisplay",
                    new Class[]{configClass, Executor.class, VirtualDisplay.Callback.class},
                    config, callbacks, new VirtualDisplay.Callback() {});
        } else {
            display = (VirtualDisplay) call(device, "createVirtualDisplay",
                    new Class[]{int.class, int.class, int.class, Surface.class, int.class, Executor.class, VirtualDisplay.Callback.class},
                    displayWidth, displayHeight, displayDpi, displayReader.getSurface(), flags,
                    callbacks, new VirtualDisplay.Callback() {});
        }
        // On failure main's finally releases this display, reader, camera and
        // virtual device before exiting; do not serve an unverified session.
        if (display == null || display.getDisplay() == null || !display.getDisplay().isValid())
            throw new IllegalStateException("Virtual display creation failed");
        int createdId = display.getDisplay().getDisplayId();
        if (createdId <= Display.DEFAULT_DISPLAY)
            throw new IllegalStateException("Virtual display must not be the primary display");
        synchronized (stateLock) {
            primaryOwnedDisplayId = createdId;
            String earlyHome = earlyTopActivities.get(createdId);
            if (earlyHome != null) topActivities.put(createdId, earlyHome);
            earlyTopActivities.clear();
        }
        boolean independentLockReady = verifyIndependentLock(display);
        wakeIndependentDisplay(display);
        log("independent_lock_ready", independentLockReady ? 1 : 0);
        log("display_id", display.getDisplay().getDisplayId());
        log("display_width", displayWidth); log("display_height", displayHeight); log("display_dpi", displayDpi);
    }

    private byte[] applications(byte[] query) throws Exception {
        return LauncherCatalog.query(context,LauncherPackageQuery.parse(query));
    }

    private byte[] createAppDisplay() throws Exception {
        if (appDisplays.size() >= 4) throw new IOException("At most four app windows are supported");
        ImageReader reader = ImageReader.newInstance(displayWidth, displayHeight, PixelFormat.RGBA_8888, 2);
        VirtualDisplay created = null;
        try {
            // Drain GPU buffers immediately; normal app windows never copy pixels on CPU.
            reader.setOnImageAvailableListener(source -> {
                try (Image image = source.acquireLatestImage()) {} catch (IllegalStateException closed) {}
            }, new Handler(imageThread.getLooper()));
            int flags = DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY |
                    CameraProbe.DISPLAY_SUPPORTS_TOUCH | CameraProbe.DISPLAY_TRUSTED | CameraProbe.DISPLAY_OWN_FOCUS;
            created = (VirtualDisplay) call(device, "createVirtualDisplay",
                    new Class[]{int.class, int.class, int.class, Surface.class, int.class, Executor.class, VirtualDisplay.Callback.class},
                    displayWidth, displayHeight, displayDpi, reader.getSurface(), flags, callbacks, new VirtualDisplay.Callback() {});
            boolean independentLock = verifyIndependentLock(created);
            wakeIndependentDisplay(created);
            int id = created.getDisplay().getDisplayId();
            byte[] response = new JSONObject().put("id", id).put("width", displayWidth).put("height", displayHeight)
                    .put("dpi", displayDpi).put("independentLock", independentLock).toString().getBytes(StandardCharsets.UTF_8);
            appDisplays.put(id, new AppDisplay(created, reader));
            return response;
        } catch (Exception failure) {
            if (created != null) try { created.release(); } catch (Exception cleanup) { failure.addSuppressed(cleanup); }
            try { reader.close(); } catch (Exception cleanup) { failure.addSuppressed(cleanup); }
            throw failure;
        }
    }

    private void releaseAppDisplay(int id) throws IOException {
        AppDisplay owned = appDisplays.get(id);
        if (owned == null) throw new IOException("Display does not belong to this session");
        synchronized (cameraPermissionLock) {
            boolean generic;long sourceInvalidation=-1;
            synchronized (stateLock) {
                generic=desktopCameraRouting.enabled();
                if(generic) {desktopCameraRouting.clear(id);sourceInvalidation=markDesktopFrameInvalidLocked();}
            }
            discardObsoleteDesktopFrame(sourceInvalidation);
            if(generic) try {revokeUnusedDesktopCameras();}
                catch(Exception failure) {throw new IOException("Camera source cleanup failed",failure);}
        }
        stopDirectStream(id);
        owned.close();
        long invalidation = -1;
        synchronized (stateLock) {
            appDisplays.remove(id);
            if (topActivities.remove(id) != null) invalidation = markDesktopFrameInvalidLocked();
        }
        discardObsoleteDesktopFrame(invalidation);
    }

    private VirtualDisplay ownedDisplay(int id) throws IOException {
        if (id <= 0) throw new IOException("A positive owned display is required");
        if (display != null && display.getDisplay() != null && display.getDisplay().getDisplayId() == id) return display;
        AppDisplay owned = appDisplays.get(id);
        if (owned == null) throw new IOException("Display does not belong to this session");
        return owned.display;
    }

    private byte[] startDirectStream(int id) throws Exception {
        if (!independentLockRequested) throw new IOException("Direct video requires independent-lock mode");
        VirtualDisplay target = ownedDisplay(id);
        if (!verifyIndependentLock(target)) throw new IOException("Independent lock policy is not active");
        stopDirectStream(id);
        Surface original = target == display ? displayReader.getSurface() : appDisplays.get(id).reader.getSurface();
        DirectDisplayStream stream = new DirectDisplayStream(target, original, displayWidth, displayHeight, realtimeVideoRequested, () -> {
            if (stopping || ownedDisplay(id) != target || !verifyIndependentLock(target))
                throw new IOException("Direct display is no longer owned and independently unlocked");
        });
        // Register ownership before startup so failed initialization cannot lose
        // a codec/surface whose cleanup has not completed.
        directStreams.put(id, stream);
        try {
            stream.start();
            return new JSONObject().put("display", id).put("socket", stream.socketName).put("token", stream.token)
                    .put("width", displayWidth).put("height", displayHeight).toString().getBytes(StandardCharsets.UTF_8);
        } catch (Exception failure) {
            stream.close();
            try { stream.awaitClosed(); directStreams.remove(id, stream); }
            catch (IOException cleanup) { failure.addSuppressed(cleanup); }
            throw failure;
        }
    }

    private void stopDirectStream(int id) throws IOException {
        ownedDisplay(id); // Even idempotent stops must stay inside this session.
        DirectDisplayStream stream = directStreams.get(id);
        if (stream != null) {
            stream.close(); stream.awaitClosed();
            directStreams.remove(id, stream);
        }
    }

    private static boolean isSupportedImage(byte[] bytes) {
        boolean jpeg = bytes.length >= 3 && (bytes[0] & 255) == 0xff && (bytes[1] & 255) == 0xd8 && (bytes[2] & 255) == 0xff;
        boolean png = bytes.length >= 8 && (bytes[0] & 255) == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e && bytes[3] == 0x47 &&
                bytes[4] == 0x0d && bytes[5] == 0x0a && bytes[6] == 0x1a && bytes[7] == 0x0a;
        return jpeg || png;
    }

    private void setCameraFrame(byte[] bytes) throws IOException { setCameraFrame(bytes, 0, -1, -1, -1); }

    private void setCameraFrame(byte[] bytes, long nativeToken, long nativeEpoch, long nativeCapture, int nativeDisplay) throws IOException {
        if (bytes.length == 0 || bytes.length > MAX_IMAGE_BYTES || !isSupportedImage(bytes))
            throw new IOException("Expected JPEG/PNG, 1..4 MiB");
        long acceptedRevision;
        synchronized (cameraLock) { acceptedRevision = sourceLease.revision(); }
        long acceptedGeneration = -1;
        int acceptedDisplay = -1;
        if (desktopHomeRequested) {
            synchronized (stateLock) {
                // Retain the native-source requirement after an owner invalidates
                // its lease. An old Mac source must not be re-authorized for a
                // different, newly opened camera while its status update is in flight.
                synchronized (cameraLock) {
                    boolean nativeAuthorized = nativeSourceOnly && nativeToken > 0 && sourceLease.current(nativeToken, nativeEpoch, nativeCapture, currentEpoch, cameraStateGeneration)
                            && previewInterleave.active(cameraStateGeneration, currentEpoch);
                    if ((nativeSourceOnly && !nativeAuthorized) || (!nativeSourceOnly && nativeToken > 0))
                        throw new IOException("Native source lease is no longer active");
                }
                acceptedDisplay = authorizedDesktopScannerLocked();
                if (acceptedDisplay <= Display.DEFAULT_DISPLAY)
                    throw new IOException("Desktop camera has no verified scanner owner");
                if (nativeToken > 0 && acceptedDisplay != nativeDisplay)
                    throw new IOException("Native source lease is no longer active");
                acceptedGeneration = cameraStateGeneration;
            }
        }
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0 || bounds.outWidth > MAX_IMAGE_SIDE || bounds.outHeight > MAX_IMAGE_SIDE)
            throw new IOException("Image dimensions must be 1..2048 on each side");
        Bitmap decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        if (decoded == null) throw new IOException("Cannot decode image");
        Bitmap previous = null;
        boolean stale = false;
        if (desktopHomeRequested) {
            // Lock order is stateLock -> cameraLock; paint only takes cameraLock
            // and reads the volatile generation, never the reverse order.
            synchronized (stateLock) {
                stale = cameraStateGeneration != acceptedGeneration || authorizedDesktopScannerLocked() != acceptedDisplay;
                if (!stale) synchronized (cameraLock) {
                    stale = !sourceLease.accepts(acceptedRevision);
                    if (!stale) {
                        previous = cameraFrame;
                        cameraFrame = decoded;
                        sourceAcceptedNanos = System.nanoTime();
                        cameraSolidColor = null;
                        frameStateGeneration = acceptedGeneration;
                        cameraPaintTiming.accept(System.nanoTime());
                    }
                }
            }
        } else synchronized (cameraLock) {
            stale = !sourceLease.accepts(acceptedRevision);
            if (!stale) {
                previous = cameraFrame;
                cameraFrame = decoded;
                sourceAcceptedNanos = System.nanoTime();
                cameraSolidColor = null;
                cameraPaintTiming.accept(System.nanoTime());
            }
        }
        if (stale) {
            decoded.recycle();
            throw new IOException("Desktop camera state changed while decoding frame");
        }
        if (previous != null) previous.recycle();
        lastCameraUpdateNanos = System.nanoTime();
        requestPaint();
    }

    private void setCalibrationFrame(boolean blue) throws IOException {
        if (!desktopHomeRequested || !realtimeVideoRequested || mirrorOnlyRequested)
            throw new IOException("Solid calibration is unavailable");
        Bitmap previous;
        synchronized (stateLock) {
            if (authorizedDesktopScannerLocked() <= Display.DEFAULT_DISPLAY)
                throw new IOException("Desktop camera has no verified scanner owner");
            synchronized (cameraLock) {
                sourceLease.invalidate();
                previous = cameraFrame;
                cameraFrame = null;
                cameraSolidColor = blue ? Color.BLUE : Color.BLACK;
                frameStateGeneration = cameraStateGeneration;
                cameraPaintTiming.accept(System.nanoTime());
            }
        }
        if (previous != null) previous.recycle();
        lastCameraUpdateNanos = System.nanoTime();
        requestPaint();
    }

    private void clearCameraFrame() { clearCameraFrame(false); }

    private CameraSourcePostFence.Ticket clearCameraFrame(boolean keepPreview) {
        final CameraSourcePostFence.Ticket retiredPost;
        synchronized (cameraLock) {
            sourceLease.invalidate();
            if (!keepPreview || !previewInterleave.active(cameraStateGeneration, currentEpoch)) previewInterleave.disable();
            sourceAcceptedNanos = 0;
            retiredPost = sourcePostFence.snapshot();
            Bitmap previous = cameraFrame;
            cameraFrame = null;
            cameraSolidColor = null;
            frameStateGeneration = -1;
            cameraPaintTiming.reset();
            if (previous != null) previous.recycle();
        }
        lastCameraUpdateNanos = System.nanoTime();
        requestPaint();
        return retiredPost;
    }

    private void awaitCameraPaints() throws IOException { CameraPaintBarrier.await(painter); }

    private byte[] previewCalibration(byte[] body) throws Exception {
        if (body.length != 29 || body[4] < 0 || body[4] > 2) throw new IOException("Invalid preview calibration");
        java.nio.ByteBuffer request = java.nio.ByteBuffer.wrap(body);
        int id = request.getInt(); int phase = request.get();
        long epoch = request.getLong(), capture = request.getLong(), token = request.getLong();
        ownedDisplay(id);
        synchronized (stateLock) {
            if (stopping || authorizedDesktopScannerLocked() != id) throw new IOException("Preview owner unavailable");
            synchronized (cameraLock) {
                if (!previewInterleave.active(cameraStateGeneration, currentEpoch) || epoch != currentEpoch
                        || !sourceLease.current(token, epoch, capture, currentEpoch, cameraStateGeneration) || previewPattern == null)
                    throw new IOException("Preview lease changed");
                sourceLease.invalidate();
                Bitmap old = cameraFrame; cameraFrame = null; sourceAcceptedNanos = 0;
                cameraSolidColor = CameraPreviewInterleave.calibrationColor(phase);
                frameStateGeneration = cameraStateGeneration;
                if (old != null) old.recycle();
            }
        }
        lastCameraUpdateNanos = System.nanoTime(); requestPaint();
        return new byte[0];
    }

    private boolean previewInterleaveActive() {
        synchronized (cameraLock) { return previewInterleave.active(cameraStateGeneration, currentEpoch); }
    }

    private byte[] configureNativePreview(byte[] body) throws Exception {
        if (body.length != 29 || body[4] < 0 || body[4] > 2) throw new IOException("Invalid native preview selection");
        java.nio.ByteBuffer request = java.nio.ByteBuffer.wrap(body);
        int id = request.getInt(); int action = request.get(); boolean enable = action == 1;
        long epoch = request.getLong(), capture = request.getLong(), token = request.getLong();
        ownedDisplay(id);
        boolean applied = false;
        CameraSourcePostFence.Ticket retiredPost = null;
        synchronized (stateLock) {
            synchronized (cameraLock) {
                if (action == 2) {
                    if (!sourceLease.current(token, epoch, capture, currentEpoch, cameraStateGeneration)
                            || authorizedDesktopScannerLocked() != id) throw new IOException("Native preview lease changed");
                } else if (enable) {
                    if (token != 0 || epoch != currentEpoch || capture != cameraStateGeneration || stopping
                            || !desktopHomeRequested || !realtimeVideoRequested || mirrorOnlyRequested
                            || !desktopCameraRouting.enabled() || streams.size() != 1 || authorizedDesktopScannerLocked() != id)
                        throw new IOException("Native preview has no unambiguous camera owner");
                    token = sourceLease.begin(epoch, capture);
                    Bitmap old = cameraFrame; cameraFrame = null; sourceAcceptedNanos = 0;
                    cameraSolidColor = Color.BLACK; frameStateGeneration = cameraStateGeneration;
                    if (old != null) old.recycle();
                    previewPattern = new NativePreviewPattern();
                    previewInterleave.enable(cameraStateGeneration, currentEpoch); nativeSourceOnly = true;
                    applied = true;
                } else if (sourceLease.end(token, epoch, capture, currentEpoch, cameraStateGeneration)) {
                    previewInterleave.disable(); nativeSourceOnly = false; applied = true;
                }
            }
            // Clear under the same state lock as selection; a later enable
            // cannot be cleared by a retired disable after it took ownership.
            if (!enable && applied) retiredPost=clearCameraFrame(false);
        }
        // A retired overlay cannot erase a newer preview on the same display.
        if (action != 2 && applied) {
            if (!enable && desktopHomeRequested) sourcePostFence.await(retiredPost);
            else awaitCameraPaints();
        }
        synchronized (cameraLock) {
            return new JSONObject().put("applied", applied).put("token", token)
                    .put("enabled", previewInterleave.active(cameraStateGeneration, currentEpoch))
                    .put("keyPosts", previewInterleave.keyPosts()).put("sourcePosts", previewInterleave.sourcePosts())
                    .toString().getBytes(StandardCharsets.UTF_8);
        }
    }

    private String sleepFailureStage = "not_requested";

    private byte[] prepareOwnedDeviceShutdown() throws Exception {
        // Bound to the authenticated session's retained object, with no display
        // ID supplied by the caller. This does not navigate or finish app pages.
        sleepFailureStage = "verify_device";
        final Object owned = device;
        if (stopping || owned == null || deviceId <= 0 || display == null ||
                display.getDisplay() == null || !display.getDisplay().isValid() ||
                (Integer) call(owned, "getDeviceId", new Class[]{}) != deviceId)
            throw new IOException("Owned virtual device is unavailable");
        final int primaryBefore = primaryDisplayState();
        // A virtual display can remain logically ON while it still has an
        // output Surface on this ROM. Drain owned encoders before detaching
        // only our retained displays; no display is released or task finished.
        sleepFailureStage = "stop_owned_streams";
        for (Integer id : new HashSet<>(directStreams.keySet())) stopDirectStream(id);
        sleepFailureStage = "detach_owned_surfaces";
        if (display != null) display.setSurface(null);
        for (AppDisplay app : appDisplays.values()) app.display.setSurface(null);
        sleepFailureStage = "sleep_api";
        call(owned, "goToSleep", new Class[]{});
        sleepFailureStage = "wait_owned_displays_off";
        final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        boolean off;
        do {
            if (display.getDisplay() == null || !display.getDisplay().isValid())
                throw new IOException("Owned display became invalid");
            off = display.getDisplay().getState() == Display.STATE_OFF;
            for (AppDisplay app : appDisplays.values()) {
                if (app.display.getDisplay() == null || !app.display.getDisplay().isValid())
                    throw new IOException("Owned app display became invalid");
                off &= app.display.getDisplay().getState() == Display.STATE_OFF;
            }
            if (off) break;
            Thread.sleep(50);
        } while (System.nanoTime() < deadline);
        if (!off) throw new IOException("Owned displays did not sleep");
        sleepFailureStage = "verify_primary_unchanged";
        if (primaryDisplayState() != primaryBefore)
            throw new IOException("Primary display changed during owned device shutdown preparation");
        // This ACK only accepts sleep; the client separately waits for camera
        // callbacks to report no streams and a known, closed owner twice.
        return new byte[]{(byte) (camera == null ? 0 : 1)};
    }

    private byte[] liveState() throws Exception {
        JSONObject state = new JSONObject().put("version", 1).put("desktopHome", desktopHomeRequested);
        state.put("interleavedPreviewSupported", desktopHomeRequested && realtimeVideoRequested && !mirrorOnlyRequested);
        state.put("requestedCameraFrames", cameraRequests.get());
        state.put("pendingRequestedPaints", requestPaints.get());
        state.put("requestedPaintPeak", requestPeak.get());
        state.put("requestedPaintOverflows", requestOverflows.get());
        state.put("requestedPaintPosts", requestPosts.get());
        state.put("requestedPaintIdentitySkips", requestIdentitySkips.get());
        state.put("requestedPaintFailures", requestPostFailures.get());
        state.put("requestedPaintRejected", requestRejected.get());
        // Rolling last 128 successful callback-to-post samples, not a phase
        // percentile. Pending is instantaneous, not shutdown/drain evidence.
        state.put("requestToPostP95Milliseconds", requestPostPercentile());
        state.put("solidCalibrationSupported", desktopHomeRequested && realtimeVideoRequested && !mirrorOnlyRequested);
        JSONArray activities = new JSONArray();
        synchronized (stateLock) {
            state.put("desktopCameraSupported",desktopHomeRequested && !mirrorOnlyRequested);
            state.put("desktopCameraEnabled",desktopCameraRouting.enabled());
            state.put("desktopCameraGeneration",desktopCameraRouting.generation());
            JSONArray bindings=new JSONArray();
            for(Map.Entry<Integer,String> binding:desktopCameraRouting.snapshot().entrySet())
                bindings.put(new JSONObject().put("displayId",binding.getKey()).put("packageName",binding.getValue()));
            state.put("desktopCameraBindings",bindings);
            state.put("generation", streamGeneration).put("captureGeneration", cameraStateGeneration).put("activeStreams", streams.size());
            state.put("cameraOwner", cameraOwner == null ? JSONObject.NULL : cameraOwner);
            // Owner observation remains independent of producer health, including
            // known closed ownership required by safe device teardown.
            state.put("ownerKnown", cameraOwnerKnown).put("ownerGeneration", ownerGeneration);
            state.put("requestDriverHealthy", !requestDriverFailed.get());
            state.put("ownerStatus", requestDriverFailed.get() ? "request_error" : ownerStatus)
                    .put("ownerErrorClass", ownerErrorClass == null ? JSONObject.NULL : ownerErrorClass)
                    .put("ownerErrorDetail", ownerErrorDetail == null ? JSONObject.NULL : ownerErrorDetail)
                    .put("ownerVisibleCameraCount", ownerVisibleCameraCount)
                    .put("ownerBackCameraCount", ownerBackCameraCount)
                    .put("ownerDeviceKeyListedCount", ownerDeviceKeyListedCount)
                    .put("ownerDeviceIdPresentCount", ownerDeviceIdPresentCount)
                    .put("ownerDeviceIdMatchCount", ownerDeviceIdMatchCount);
            for (Map.Entry<Integer, String> entry : topActivities.entrySet()) {
                int id = entry.getKey();
                String component = entry.getValue();
                if (isOwnedActivityDisplay(id) && component != null && !component.isEmpty())
                    activities.put(new JSONObject().put("displayId", id).put("component", component));
            }
        }
        state.put("activities", activities);
        state.put("packageLauncherQuerySupported",true);
        state.put("activityTaskDumpSupported",activityTaskDump.available());
        CameraPaintTiming.Snapshot timing = cameraPaintTiming.snapshot();
        state.put("paintTiming", new JSONObject().put("samples", timing.samples)
                .put("lastAcceptedToPostMilliseconds", timing.lastAcceptedToPost)
                .put("p95AcceptedToPostMilliseconds", timing.p95AcceptedToPost)
                .put("maximumAcceptedToPostMilliseconds", timing.maximumAcceptedToPost)
                .put("lastCanvasLockMilliseconds", timing.lastCanvasLock)
                .put("lastDrawMilliseconds", timing.lastDraw)
                .put("lastPostMilliseconds", timing.lastPost));
        return state.toString().getBytes(StandardCharsets.UTF_8);
    }

    private static void reply(DataOutputStream output, boolean success, byte[] body) throws IOException {
        output.writeByte(success ? 0 : 1);
        output.writeInt(body.length);
        output.write(body);
        output.flush();
    }

    private static void error(DataOutputStream output, String message) throws IOException {
        reply(output, false, message.getBytes(StandardCharsets.UTF_8));
    }

    private boolean handleSession(LocalSocket socket) throws IOException {
        socket.setSoTimeout(SOCKET_IDLE_MS);
        DataInputStream input = new DataInputStream(socket.getInputStream());
        // One small ACK must not become separate forwarded writes for status,
        // length and timing. reply() still flushes each complete response.
        DataOutputStream output = new DataOutputStream(new BufferedOutputStream(socket.getOutputStream(), 16 * 1024));
        while (!stopping) {
            int command;
            try { command = input.readUnsignedByte(); } catch (EOFException eof) { return false; }
            int length = input.readInt();
            if (length < 0 || length > MAX_IMAGE_BYTES + 28) {
                error(output, "Invalid payload length");
                return false;
            }
            if (command==26 && (length<1 || length>260)) {
                error(output,"Invalid camera source payload length");return false;
            }
            byte[] body = new byte[length];
            input.readFully(body);
            if (command == 1) {
                if (mirrorOnlyRequested) { error(output, "Camera disabled for mirror-only research"); continue; }
                if (length <= Long.BYTES) { error(output, "Frame needs an epoch and image"); continue; }
                long epoch = new DataInputStream(new ByteArrayInputStream(body, 0, Long.BYTES)).readLong();
                if (epoch < 0) { error(output, "Epoch must be nonnegative"); continue; }
                if (epoch != currentEpoch) { reply(output, true, new byte[0]); continue; }
                try {
                    byte[] image = Arrays.copyOfRange(body, Long.BYTES, body.length);
                    long frameStartedAt = System.nanoTime();
                    setCameraFrame(image);
                    long processingNanos = System.nanoTime() - frameStartedAt;
                    // Optional numeric receipt: method processing/lock wait only,
                    // excluding socket transfer, reply flush and later painting.
                    reply(output, true, java.nio.ByteBuffer.allocate(Long.BYTES).putLong(processingNanos).array());
                }
                catch (Exception e) { error(output, e.getMessage() == null ? "Invalid camera frame" : e.getMessage()); }
            } else if (command == 35) {
                try {
                    if (length <= 28 || mirrorOnlyRequested || !desktopHomeRequested) throw new IOException("Native source lease is no longer active");
                    java.nio.ByteBuffer request = java.nio.ByteBuffer.wrap(body);
                    int id = request.getInt(); long epoch = request.getLong(), capture = request.getLong(), token = request.getLong();
                    if (id <= 0 || epoch < 0 || capture < 0 || token <= 0) throw new IOException("Native source lease is no longer active");
                    long began = System.nanoTime();
                    setCameraFrame(Arrays.copyOfRange(body, 28, body.length), token, epoch, capture, id);
                    reply(output, true, java.nio.ByteBuffer.allocate(Long.BYTES).putLong(System.nanoTime() - began).array());
                } catch (Exception failure) { error(output, failure.getMessage() == null ? "Native source lease is no longer active" : failure.getMessage()); }
            } else if (command == 33) {
                try { reply(output, true, previewCalibration(body)); }
                catch (Exception failure) { error(output, "Native preview calibration was rejected"); }
            } else if (command == 32) {
                try { reply(output, true, configureNativePreview(body)); }
                catch (Exception failure) { error(output, "Native preview selection was rejected"); }
            } else if (command == 26) {
                try {reply(output,true,configureDesktopCamera(body));}
                catch (Exception failure) {error(output,"Desktop camera selection failed: "+failure.getClass().getSimpleName());}
            } else if (command == 25) {
                try {
                    CalibrationFrameRequest calibration = CalibrationFrameRequest.parse(body);
                    if (calibration.epoch != currentEpoch) { reply(output, true, new byte[0]); continue; }
                    long started = System.nanoTime();
                    setCalibrationFrame(calibration.blue);
                    // ACK measures assignment/queueing, not Surface painting or display.
                    reply(output, true, java.nio.ByteBuffer.allocate(Long.BYTES)
                            .putLong(System.nanoTime() - started).array());
                } catch (Exception failure) {
                    error(output, failure.getMessage() == null ? "Invalid calibration frame" : failure.getMessage());
                }
            } else if (command == 2) {
                if (length != 0) { error(output, "Screenshot request must be empty"); continue; }
                byte[] encoded = null;
                synchronized (frameLock) {
                    if (latestDisplayImage != null) {
                        Image image = latestDisplayImage;
                        Image.Plane plane = image.getPlanes()[0];
                        int paddedWidth = plane.getRowStride() / plane.getPixelStride();
                        Bitmap padded = Bitmap.createBitmap(paddedWidth, image.getHeight(), Bitmap.Config.ARGB_8888);
                        Bitmap cropped = null;
                        try {
                            plane.getBuffer().rewind();
                            padded.copyPixelsFromBuffer(plane.getBuffer());
                            cropped = Bitmap.createBitmap(padded, 0, 0, image.getWidth(), image.getHeight());
                            ByteArrayOutputStream jpeg = new ByteArrayOutputStream(256 * 1024);
                            if (!cropped.compress(Bitmap.CompressFormat.JPEG, 85, jpeg))
                                throw new IOException("Display JPEG encoding failed");
                            encoded = jpeg.toByteArray();
                        } finally {
                            if (cropped != null && cropped != padded) cropped.recycle();
                            padded.recycle();
                        }
                    }
                }
                if (encoded == null) error(output, "Virtual display frame not ready");
                else reply(output, true, encoded);
            } else if (command == 3) {
                if (length != Long.BYTES) { error(output, "Clear request needs an 8-byte epoch"); continue; }
                long epoch = new DataInputStream(new ByteArrayInputStream(body)).readLong();
                if (epoch < 0) { error(output, "Epoch must be nonnegative"); continue; }
                CameraSourcePostFence.Ticket retiredPost = null;
                boolean advanced = false;
                synchronized (stateLock) {
                    if (epoch > currentEpoch) {
                        currentEpoch = epoch;advanced = true;
                        // An explicit new capture operation may select ordinary
                        // camera input again. Retired native packets still carry
                        // their old epoch/token and cannot enter this operation.
                        synchronized (cameraLock) {nativeSourceOnly = false;}
                        retiredPost=clearCameraFrame(false);
                    }
                }
                try {
                    if (desktopHomeRequested && advanced) sourcePostFence.await(retiredPost);
                    else awaitCameraPaints();
                    reply(output, true, new byte[0]);
                }
                catch (IOException failure) { error(output, "Camera clear is not yet confirmed"); }
            } else if (command == 23) {
                if (length != Long.BYTES) { error(output, "Discard request needs an 8-byte epoch"); continue; }
                long epoch = new DataInputStream(new ByteArrayInputStream(body)).readLong();
                if (epoch < 0) { error(output, "Epoch must be nonnegative"); continue; }
                // An old discard must never erase a newer capture generation.
                final boolean sameEpoch = epoch == currentEpoch;
                CameraSourcePostFence.Ticket retiredPost = sameEpoch ? clearCameraFrame(true) : null;
                try {
                    if (desktopHomeRequested && sameEpoch) sourcePostFence.await(retiredPost);
                    else awaitCameraPaints();
                    reply(output, true, new byte[0]);
                }
                catch (IOException failure) { error(output, "Camera discard is not yet confirmed"); }
            } else if (command == 4) {
                if (length != 0) { error(output, "Heartbeat must be empty"); continue; }
                reply(output, true, new byte[0]);
            } else if (command == 5) {
                if (length != 0) { error(output, "Live state request must be empty"); continue; }
                try { reply(output, true, liveState()); }
                catch (Exception failure) { error(output, "Live state unavailable"); }
            } else if (command == 30) {
                if (length != 0) { error(output, "Activity task dump request must be empty"); continue; }
                try { reply(output, true, activityTaskDump.read()); }
                catch (IOException failure) {
                    error(output, ActivityTaskDump.TIMEOUT.equals(failure.getMessage())
                            ? ActivityTaskDump.TIMEOUT : ActivityTaskDump.UNAVAILABLE);
                }
            } else if (command == 10 || command == 11 || command == 12) {
                if ((command == 12 && length != Integer.BYTES) || (command == 11 && length != 0) || (command == 10 && length > 255)) {
                    error(output, "Invalid app command payload"); continue;
                }
                try {
                    if (command == 10) reply(output, true, applications(body));
                    else if (command == 11) reply(output, true, createAppDisplay());
                    else {
                        releaseAppDisplay(new DataInputStream(new ByteArrayInputStream(body)).readInt());
                        reply(output, true, new byte[0]);
                    }
                } catch (Exception failure) { error(output, "App operation failed: " + failure.getClass().getSimpleName()); }
            } else if (command == 20 || command == 21) {
                if (length != Integer.BYTES) { error(output, "Direct stream request needs a display ID"); continue; }
                int id = new DataInputStream(new ByteArrayInputStream(body)).readInt();
                try {
                    if (command == 20) reply(output, true, startDirectStream(id));
                    else { stopDirectStream(id); reply(output, true, new byte[0]); }
                } catch (Exception failure) { error(output, "Direct stream operation failed: " + failure.getClass().getSimpleName()); }
            } else if (command == 24) {
                if (length != 0) { error(output, "Shutdown preparation must be empty"); continue; }
                try { reply(output, true, prepareOwnedDeviceShutdown()); }
                catch (Exception failure) { error(output, "Owned device sleep not confirmed: " + sleepFailureStage); }
            } else if (command == 9) {
                if (length != 0) { error(output, "Stop request must be empty"); continue; }
                reply(output, true, new byte[0]);
                return true;
            } else {
                error(output, "Unknown command");
            }
        }
        return false;
    }

    private void serve(String name, byte[] expectedToken) throws Exception {
        server = new LocalServerSocket(name);
        log("ready", 1);
        long deadline = android.os.SystemClock.uptimeMillis() + FIRST_CONNECTION_MS;
        while (!stopping) {
            long remaining = deadline - android.os.SystemClock.uptimeMillis();
            if (remaining <= 0) throw new IOException("No authenticated Mac connection within 60 seconds");
            Future<LocalSocket> wait = acceptor.submit(() -> server.accept());
            LocalSocket incoming;
            try { incoming = wait.get(remaining, TimeUnit.MILLISECONDS); }
            catch (java.util.concurrent.TimeoutException timeout) {
                server.close();
                throw new IOException("No authenticated Mac connection within 60 seconds", timeout);
            }
            incoming.setSoTimeout((int) Math.min(remaining, 10_000));
            byte[] token = new byte[32];
            try {
                new DataInputStream(incoming.getInputStream()).readFully(token);
                if (!MessageDigest.isEqual(expectedToken, token)) {
                    incoming.close();
                    continue;
                }
            } catch (IOException e) {
                incoming.close();
                continue;
            }
            client = incoming;
            log("client", "authenticated");
            try { handleSession(incoming); }
            finally { incoming.close(); client = null; }
            return; // A single authenticated session owns this virtual device.
        }
    }

    private synchronized void close() {
        if (stopping) return;
        stopping = true;
        activityTaskDump.close();
        boolean clean = true;
        boolean deviceClosed = false;
        if (client != null) try { client.close(); } catch (Exception e) { clean = false; log("cleanup_error", e); }
        if (server != null) try { server.close(); } catch (Exception e) { clean = false; log("cleanup_error", e); }
        try { revokeSupportedCameras(); } catch (Exception e) { clean = false; log("cleanup_error", "virtual camera permission: " + e); }
        if (activityListener != null && device != null) try {
            Class<?> listenerClass = Class.forName("android.companion.virtual.VirtualDeviceManager$ActivityListener");
            call(device, "removeActivityListener", new Class[]{listenerClass}, activityListener);
            activityListener = null;
        } catch (Exception e) { clean = false; log("cleanup_error", "activity listener cleanup failed"); }
        if (cameraOwnerListener != null && cameraManager != null) try {
            cameraManager.unregisterAvailabilityCallback(cameraOwnerListener);
            cameraOwnerListener = null;
            cameraManager = null;
        } catch (Exception e) { clean = false; log("cleanup_error", "camera owner listener cleanup failed"); }
        synchronized (stateLock) { cameraOwner = null; cameraOwnerKnown = false; }
        cameraCallbacks.close();
        painter.shutdownNow();
        for (Map.Entry<Integer, DirectDisplayStream> entry : directStreams.entrySet()) {
            DirectDisplayStream stream = entry.getValue();
            try { stream.close(); stream.awaitClosed(); directStreams.remove(entry.getKey(), stream); }
            catch (Exception e) { clean = false; log("cleanup_error", "direct stream cleanup failed; resources retained until process termination"); }
        }
        if (!directStreams.isEmpty()) {
            // A worker may still be using its codec/display. Do not release any
            // underlying VD, reader or VirtualDevice; process exit reclaims binder
            // resources. Never claim complete cleanup in this partial path.
            callbacks.shutdownNow();
            acceptor.shutdownNow();
            log("cleanup", "partial_close_failed");
            return;
        }
        for (AppDisplay owned : appDisplays.values()) try { owned.close(); } catch (Exception e) { clean = false; log("cleanup_error", e); }
        appDisplays.clear();
        synchronized (stateLock) { topActivities.clear(); earlyTopActivities.clear(); }
        if (display != null) try { display.release(); } catch (Exception e) { clean = false; log("cleanup_error", e); }
        synchronized (frameLock) {
            if (latestDisplayImage != null) latestDisplayImage.close();
            latestDisplayImage = null;
        }
        if (displayReader != null) try { displayReader.close(); } catch (Exception e) { clean = false; log("cleanup_error", e); }
        for (Object owned : new Object[]{camera, device}) {
            if (owned != null) try {
                call(owned, "close", new Class[]{});
                if (owned == device) deviceClosed = true;
            } catch (Exception e) { clean = false; log("cleanup_error", e); }
        }
        callbacks.shutdownNow();
        acceptor.shutdownNow();
        if (imageThread != null) imageThread.quitSafely();
        clearCameraFrame();
        synchronized (frameLock) {
            if (latestDisplayImage != null) latestDisplayImage.close();
            latestDisplayImage = null;
        }
        log("cleanup", device == null ? "no_device_created" :
                (clean && deviceClosed ? "closed_owned_session" : "partial_close_failed"));
    }

    public static void main(String[] args) {
        LiveCameraServer live = new LiveCameraServer();
        int result = 0;
        try {
            SessionFlags flags = parseSessionFlags(args);
            live.independentLockRequested = flags.independentLock;
            live.desktopHomeRequested = flags.desktopHome;
            live.balancedDisplayRequested = flags.balancedDisplay;
            live.displayBeforeCameraRequested = flags.displayBeforeCamera;
            live.mirrorOnlyRequested = flags.mirrorOnly;
            live.realtimeVideoRequested = flags.realtimeVideo;
            int association = Integer.parseInt(args[0]);
            if (association <= 0) throw new IllegalArgumentException("Association ID must be positive");
            byte[] token = args[2].getBytes(StandardCharsets.US_ASCII);
            live.context = CameraProbe.shellContext();
            CameraProbe.context = live.context;
            log("pid", Process.myPid());
            Runtime.getRuntime().addShutdownHook(new Thread(live::close));
            log("setup_phase", "virtual_device");
            live.createVirtualDevice(association);
            // Explicit research switch; default product order is unchanged.
            if (live.displayBeforeCameraRequested) {
                log("setup_phase", "owned_display");
                live.createVirtualDisplay();
            }
            if (!live.mirrorOnlyRequested) {
                log("setup_phase", "camera_policy");
                // Generic sessions start without compatibility grants. Authenticated
                // source selection and per-owned-window binding remain required.
                if (flags.needsCompatibilityCameraGrants()) live.grantSupportedCameras();
                log("setup_phase", "virtual_camera");
                live.createVirtualCamera();
            } else {
                // Isolate the owned HOME/video path without contacting camera
                // services or granting packages virtual-camera access.
                live.ownerStatus = "mirror_only";
                log("camera_mode", "disabled_research");
            }
            if (!live.displayBeforeCameraRequested) {
                log("setup_phase", "owned_display");
                live.createVirtualDisplay();
            }
            log("setup_phase", "session_channel");
            live.serve(args[1], token);
        } catch (Throwable error) {
            while (error instanceof InvocationTargetException && error.getCause() != null) error = error.getCause();
            log("error", error.getClass().getName() + ": " + error.getMessage());
            error.printStackTrace(System.err);
            result = 1;
        } finally {
            live.close();
        }
        System.exit(result);
    }
}
