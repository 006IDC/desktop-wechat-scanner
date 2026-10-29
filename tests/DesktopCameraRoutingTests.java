import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class DesktopCameraRoutingTests {
    interface Test {void run() throws Exception;}
    static void require(boolean value,String message) {if(!value) throw new AssertionError(message);}
    static void rejects(Test code) throws Exception {try{code.run();}catch(IOException expected){return;}throw new AssertionError("Invalid source accepted");}
    static byte[] body(int action,int display,String pkg) {
        byte[] bytes=pkg==null ? new byte[0]:pkg.getBytes(StandardCharsets.UTF_8);
        return ByteBuffer.allocate(5+bytes.length).put((byte)action).putInt(display).put(bytes).array();
    }
    public static void main(String[] args) throws Exception {
        require(DesktopCameraRouting.Request.parse(new byte[]{2}).action==2,"Mode negotiation failed");
        var parsed=DesktopCameraRouting.Request.parse(body(1,0x01020304,"org.example.scanner"));
        require(parsed.display==0x01020304 && parsed.packageName.equals("org.example.scanner"),"Binding wire order changed");
        require(DesktopCameraRouting.Request.parse(body(0,7,null)).packageName==null,"Clear source has a package");
        for(byte[] invalid:new byte[][]{null,new byte[0],new byte[261],new byte[]{2,0},body(9,7,null),body(1,0,"org.example"),body(1,-1,"org.example"),body(1,7,""),body(1,7,"org.example;bad"),body(0,7,"org.example"),new byte[]{1,0,0,0,7,(byte)0xc3,0x28}})
            rejects(()->DesktopCameraRouting.Request.parse(invalid));
        DesktopCameraRouting routing=new DesktopCameraRouting();
        String app="org.example.unadapted",component=app+"/.AnyCameraPage";
        rejects(()->routing.bind(7,app));routing.enable();long enabled=routing.generation();
        require(routing.authorizedDisplay(app,Map.of(7,component),7,Map.of())==-1,"Enable alone authorizes capture");
        routing.bind(7,app);require(routing.generation()>enabled,"Binding did not advance generation");
        require(routing.authorizedDisplay(app,Map.of(7,component),7,Map.of())==7,"Unadapted app requires a hardcoded scan route");
        require(routing.authorizedDisplay("org.other",Map.of(7,component),7,Map.of())==-1,"Wrong camera owner accepted");
        require(routing.authorizedDisplay(app,Map.of(7,component),9,Map.of())==-1,"Unowned display accepted");
        require(routing.authorizedDisplay(app,Map.of(7,component,8,app+"/.Other"),7,Map.of(8,"owned"))==-1,"Ambiguous same-app windows accepted");
        require(routing.authorizedDisplay(app,Map.of(7,component,8,"org.other/.Main"),7,Map.of(8,"owned"))==7,"Unrelated window blocked selected source");
        long bound=routing.generation();require(routing.clear(7).equals(app) && routing.generation()>bound,"Clear did not invalidate source");
        require(routing.authorizedDisplay(app,Map.of(7,component),7,Map.of())==-1,"Cleared source still authorizes pixels");
        for(int i=1;i<=8;i++) routing.bind(i,"org.example.app"+i);
        rejects(()->routing.bind(9,app));
        require(routing.snapshot().size()==8,"Binding overflow changed policy");
        Map<Integer,String> copy=routing.snapshot();copy.clear();require(routing.snapshot().size()==8,"Snapshot mutates source bindings");

        // Exercise the exact permission transaction used by LiveCameraServer.
        for(boolean grantFails:new boolean[]{true,false}) {
            Set<String> grants=new HashSet<>();int[] bindCalls={0},revokeCalls={0};
            IOException original=new IOException(grantFails ? "uncertain Binder reply":"display closed before bind");
            try {
                DesktopCameraRouting.grantAndBind(()->{grants.add(app);if(grantFails) throw original;},
                    ()->{bindCalls[0]++;throw original;},()->{revokeCalls[0]++;grants.remove(app);});
                throw new AssertionError("Grant/bind failure accepted");
            } catch(IOException failure) {require(failure==original,"Original permission failure lost");}
            require(grants.isEmpty() && revokeCalls[0]==1 && bindCalls[0]==(grantFails?0:1),"Partial grant was not compensated");
        }
        IOException original=new IOException("bind failed"),cleanup=new IOException("revoke failed");
        try {DesktopCameraRouting.grantAndBind(()->{},()->{throw original;},()->{throw cleanup;});throw new AssertionError("Uncertain cleanup accepted");}
        catch(IOException failure) {require(failure==original && failure.getSuppressed().length==1 && failure.getSuppressed()[0]==cleanup,"Cleanup failure evidence lost");}
        DesktopCameraRouting cleanupPolicy=new DesktopCameraRouting();
        Set<String> granted=Set.of("com.tencent.mm","com.eg.android.AlipayGphone");
        cleanupPolicy.clear(7);
        require(cleanupPolicy.unusedPackages(granted).isEmpty(),"Legacy display close revoked compatibility grants");
        cleanupPolicy.enable();cleanupPolicy.bind(7,"com.tencent.mm");cleanupPolicy.bind(8,"com.tencent.mm");
        cleanupPolicy.clear(7);
        require(cleanupPolicy.unusedPackages(granted).equals(Set.of("com.eg.android.AlipayGphone")),"Shared package grant revoked while another binding uses it");
        cleanupPolicy.clear(8);
        require(cleanupPolicy.unusedPackages(granted).equals(granted),"Last binding did not release package grant");
        require(cleanupPolicy.unusedPackages(granted).equals(granted),"Uncertain revoke not available for retry");
        routing.clear(1);require(routing.authorizedDisplay("org.example.app1",Map.of(1,"org.example.app1/.Camera"),1,Map.of())==-1,
                "A revoke failure could reactivate the removed binding");
        System.out.println("PASS generic source parsing, third-app routing, ownership/ambiguity, invalidation, bounds and permission rollback");
    }
}
