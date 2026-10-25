import android.content.Context;
import android.content.ContextWrapper;
import android.content.AttributionSource;
import android.graphics.*;
import android.hardware.camera2.*;
import android.hardware.display.*;
import android.media.*;
import android.os.*;
import android.view.Surface;
import android.os.Looper;
import java.io.*;
import java.lang.reflect.*;
import java.util.Map;
import java.util.concurrent.*;

/** Temporary shell-owned diagnostic. Uses existing shell permissions only. */
public final class CameraProbe {
    static Context context;
    static final String PREFIX = "QR_PROBE ";
    static final String DIR = "/data/local/tmp/006idc-qr-probe/";
    // Android 16 DisplayManager internal flags. OWN_FOCUS is not ALWAYS_UNLOCKED (1<<12).
    static final int DISPLAY_SUPPORTS_TOUCH = 1 << 6;
    static final int DISPLAY_TRUSTED = 1 << 10;
    static final int DISPLAY_OWN_FOCUS = 1 << 14;
    static final ExecutorService callbacks = Executors.newSingleThreadExecutor();
    static final ScheduledExecutorService painter = Executors.newSingleThreadScheduledExecutor();
    static final Map<Integer, Surface> inputs = new ConcurrentHashMap<>();
    static volatile boolean stopping;
    static volatile long paintedFrames;
    static Bitmap source;
    static Object device, camera;
    static VirtualDisplay display;
    static ImageReader displayReader;
    static final Object frameLock = new Object();
    static Bitmap latestDisplay;
    static HandlerThread handlerThread;

    static final class ShellContext extends ContextWrapper {
        ShellContext(Context base) { super(base); }
        @Override public String getPackageName() { return "com.android.shell"; }
        @Override public String getOpPackageName() { return "com.android.shell"; }
        @Override public Context getApplicationContext() { return this; }
        @Override public AttributionSource getAttributionSource() {
            return new AttributionSource.Builder(android.os.Process.myUid()).setPackageName("com.android.shell").build();
        }
        @Override public Context createDeviceContext(int id) {
            return new ShellContext(getBaseContext().createDeviceContext(id));
        }
    }

    static void log(String name, Object value) {
        System.out.println(PREFIX + name + "=" + value);
        System.out.flush();
    }

    static Object call(Object obj, String name, Class<?>[] types, Object... args) throws Exception {
        Method m = obj.getClass().getMethod(name, types);
        return m.invoke(obj, args);
    }

    static Context shellContext() throws Exception {
        Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread = at.getMethod("systemMain").invoke(null);
        Context system = (Context) at.getMethod("getSystemContext").invoke(thread);
        return new ShellContext(system.createPackageContext("com.android.shell", 0));
    }

