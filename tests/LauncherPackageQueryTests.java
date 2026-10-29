import java.io.IOException;
import java.nio.charset.StandardCharsets;
public final class LauncherPackageQueryTests {
    private static void rejected(byte[] data)throws Exception {
        try {LauncherPackageQuery.parse(data);throw new AssertionError("Invalid query accepted");}catch(IOException expected){}
    }
    public static void main(String[] args)throws Exception {
        if(LauncherPackageQuery.parse(new byte[0])!=null)throw new AssertionError();
        if(!"com.example.camera".equals(LauncherPackageQuery.parse("com.example.camera".getBytes(StandardCharsets.UTF_8))))throw new AssertionError();
        String boundary="a."+"b".repeat(253);
        if(!boundary.equals(LauncherPackageQuery.parse(boundary.getBytes(StandardCharsets.UTF_8))))throw new AssertionError();
        for(String invalid:new String[]{"single","com.example/.Home","com.example\n","com.example;cmd",boundary+"b"})rejected(invalid.getBytes(StandardCharsets.UTF_8));
        rejected(null);rejected(new byte[]{(byte)0xc0,(byte)0xaf});rejected(new byte[]{0});
        System.out.println("PASS empty legacy query, bounded package restriction, malformed UTF-8 and component/injection rejection");
    }
}
