public final class DesktopDisplayGeometryTests {
    static void check(int width, int height, int dpi) {
        DesktopDisplayGeometry result = DesktopDisplayGeometry.fromPrimary(width, height, dpi);
        if (result.width <= 0 || result.height <= 0 || result.width % 2 != 0 || result.height % 2 != 0 ||
                Math.max(result.width, result.height) > 1600 || result.dpi <= 0) throw new AssertionError("bounds");
        double inputWidthDp = width * 160.0 / dpi, outputWidthDp = result.width * 160.0 / result.dpi;
        double inputHeightDp = height * 160.0 / dpi, outputHeightDp = result.height * 160.0 / result.dpi;
        if (Math.abs(outputWidthDp / inputWidthDp - 1) > 0.02 ||
                Math.abs(outputHeightDp / inputHeightDp - 1) > 0.02) throw new AssertionError("dp layout changed");
    }
    public static void main(String[] args) {
        for (int[] geometry : new int[][]{{1268,2756,560},{2756,1268,560},{1080,2400,440},
                {1440,3200,640},{720,1280,320},{4096,4096,1000},{1081,1921,420}})
            check(geometry[0],geometry[1],geometry[2]);
        DesktopDisplayGeometry nativeSmall = DesktopDisplayGeometry.fromPrimary(720,1280,320);
        if (nativeSmall.width != 720 || nativeSmall.height != 1280 || nativeSmall.dpi != 320)
            throw new AssertionError("small display changed");
        DesktopDisplayGeometry large = DesktopDisplayGeometry.fromPrimary(1268,2756,560);
        if (large.width != 736 || large.height != 1600 || large.dpi != 325)
            throw new AssertionError("observed phone dimensions");
        for (int[] bad : new int[][]{{0,2400,440},{1080,0,440},{1080,2400,0},{5000,2400,440}}) {
            try { DesktopDisplayGeometry.fromPrimary(bad[0],bad[1],bad[2]); throw new AssertionError("invalid accepted"); }
            catch (IllegalArgumentException expected) {}
        }
        System.out.println("PASS owned display cap, portrait/landscape, density layout, parity, invalid bounds");
    }
}
