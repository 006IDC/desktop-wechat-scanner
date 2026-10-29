import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

/** Optional command-10 package restriction, never an explicit component. */
final class LauncherPackageQuery {
    static boolean valid(String pkg) {
        return pkg!=null && pkg.length()<=255 && pkg.matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+");
    }
    static String parse(byte[] body) throws IOException {
        if(body==null || body.length>255) throw new IOException("Invalid launcher query");
        if(body.length==0) return null;
        String pkg;
        try {pkg=StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(body)).toString();}
        catch(CharacterCodingException invalid) {throw new IOException("Invalid launcher query encoding");}
        if(!valid(pkg)) throw new IOException("Invalid launcher package");
        return pkg;
    }
}