    static Object manager() throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, "virtualdevice");
        Class<?> iface = Class.forName("android.companion.virtual.IVirtualDeviceManager");
        Object service = Class.forName(iface.getName()+"$Stub").getMethod("asInterface", IBinder.class).invoke(null, binder);
        return Class.forName("android.companion.virtual.VirtualDeviceManager").getConstructor(iface, Context.class).newInstance(service, context);
    }

    static void paint(Surface surface) {
        if (stopping || !surface.isValid()) return;
        Canvas c = null;
        try {
            c = surface.lockCanvas(null);
            c.drawColor(Color.WHITE);
            int size = Math.min(c.getWidth(), c.getHeight()) * 4 / 5;
            int x = (c.getWidth()-size)/2, y=(c.getHeight()-size)/2;
            Paint p = new Paint();
            p.setFilterBitmap(false);
            c.drawBitmap(source, null, new Rect(x,y,x+size,y+size), p);
            p.setColor(Color.rgb(20,180,90));
            c.drawRect(0,c.getHeight()-12,c.getWidth(),c.getHeight(),p);
            paintedFrames++;
        } catch (Exception e) {
            if (!stopping) log("paint_error", e.toString());
        } finally {
            if (c!=null) try { surface.unlockCanvasAndPost(c); } catch(Exception ignored) {}
        }
    }

    static void create(int association) throws Exception {
        Class<?> paramsClass = Class.forName("android.companion.virtual.VirtualDeviceParams");
        Object builder = Class.forName(paramsClass.getName()+"$Builder").getConstructor().newInstance();
        call(builder,"setName",new Class[]{String.class},"006IDC QR prototype");
        int type=paramsClass.getField("POLICY_TYPE_CAMERA").getInt(null);
        int custom=paramsClass.getField("DEVICE_POLICY_CUSTOM").getInt(null);
        call(builder,"setDevicePolicy",new Class[]{int.class,int.class},type,custom);
        Object params=call(builder,"build",new Class[]{});
        device=call(manager(),"createVirtualDevice",new Class[]{int.class,paramsClass},association,params);
        log("device_id",call(device,"getDeviceId",new Class[]{}));

        Class<?> cbClass=Class.forName("android.companion.virtual.camera.VirtualCameraCallback");
        Object cb=Proxy.newProxyInstance(cbClass.getClassLoader(),new Class[]{cbClass},(proxy,method,args)->{
            if(method.getDeclaringClass()==Object.class) {
                if(method.getName().equals("hashCode")) return System.identityHashCode(proxy);
                if(method.getName().equals("equals")) return proxy==args[0];
                return "006IDC Camera Callback";
            }
            if(method.getName().equals("onStreamConfigured")) {
                int id=(Integer)args[0];
                Surface s=(Surface)args[1];
                inputs.put(id,s);
                log("stream",id+":"+args[2]+"x"+args[3]+":format="+args[4]);
            } else if(method.getName().equals("onStreamClosed")) {
                inputs.remove((Integer)args[0]);
                log("stream_closed",args[0]);
            }
            return null;
        });
        Class<?> configClass=Class.forName("android.companion.virtual.camera.VirtualCameraConfig");
        Object b=Class.forName(configClass.getName()+"$Builder").getConstructor(String.class).newInstance("006IDC desktop QR camera");
        call(b,"addStreamConfig",new Class[]{int.class,int.class,int.class,int.class},640,480,PixelFormat.RGBA_8888,30);
        call(b,"setLensFacing",new Class[]{int.class},CameraMetadata.LENS_FACING_BACK);
        call(b,"setSensorOrientation",new Class[]{int.class},0);
        call(b,"setVirtualCameraCallback",new Class[]{Executor.class,cbClass},callbacks,cb);
        Object config=call(b,"build",new Class[]{});
        camera=call(device,"createVirtualCamera",new Class[]{configClass},config);
        log("camera_id",call(camera,"getId",new Class[]{}));
        painter.scheduleAtFixedRate(()->{for(Surface s:inputs.values())paint(s);},0,66,TimeUnit.MILLISECONDS);
    }

    static void startDisplay() throws Exception {
        Handler handler=new Handler(handlerThread.getLooper());
        displayReader=ImageReader.newInstance(720,1280,PixelFormat.RGBA_8888,3);
        displayReader.setOnImageAvailableListener(r->{
            try(Image im=r.acquireLatestImage()) {
                if(im==null)return;
                Image.Plane plane=im.getPlanes()[0];
                int stride=plane.getRowStride()/plane.getPixelStride();
                Bitmap padded=Bitmap.createBitmap(stride,im.getHeight(),Bitmap.Config.ARGB_8888);
                padded.copyPixelsFromBuffer(plane.getBuffer());
                Bitmap actual=Bitmap.createBitmap(padded,0,0,im.getWidth(),im.getHeight());
                synchronized(frameLock){
                    if(latestDisplay!=null)latestDisplay.recycle();
                    latestDisplay=actual;
                }
                if(actual!=padded)padded.recycle();
            }catch(Exception e){if(!stopping)log("display_error",e.toString());}
        },handler);
        display=(VirtualDisplay)call(device,"createVirtualDisplay",new Class[]{int.class,int.class,int.class,Surface.class,int.class,Executor.class,VirtualDisplay.Callback.class},720,1280,320,displayReader.getSurface(),(DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY | DISPLAY_SUPPORTS_TOUCH | DISPLAY_TRUSTED | DISPLAY_OWN_FOCUS),callbacks,new VirtualDisplay.Callback(){});
        log("display_id",display.getDisplay().getDisplayId());
    }

    static void snapshotIfRequested() throws Exception {
        File request=new File(DIR+"snapshot");
        if(!request.exists())return;
        synchronized(frameLock){
            if(latestDisplay==null)return;
            File temp=new File(DIR+"display.png.tmp");
            try(FileOutputStream out=new FileOutputStream(temp)){
                if(!latestDisplay.compress(Bitmap.CompressFormat.PNG,100,out))throw new IOException("Snapshot encoding failed");
            }
            if(!temp.renameTo(new File(DIR+"display.png")))throw new IOException("Snapshot replacement failed");
            if(!request.delete())throw new IOException("Snapshot request cleanup failed");
        }
    }

    static synchronized void cleanup() {
        if(stopping)return;
        stopping=true;
        painter.shutdownNow();
        if(display!=null)try{display.release();}catch(Exception e){log("cleanup_error",e.toString());}
        if(displayReader!=null)try{displayReader.close();}catch(Exception e){log("cleanup_error",e.toString());}
        for(Object obj:new Object[]{camera,device})if(obj!=null)try{call(obj,"close",new Class[]{});}catch(Exception e){log("cleanup_error",e.toString());}
        callbacks.shutdownNow();
        if(handlerThread!=null)handlerThread.quitSafely();
        log("cleanup","closed_owned_camera_and_display");
    }

    static void inspect() throws Exception {
        log("uid", android.os.Process.myUid());
        log("package", context.getPackageName());
        log("attribution", context.getAttributionSource().getPackageName());
        log("create_virtual_device_permission", context.checkSelfPermission("android.permission.CREATE_VIRTUAL_DEVICE"));
        for (String name : new String[]{
            "android.companion.virtual.VirtualDeviceManager",
            "android.companion.virtual.VirtualDeviceManager$VirtualDevice",
            "android.companion.virtual.VirtualDeviceParams",
            "android.companion.virtual.VirtualDeviceParams$Builder",
            "android.companion.virtual.camera.VirtualCameraConfig$Builder",
            "android.companion.virtual.camera.VirtualCameraCallback",
            "android.hardware.display.VirtualDisplayConfig$Builder"}) {
            try {
                Class<?> c = Class.forName(name);
                log("class", name);
                for (Constructor<?> ctor : c.getConstructors()) log("constructor", ctor);
                for (Method m : c.getMethods()) {
                    if (m.getDeclaringClass() != Object.class && (m.getName().startsWith("create") || m.getName().startsWith("set") || m.getName().startsWith("add") || m.getName().startsWith("on") || m.getName().startsWith("isVirtualCamera") || m.getName().equals("close") || m.getName().equals("getCameraId"))) log("method", m);
                }
                for (Field f : c.getFields()) if (Modifier.isStatic(f.getModifiers()) && f.getType()==int.class) log("constant", f.getName()+":"+f.get(null));
            } catch (ClassNotFoundException e) { log("missing_class", name); }
        }
    }

    public static void main(String[] args) {
        int result = 0;
        try {
            context = shellContext();
            if(args.length==0||args[0].equals("inspect"))inspect();
            else {
                int association=Integer.parseInt(args[1]);
                int seconds=args.length>2?Integer.parseInt(args[2]):120;
                source=BitmapFactory.decodeFile(DIR+"test-qr.png");
                if(source==null)throw new IOException("Missing generated test QR");
                handlerThread=new HandlerThread("006IDC-QR-callbacks");handlerThread.start();
                Runtime.getRuntime().addShutdownHook(new Thread(CameraProbe::cleanup));
                create(association);
                if(args[0].equals("serve")) {
                    startDisplay();
                    log("ready","virtual_camera_and_display");
                    long end=System.currentTimeMillis()+Math.min(seconds,600)*1000L;
                    while(System.currentTimeMillis()<end && !new File(DIR+"stop").exists()){snapshotIfRequested();Thread.sleep(100);}
                }
            }
        } catch (Throwable e) {
            while (e instanceof InvocationTargetException && e.getCause()!=null) e=e.getCause();
            log("error", e.getClass().getName()+": "+e.getMessage());
            e.printStackTrace(System.err);
            result = 1;
        } finally {
            cleanup();
        }
        System.exit(result);
    }
}
