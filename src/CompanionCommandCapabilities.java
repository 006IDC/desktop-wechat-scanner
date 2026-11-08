import java.lang.reflect.*;
import org.json.JSONObject;
import org.json.JSONArray;
import android.companion.CompanionDeviceManager;
import android.content.Context;
import android.os.Process;
import java.util.List;

/** Read a public runtime feature getter. Never change flags or create devices. */
public final class CompanionCommandCapabilities {
    public static void main(String[] args) throws Exception {
        boolean association=args.length==2 && args[0].equals("association") && args[1].matches("02:06:1D:([0-9A-F]{2}:){2}[0-9A-F]{2}");
        if (args.length!=0 && !association) throw new IllegalArgumentException("Unsupported probe arguments");
        Thread deadline=new Thread(()->{
            try {Thread.sleep(5_000);} catch(InterruptedException done) {return;}
            System.exit(70); // Only this short-lived helper process, no resources.
        },"006idc-read-command-capabilities-deadline");
        deadline.setDaemon(true);deadline.start();
        JSONObject result=new JSONObject().put("version",1);
        if (association) {
            if (Process.myUid()/100000!=0) throw new SecurityException("Expected shell main user");
            Context context=CameraProbe.shellContext();
            CompanionDeviceManager manager=context.getSystemService(CompanionDeviceManager.class);
            if (manager==null) throw new IllegalStateException("Companion manager unavailable");
            List<?> entries=manager.getMyAssociations();
            if (entries==null || entries.size()>4096) throw new IllegalStateException("Unconfirmed association list");
            JSONArray ids=new JSONArray();
            for (Object entry:entries) {
                Class<?> type=entry.getClass();
                Object address=type.getMethod("getDeviceMacAddress").invoke(entry);
                if (address==null || !args[1].equalsIgnoreCase(address.toString())) continue;
                String owner=(String)type.getMethod("getPackageName").invoke(entry);
                int user=(Integer)type.getMethod("getUserId").invoke(entry);
                String profile=(String)type.getMethod("getDeviceProfile").invoke(entry);
                int id=(Integer)type.getMethod("getId").invoke(entry);
                if (!"com.android.shell".equals(owner) || user!=0 || id<=0 ||
                    !"android.app.role.COMPANION_DEVICE_APP_STREAMING".equals(profile))
                    throw new SecurityException("Association ownership/profile mismatch");
                ids.put(id);
            }
            result.put("associationKnown",true).put("targetMAC",args[1]).put("userId",0)
                  .put("ownerPackage","com.android.shell").put("associationIDs",ids);
        } else {
            result.put("cmdOptionsKnown",false);
            try {
                Class<?> flags=Class.forName("com.android.internal.hidden_from_bootclasspath.android.companion.Flags");
                Object value=flags.getMethod("cmdOptions").invoke(null);
                if (value instanceof Boolean) result.put("cmdOptionsKnown",true).put("cmdOptions",value);
            } catch(ReflectiveOperationException|LinkageError unavailable) {
                // Missing/unsupported getter remains unknown; never assume enabled.
            }
        }
        System.out.println(result.toString());System.out.flush();
        deadline.interrupt();System.exit(0);
    }
}
