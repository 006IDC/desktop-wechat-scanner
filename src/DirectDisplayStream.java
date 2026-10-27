import android.hardware.display.VirtualDisplay;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.SystemClock;
import android.view.Display;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.Surface;
import java.io.*;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** Authenticated, session-owned direct encoder surface. Never mirrors display 0. */
final class DirectDisplayStream implements AutoCloseable {
    interface Validator { void validate() throws Exception; }
    final int displayId, width, height;
    final String socketName, token;
    private final VirtualDisplay display;
    private final Surface originalSurface;
    private final Validator validator;
    private final boolean realtimeRequested;
    private final AtomicBoolean closed = new AtomicBoolean();
    private final Object connections = new Object();
    private final CountDownLatch cleanupFinished = new CountDownLatch(1);
    private volatile IOException cleanupFailure;
    private final ExecutorService workers = Executors.newCachedThreadPool();
    private final ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor();
    private LocalServerSocket server;
    private LocalSocket pending, video, control;
    private MediaCodec codec;
    private boolean codecStarted;
    private Surface encoderSurface;
    private boolean down;
    private long downTime;
    private float lastX, lastY;

    DirectDisplayStream(VirtualDisplay display, Surface originalSurface, int width, int height, boolean realtimeRequested, Validator validator) throws Exception {
        this.display = display; this.originalSurface = originalSurface;
        this.width = width; this.height = height; this.validator = validator;
        this.realtimeRequested = realtimeRequested;
        validator.validate();
        displayId = display.getDisplay().getDisplayId();
        if (displayId <= Display.DEFAULT_DISPLAY || width <= 0 || height <= 0) throw new IOException("Invalid owned video display");
        socketName = "006idc_video_" + randomHex(); token = randomHex();
    }

