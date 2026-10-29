import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Process;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

final class LauncherCatalog {
    static byte[] query(Context context,String packageFilter) throws Exception {
        if(Process.myUid()/100000!=0) throw new IOException("Primary user required");
        if(packageFilter!=null && !LauncherPackageQuery.valid(packageFilter)) throw new IOException("Invalid launcher package");
        // Keep MAIN/LAUNCHER resolution. Setting a component here would bypass
        // intent filters and could authorize a non-launcher activity.
        Intent launcher=new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        if(packageFilter!=null) launcher.setPackage(packageFilter);
        PackageManager pm=context.getPackageManager();
        List<ResolveInfo> resolved=pm.queryIntentActivities(launcher,PackageManager.MATCH_DIRECT_BOOT_AWARE|PackageManager.MATCH_DIRECT_BOOT_UNAWARE);
        JSONArray entries=new JSONArray();HashSet<String> seen=new HashSet<>();
        for(ResolveInfo entry:resolved) {
            if(entries.length()>=500) break;
            if(entry.activityInfo==null || !entry.activityInfo.exported || !entry.activityInfo.enabled ||
                    entry.activityInfo.applicationInfo==null || !entry.activityInfo.applicationInfo.enabled) continue;
            String pkg=entry.activityInfo.packageName,cls=entry.activityInfo.name;
            if(pkg==null || cls==null || !pkg.matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+") ||
                    !cls.matches("[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*)*")) continue;
            if(packageFilter!=null && !packageFilter.equals(pkg)) continue;
            String component=new ComponentName(pkg,cls).flattenToString();if(!seen.add(component))continue;
            String label=String.valueOf(entry.loadLabel(pm)).replaceAll("[\\p{Cntrl}]"," ");
            if(label.length()>160)label=label.substring(0,160);
            entries.put(new JSONObject().put("packageName",pkg).put("component",component).put("name",label));
        }
        return entries.toString().getBytes(StandardCharsets.UTF_8);
    }
}
