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

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Map;
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
    private static final int MAX_IMAGE_BYTES = 4 * 1024 * 1024;
    private static final int MAX_IMAGE_SIDE = 2048;
    private int displayWidth = 720;
    private int displayHeight = 1280;
    private int displayDpi = 320;
    private static final int SOCKET_IDLE_MS = 90_000;
    private static final int FIRST_CONNECTION_MS = 60_000;
    private static final String INDEPENDENT_LOCK_PERMISSION = "android.permission.ADD_ALWAYS_UNLOCKED_DISPLAY";
    private boolean independentLockRequested;

    private final Object cameraLock = new Object();
    private final Object frameLock = new Object();
    private final Map<Integer, Surface> streams = new ConcurrentHashMap<>();
    private final ExecutorService callbacks = Executors.newSingleThreadExecutor();
    private final ScheduledExecutorService painter = Executors.newSingleThreadScheduledExecutor();
    private final ExecutorService acceptor = Executors.newSingleThreadExecutor();
    // At most one queued paint besides the one currently running. Every paint,
    // including the idle refresh, stays on this one executor: never parallel Canvas.
    private final AtomicBoolean paintPending = new AtomicBoolean();
    private volatile long lastCameraUpdateNanos = System.nanoTime();
    private volatile boolean stopping;
    private Image latestDisplayImage;
    private Context context;
    private Bitmap cameraFrame;
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
    private boolean wechatCameraGranted;
    // Only the authenticated command reader changes this value. A clear advances
    // the epoch so a frame captured before pause cannot revive the camera.
    private long currentEpoch;

    private static void log(String key, Object value) {
        System.out.println(PREFIX + key + "=" + value);
        System.out.flush();
    }

    private static Object call(Object target, String method, Class<?>[] types, Object... values) throws Exception {
        return CameraProbe.call(target, method, types, values);
    }

    static boolean requestedIndependentLock(String[] args) {
        if ((args.length != 3 && args.length != 4) || !args[1].matches("006idc_scan_[0-9a-f]{8}") ||
                !args[2].matches("[0-9a-f]{32}") || (args.length == 4 && !"independent-lock".equals(args[3])))
            throw new IllegalArgumentException("Expected associationId 006idc_scan_<8 hex> <32 hex token> [independent-lock]");
        return args.length == 4;
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
        int cameraPolicy = paramsClass.getField("POLICY_TYPE_CAMERA").getInt(null);
        int customPolicy = paramsClass.getField("DEVICE_POLICY_CUSTOM").getInt(null);
        call(builder, "setDevicePolicy", new Class[]{int.class, int.class}, cameraPolicy, customPolicy);
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
    }

    private void grantWechatCamera() throws Exception {
        Context virtualContext = context.createDeviceContext(deviceId);
        if (virtualContext.getDeviceId() != deviceId) throw new IllegalStateException("Virtual context mismatch");
        PackageManager pm = virtualContext.getPackageManager();
        pm.getClass().getMethod("grantRuntimePermission", String.class, String.class, UserHandle.class)
                .invoke(pm, WECHAT, "android.permission.CAMERA", Process.myUserHandle());
        wechatCameraGranted = true;
        log("camera_permission", "granted_virtual_device_only");
    }

    private void revokeWechatCamera() throws Exception {
        if (!wechatCameraGranted || deviceId <= 0) return;
        Context virtualContext = context.createDeviceContext(deviceId);
        if (virtualContext.getDeviceId() != deviceId) throw new IllegalStateException("Virtual context mismatch on revoke");
        PackageManager pm = virtualContext.getPackageManager();
        pm.getClass().getMethod("revokeRuntimePermission", String.class, String.class, UserHandle.class)
                .invoke(pm, WECHAT, "android.permission.CAMERA", Process.myUserHandle());
        wechatCameraGranted = false;
        log("camera_permission", "revoked_virtual_device_only");
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
                        streams.put((Integer) args[0], (Surface) args[1]);
                        requestPaint();
                    } else if ("onStreamClosed".equals(method.getName())) {
                        streams.remove((Integer) args[0]);
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
        call(builder, "setVirtualCameraCallback", new Class[]{Executor.class, callbackClass}, callbacks, callback);
        Object config = call(builder, "build", new Class[]{});
        camera = call(device, "createVirtualCamera", new Class[]{configClass}, config);
        log("camera_id", call(camera, "getId", new Class[]{}));
        painter.scheduleWithFixedDelay(() -> {
            // Arrival-driven drawing already supplies the active 30fps stream.
            // Only refresh idle content; otherwise an unrelated tick could post
            // an old image just before the next arrival and add camera backpressure.
            if (System.nanoTime() - lastCameraUpdateNanos >= TimeUnit.MILLISECONDS.toNanos(66))
                requestPaint();
        }, 33, 33, TimeUnit.MILLISECONDS);
    }

    private void requestPaint() {
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

    private void paint(Surface surface) {
        if (stopping || !surface.isValid()) return;
        Canvas canvas = null;
        try {
            canvas = surface.lockCanvas(null);
            canvas.drawColor(Color.WHITE);
            synchronized (cameraLock) {
                if (cameraFrame != null) {
                    int width = canvas.getWidth();
                    int height = canvas.getHeight();
                    canvas.save();
                    canvas.translate(width / 2f, height / 2f);
                    canvas.rotate(-90);
                    int portraitWidth = height, portraitHeight = width;
                    float scale = Math.min((float) portraitWidth / cameraFrame.getWidth(), (float) portraitHeight / cameraFrame.getHeight());
                    int drawWidth = Math.round(cameraFrame.getWidth() * scale);
                    int drawHeight = Math.round(cameraFrame.getHeight() * scale);
                    Rect destination = new Rect(-drawWidth / 2, -drawHeight / 2,
                            drawWidth / 2, drawHeight / 2);
                    Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
                    canvas.drawBitmap(cameraFrame, null, destination, paint);
                    canvas.restore();
                }
            }
        } catch (Exception e) {
            if (!stopping) log("paint_error", e.toString());
        } finally {
            if (canvas != null) try { surface.unlockCanvasAndPost(canvas); } catch (Exception ignored) {}
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
        display = (VirtualDisplay) call(device, "createVirtualDisplay",
                new Class[]{int.class, int.class, int.class, Surface.class, int.class, Executor.class, VirtualDisplay.Callback.class},
                displayWidth, displayHeight, displayDpi, displayReader.getSurface(), flags,
                callbacks, new VirtualDisplay.Callback() {});
        // On failure main's finally releases this display, reader, camera and
        // virtual device before exiting; do not serve an unverified session.
        boolean independentLockReady = verifyIndependentLock(display);
        wakeIndependentDisplay(display);
        log("independent_lock_ready", independentLockReady ? 1 : 0);
        log("display_id", display.getDisplay().getDisplayId());
        log("display_width", displayWidth); log("display_height", displayHeight); log("display_dpi", displayDpi);
    }

    private byte[] applications() throws Exception {
        // Explicitly query the primary user, never work-profile/private-profile apps.
        if (Process.myUid() / 100000 != 0) throw new IOException("Primary user required");
        Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        PackageManager pm = context.getPackageManager();
        List<ResolveInfo> resolved = pm.queryIntentActivities(launcher, PackageManager.MATCH_DIRECT_BOOT_AWARE | PackageManager.MATCH_DIRECT_BOOT_UNAWARE);
        JSONArray entries = new JSONArray();
        HashSet<String> seen = new HashSet<>();
        for (ResolveInfo entry : resolved) {
            if (entries.length() >= 500) break;
            if (entry.activityInfo == null || !entry.activityInfo.exported || !entry.activityInfo.enabled || !entry.activityInfo.applicationInfo.enabled) continue;
            String pkg = entry.activityInfo.packageName;
            String cls = entry.activityInfo.name;
            if (pkg == null || cls == null || !pkg.matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+") ||
                    !cls.matches("[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*)*")) continue;
            String component = new ComponentName(pkg, cls).flattenToString();
            if (!seen.add(component)) continue;
            String label = String.valueOf(entry.loadLabel(pm)).replaceAll("[\\p{Cntrl}]", " ");
            if (label.length() > 160) label = label.substring(0, 160);
            entries.put(new JSONObject().put("packageName", pkg).put("component", component).put("name", label));
        }
        return entries.toString().getBytes(StandardCharsets.UTF_8);
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
        stopDirectStream(id);
        owned.close();
        appDisplays.remove(id);
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
        DirectDisplayStream stream = new DirectDisplayStream(target, original, displayWidth, displayHeight, () -> {
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

    private void setCameraFrame(byte[] bytes) throws IOException {
        if (bytes.length == 0 || bytes.length > MAX_IMAGE_BYTES || !isSupportedImage(bytes))
            throw new IOException("Expected JPEG/PNG, 1..4 MiB");
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0 || bounds.outWidth > MAX_IMAGE_SIDE || bounds.outHeight > MAX_IMAGE_SIDE)
            throw new IOException("Image dimensions must be 1..2048 on each side");
        Bitmap decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        if (decoded == null) throw new IOException("Cannot decode image");
        synchronized (cameraLock) {
            Bitmap previous = cameraFrame;
            cameraFrame = decoded;
            if (previous != null) previous.recycle();
        }
        lastCameraUpdateNanos = System.nanoTime();
        requestPaint();
    }

    private void clearCameraFrame() {
        synchronized (cameraLock) {
            Bitmap previous = cameraFrame;
            cameraFrame = null;
            if (previous != null) previous.recycle();
        }
        lastCameraUpdateNanos = System.nanoTime();
        requestPaint();
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
            if (length < 0 || length > MAX_IMAGE_BYTES + Long.BYTES) {
                error(output, "Invalid payload length");
                return false;
            }
            byte[] body = new byte[length];
            input.readFully(body);
            if (command == 1) {
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
                if (epoch > currentEpoch) {
                    currentEpoch = epoch;
                    clearCameraFrame();
                }
                reply(output, true, new byte[0]);
            } else if (command == 4) {
                if (length != 0) { error(output, "Heartbeat must be empty"); continue; }
                reply(output, true, new byte[0]);
            } else if (command == 10 || command == 11 || command == 12) {
                if ((command == 12 && length != Integer.BYTES) || (command != 12 && length != 0)) {
                    error(output, "Invalid app command payload"); continue;
                }
                try {
                    if (command == 10) reply(output, true, applications());
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
        boolean clean = true;
        boolean deviceClosed = false;
        if (client != null) try { client.close(); } catch (Exception e) { clean = false; log("cleanup_error", e); }
        if (server != null) try { server.close(); } catch (Exception e) { clean = false; log("cleanup_error", e); }
        try { revokeWechatCamera(); } catch (Exception e) { clean = false; log("cleanup_error", "virtual camera permission: " + e); }
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
            live.independentLockRequested = requestedIndependentLock(args);
            int association = Integer.parseInt(args[0]);
            if (association <= 0) throw new IllegalArgumentException("Association ID must be positive");
            byte[] token = args[2].getBytes(StandardCharsets.US_ASCII);
            live.context = CameraProbe.shellContext();
            CameraProbe.context = live.context;
            log("pid", Process.myPid());
            Runtime.getRuntime().addShutdownHook(new Thread(live::close));
            live.createVirtualDevice(association);
            live.grantWechatCamera();
            live.createVirtualCamera();
            live.createVirtualDisplay();
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