    void start() throws Exception {
        try {
            server = new LocalServerSocket(socketName);
            codec = MediaCodec.createEncoderByType("video/avc");
            MediaFormat format = MediaFormat.createVideoFormat("video/avc", width, height);
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            format.setInteger(MediaFormat.KEY_BIT_RATE, 8_000_000);
            format.setInteger(MediaFormat.KEY_FRAME_RATE, 60);
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
            if (realtimeRequested) {
                // Public encoder hints. Vendors may ignore LATENCY; report the
                // eventual output format instead of claiming it was enabled.
                format.setInteger(MediaFormat.KEY_PRIORITY, 0);
                format.setInteger(MediaFormat.KEY_LATENCY, 0);
                // Keep a static UI's tail from waiting for later user input
                // when a hardware encoder retains multiple frames internally.
                format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 16_667L);
            }
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            encoderSurface = codec.createInputSurface();
            codec.start();
            codecStarted = true;
            validator.validate();
            display.setSurface(encoderSurface);
            timer.schedule(() -> {
                synchronized (connections) { if (video != null && control != null) return; }
                close();
            }, 15, TimeUnit.SECONDS);
            workers.execute(this::accept);
        } catch (Exception failure) { throw failure; }
    }

    private static String randomHex() {
        byte[] bytes = new byte[16]; new SecureRandom().nextBytes(bytes);
        StringBuilder result = new StringBuilder(32);
        for (byte value : bytes) result.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        return result.toString();
    }

    private void accept() {
        long deadline = SystemClock.uptimeMillis() + 15_000;
        try {
            while (!closed.get()) {
                synchronized (connections) { if (video != null && control != null) return; }
                LocalSocket incoming = server.accept();
                synchronized (connections) {
                    if (closed.get()) { incoming.close(); return; }
                    pending = incoming;
                }
                boolean accepted = false;
                try {
                    long remaining = deadline - SystemClock.uptimeMillis();
                    if (remaining <= 0) throw new IOException("Direct stream authentication timed out");
                    incoming.setSoTimeout((int) remaining);
                    DataInputStream input = new DataInputStream(incoming.getInputStream());
                    byte[] supplied = new byte[32]; input.readFully(supplied);
                    if (!MessageDigest.isEqual(token.getBytes(StandardCharsets.US_ASCII), supplied)) continue;
                    int role = input.readUnsignedByte();
                    synchronized (connections) {
                        if (closed.get() || (role != 0 && role != 1) || (role == 0 ? video != null : control != null)) continue;
                        validator.validate();
                        incoming.setSoTimeout(0);
                        incoming.getOutputStream().write(0); incoming.getOutputStream().flush();
                        if (role == 0) video = incoming; else control = incoming;
                        accepted = true;
                    }
                    LocalSocket owned = incoming;
                    if (role == 0) workers.execute(() -> encode(owned));
                    else workers.execute(() -> control(owned));
                } catch (IOException invalidConnection) {
                    // An unauthenticated peer cannot terminate the owning stream.
                } finally {
                    synchronized (connections) { pending = null; }
                    if (!accepted) try { incoming.close(); } catch (IOException ignored) {}
                }
            }
        } catch (Exception failure) { close(); }
    }

    private void encode(LocalSocket socket) {
        try {
            DataOutputStream output = new DataOutputStream(socket.getOutputStream());
            output.write("h264".getBytes(StandardCharsets.US_ASCII));
            output.writeInt(0x80000000); output.writeInt(width); output.writeInt(height); output.flush();
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            while (!closed.get()) {
                int index = codec.dequeueOutputBuffer(info, 100_000);
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat actual = codec.getOutputFormat();
                    int latency = actual.containsKey(MediaFormat.KEY_LATENCY) ? actual.getInteger(MediaFormat.KEY_LATENCY) : -1;
                    System.out.println("QR_LIVE direct_codec_latency=" + latency);
                    System.out.flush();
                }
                if (index < 0) continue;
                try {
                    if (info.size <= 0) continue;
                    if (info.size > 8 * 1024 * 1024) throw new IOException("Encoded packet exceeds limit");
                    ByteBuffer buffer = codec.getOutputBuffer(index);
                    if (buffer == null) throw new IOException("Encoder output unavailable");
                    buffer.position(info.offset); buffer.limit(info.offset + info.size);
                    long flags = info.presentationTimeUs & ((1L << 61) - 1);
                    if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) flags |= 1L << 62;
                    if ((info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0) flags |= 1L << 61;
                    DirectVideoPacket.write(output, buffer, flags, info.size);
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) throw new IOException("Encoder ended");
                } finally { codec.releaseOutputBuffer(index, false); }
            }
        } catch (Exception failure) { /* Closing the socket makes failure explicit to Mac. */ }
        finally { close(); }
    }

    private void inject(InputEvent event) throws Exception {
        validator.validate();
        Display actual = display.getDisplay();
        if (actual == null || !actual.isValid() || actual.getDisplayId() != displayId || displayId <= 0)
            throw new IOException("Input display is no longer owned and valid");
        InputEvent.class.getMethod("setDisplayId", int.class).invoke(event, displayId);
        Class<?> inputManager = Class.forName("android.hardware.input.InputManager");
        Object manager = inputManager.getMethod("getInstance").invoke(null);
        Method inject = inputManager.getMethod("injectInputEvent", InputEvent.class, int.class);
        if (!Boolean.TRUE.equals(inject.invoke(manager, event, 0))) throw new IOException("Owned display input rejected");
    }

    private void control(LocalSocket socket) {
        try {
            DataInputStream input = new DataInputStream(socket.getInputStream());
            while (!closed.get()) {
                int type = input.readUnsignedByte();
                if (type == 2) {
                    int action = input.readUnsignedByte(); long pointer = input.readLong();
                    long x = Integer.toUnsignedLong(input.readInt()), y = Integer.toUnsignedLong(input.readInt());
                    int w = input.readUnsignedShort(), h = input.readUnsignedShort(), pressure = input.readUnsignedShort();
                    int actionButton = input.readInt(), buttons = input.readInt();
                    if ((action != 0 && action != 1 && action != 2) || pointer != -2L || w != width || h != height ||
                            x >= width || y >= height || actionButton != 0 || buttons != 0 || (action == 0 ? down : !down))
                        throw new IOException("Unsupported direct touch event");
                    long now = SystemClock.uptimeMillis();
                    if (action == 0) { down = true; downTime = now; }
                    lastX = x; lastY = y;
                    MotionEvent.PointerProperties properties = new MotionEvent.PointerProperties();
                    properties.id = 0;
                    properties.toolType = MotionEvent.TOOL_TYPE_FINGER;
                    MotionEvent.PointerCoords coords = new MotionEvent.PointerCoords();
                    coords.x = lastX;
                    coords.y = lastY;
                    coords.pressure = pressure / 65535f;
                    coords.size = 1f;
                    MotionEvent event = MotionEvent.obtain(downTime, now, action, 1,
                            new MotionEvent.PointerProperties[]{properties}, new MotionEvent.PointerCoords[]{coords},
                            0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
                    try { inject(event); } finally { event.getClass().getMethod("recycle").invoke(event); }
                    if (action == 1) down = false;
                } else if (type == 0) {
                    int action = input.readUnsignedByte(), code = input.readInt(), repeat = input.readInt(), meta = input.readInt();
                    if ((action != 0 && action != 1) || (code != KeyEvent.KEYCODE_BACK && code != KeyEvent.KEYCODE_HOME) || repeat != 0 || meta != 0)
                        throw new IOException("Unsupported direct navigation key");
                    long now = SystemClock.uptimeMillis();
                    KeyEvent event = new KeyEvent(now, now, action, code, 0, 0, -1, 0, 0, InputDevice.SOURCE_KEYBOARD);
                    try { inject(event); } finally { event.getClass().getMethod("recycle").invoke(event); }
                } else throw new IOException("Unsupported direct control message");
            }
        } catch (Exception failure) { /* EOF/error closes both roles. */ }
        finally { close(); }
    }

    void awaitClosed() throws IOException {
        try {
            if (!cleanupFinished.await(4, TimeUnit.SECONDS)) throw new IOException("Direct encoder cleanup timed out");
            if (cleanupFailure != null) throw new IOException("Direct encoder resources remain owned until process termination", cleanupFailure);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt(); throw new IOException("Direct encoder cleanup interrupted", interrupted);
        }
    }

    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        timer.shutdownNow();
        synchronized (connections) {
            for (LocalSocket socket : new LocalSocket[]{pending, video, control})
                if (socket != null) try { socket.close(); } catch (IOException ignored) {}
        }
        if (server != null) try { server.close(); } catch (IOException ignored) {}
        // Codec release follows the encoder worker, avoiding release/dequeue races.
        workers.shutdownNow();
        Thread cleanup = new Thread(() -> {
            try {
                if (!workers.awaitTermination(2, TimeUnit.SECONDS)) {
                    cleanupFailure = new IOException("Direct encoder workers did not stop; surface and codec retained");
                    return;
                }
                // Restore the live ImageReader before releasing its replacement surface.
                if (originalSurface == null || !originalSurface.isValid()) throw new IOException("Original owned display surface is unavailable");
                display.setSurface(originalSurface);
                if (codec != null) {
                    try { if (codecStarted) codec.stop(); } finally { codec.release(); }
                }
                if (encoderSurface != null) encoderSurface.release();
            } catch (Exception failure) {
                if (failure instanceof InterruptedException) Thread.currentThread().interrupt();
                cleanupFailure = new IOException("Direct encoder cleanup failed; resources remain owned", failure);
            } finally { cleanupFinished.countDown(); }
        }, "006IDC-direct-codec-cleanup");
        cleanup.start();
    }
}
