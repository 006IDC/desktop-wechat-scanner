import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.LinkedHashSet;

/** Connection-owned input selection. Caller holds stateLock and verifies display/catalog ownership. */
final class DesktopCameraRouting {
    static final int MAX_BINDINGS = 8;
    static final class Request {
        final int action, display;
        final String packageName;
        Request(int action, int display, String packageName) {this.action=action;this.display=display;this.packageName=packageName;}
        static Request parse(byte[] body) throws IOException {
            if (body == null || body.length < 1 || body.length > 260) throw new IOException("Invalid camera source payload");
            int action=body[0]&255;
            if (action==2 && body.length==1) return new Request(2,0,null);
            if ((action!=0 && action!=1) || body.length<5) throw new IOException("Invalid camera source action");
            int display=ByteBuffer.wrap(body,1,4).getInt();
            if (display<=0) throw new IOException("An owned display is required");
            if (action==0) {
                if (body.length!=5) throw new IOException("Clear source must not include a package");
                return new Request(0,display,null);
            }
            String pkg;
            try {pkg=StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(body,5,body.length-5)).toString();}
            catch (CharacterCodingException invalid) {throw new IOException("Invalid source package encoding");}
            if (!validPackage(pkg)) throw new IOException("Invalid source package");
            return new Request(1,display,pkg);
        }
    }
    interface Change {void run() throws Exception;}
    static void grantAndBind(Change grant,Change bind,Change revokeUnused) throws Exception {
        try {grant.run();bind.run();}
        catch (Exception failure) {
            try {revokeUnused.run();} catch(Exception cleanup) {failure.addSuppressed(cleanup);}
            throw failure;
        }
    }
    private boolean enabled;
    private long generation;
    private final LinkedHashMap<Integer,String> bindings=new LinkedHashMap<>();
    static boolean validPackage(String pkg) {
        return pkg!=null && pkg.length()<=255 && pkg.matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+");
    }
    boolean enabled() {return enabled;}
    long generation() {return generation;}
    void enable() {if (!enabled) {enabled=true;generation++;}}
    Map<Integer,String> snapshot() {return new LinkedHashMap<>(bindings);}
    String clear(int display) {String old=bindings.remove(display);if(old!=null) generation++;return old;}
    void bind(int display,String pkg) throws IOException {
        if (!enabled || display<=0 || !validPackage(pkg)) throw new IOException("Invalid desktop camera binding");
        if (!bindings.containsKey(display) && bindings.size()>=MAX_BINDINGS) throw new IOException("Too many camera windows");
        if (!pkg.equals(bindings.put(display,pkg))) generation++;
    }
    boolean uses(String pkg) {return bindings.containsValue(pkg);}
    Set<String> unusedPackages(Set<String> granted) {
        Set<String> unused=new LinkedHashSet<>();
        if(enabled) for(String pkg:granted) if(!uses(pkg)) unused.add(pkg);
        return unused;
    }
    int authorizedDisplay(String owner,Map<Integer,String> activities,int primaryDisplay,Map<Integer,?> otherDisplays) {
        if (!enabled || !validPackage(owner)) return -1;
        int match=-1;
        for (Map.Entry<Integer,String> activity:activities.entrySet()) {
            int display=activity.getKey();String component=activity.getValue();
            if (display<=0 || (display!=primaryDisplay && !otherDisplays.containsKey(display)) ||
                    component==null || !component.startsWith(owner+"/")) continue;
            // A package-level camera callback cannot choose between two app windows.
            if (match>=0 || !owner.equals(bindings.get(display))) return -1;
            match=display;
        }
        return match;
    }
}
