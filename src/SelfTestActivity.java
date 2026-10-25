package com.idc006.qrprobe;

import android.app.Activity;
import android.os.*;
import android.graphics.*;
import android.hardware.camera2.*;
import android.media.*;
import android.widget.*;
import java.io.*;
import java.nio.ByteBuffer;
import java.util.*;

/** Reads only a camera in the expected virtual device; refuses the default device. */
public final class SelfTestActivity extends Activity {
    HandlerThread worker;
    Handler handler;
    CameraDevice camera;
    CameraCaptureSession session;
    ImageReader reader;
    TextView status;
    int frames;
    boolean completed;

    void report(String s) {
        runOnUiThread(()->status.setText(s));
        try(FileOutputStream f=openFileOutput("result.txt",MODE_PRIVATE)){f.write(s.getBytes("UTF-8"));}catch(Exception ignored){}
    }

    @Override public void onCreate(Bundle b) {
        super.onCreate(b);
        status=new TextView(this);status.setTextSize(22);status.setPadding(24,40,24,24);setContentView(status);
        int expected=getIntent().getIntExtra("deviceId",-1);
        if(getDeviceId()==0 || getDeviceId()!=expected){report("REFUSED: not in expected virtual device (actual="+getDeviceId()+")");return;}
        worker=new HandlerThread("qr-self-test");worker.start();handler=new Handler(worker.getLooper());
        handler.post(()->startCamera(expected));
    }

    void startCamera(int deviceId) {
        try {
            CameraManager cm=getSystemService(CameraManager.class);
            String[] ids=cm.getCameraIdList();
            // Android 16 maps a virtual back camera to app-visible ID 0.
            String expected="0";
            report("Virtual device="+deviceId+" camera ids="+Arrays.toString(ids));
            if(ids.length!=1 || !Arrays.asList(ids).contains(expected))throw new IllegalStateException("Expected virtual camera not visible: "+expected);
            reader=ImageReader.newInstance(640,480,ImageFormat.YUV_420_888,3);
            reader.setOnImageAvailableListener(r->{
                try(Image image=r.acquireLatestImage()) {
                    if(image!=null && !completed && ++frames>=8){
                        save(image);completed=true;
                        report("CAPTURED: device="+deviceId+" camera="+expected+" frames="+frames);
                        handler.post(this::closeCamera);
                    }
                }catch(Exception e){report("ERROR: "+e);}
            },handler);
            cm.openCamera(expected,new CameraDevice.StateCallback(){
                @Override public void onOpened(CameraDevice d) {
                    camera=d;
                    try {
                        d.createCaptureSession(Collections.singletonList(reader.getSurface()),new CameraCaptureSession.StateCallback(){
                            @Override public void onConfigured(CameraCaptureSession s){
                                session=s;
                                try {
                                    CaptureRequest.Builder req=d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
                                    req.addTarget(reader.getSurface());s.setRepeatingRequest(req.build(),null,handler);
                                }catch(Exception e){report("ERROR: "+e);}
                            }
                            @Override public void onConfigureFailed(CameraCaptureSession s){report("ERROR: capture session rejected");}
                        },handler);
                    }catch(Exception e){report("ERROR: "+e);}
                }
                @Override public void onError(CameraDevice d,int e){report("ERROR: camera error "+e);d.close();}
                @Override public void onDisconnected(CameraDevice d){d.close();}
            },handler);
        }catch(Exception e){report("ERROR: "+e);}
    }

    void save(Image image)throws Exception {
        int w=image.getWidth(),h=image.getHeight();byte[] nv21=new byte[w*h*3/2];
        Image.Plane[] planes=image.getPlanes();
        for(int p=0;p<3;p++) {
            ByteBuffer buf=planes[p].getBuffer();int rw=p==0?w:w/2,rh=p==0?h:h/2;
            for(int y=0;y<rh;y++)for(int x=0;x<rw;x++) {
                byte v=buf.get(y*planes[p].getRowStride()+x*planes[p].getPixelStride());
                if(p==0)nv21[y*w+x]=v;else nv21[w*h+y*w+x*2+(p==1?1:0)]=v;
            }
        }
        try(FileOutputStream out=openFileOutput("readback.jpg",MODE_PRIVATE)) {
            if(!new YuvImage(nv21,ImageFormat.NV21,w,h,null).compressToJpeg(new Rect(0,0,w,h),95,out))throw new IOException("JPEG encoding failed");
        }
    }

    void closeCamera(){
        if(session!=null){session.close();session=null;}
        if(camera!=null){camera.close();camera=null;}
        if(reader!=null){reader.close();reader=null;}
    }
    @Override public void onDestroy(){closeCamera();if(worker!=null)worker.quitSafely();super.onDestroy();}
}
