import android.content.Context;
import android.content.pm.PackageManager;
import android.os.UserHandle;

/** Grant only CAMERA, only in an existing non-default test virtual device. */
public final class GrantProbe {
    public static void main(String[] args) throws Exception {
        int id=Integer.parseInt(args[0]);
        String pkg=args[1];
        if(id<=0 || !(pkg.equals("com.idc006.qrprobe") || pkg.equals("com.tencent.mm")))
            throw new IllegalArgumentException("Only the test virtual device and test consumers are allowed");
        Context dc=CameraProbe.shellContext().createDeviceContext(id);
        if(dc.getDeviceId()!=id)throw new IllegalStateException("Virtual context mismatch");
        PackageManager pm=dc.getPackageManager();
        boolean revoke=args.length>2 && args[2].equals("revoke");
        pm.getClass().getMethod(revoke?"revokeRuntimePermission":"grantRuntimePermission",String.class,String.class,UserHandle.class)
            .invoke(pm,pkg,"android.permission.CAMERA",android.os.Process.myUserHandle());
        System.out.println("QR_PROBE camera_permission="+(revoke?"revoked":"granted")+" device="+id+" package="+pkg);
        System.exit(0);
    }
}
