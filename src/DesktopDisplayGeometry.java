/** Geometry for an owned app display. Never changes the physical phone display. */
final class DesktopDisplayGeometry {
    static final int MAX_SIDE = 1600;
    final int width, height, dpi;
    private DesktopDisplayGeometry(int width, int height, int dpi) {
        this.width = width; this.height = height; this.dpi = dpi;
    }
    static DesktopDisplayGeometry fromPrimary(int width, int height, int dpi) {
        if (width < 64 || height < 64 || width > 4096 || height > 4096 || dpi < 72 || dpi > 1000)
            throw new IllegalArgumentException("Invalid primary display geometry");
        double scale = Math.min(1.0, (double) MAX_SIDE / Math.max(width, height));
        // AVC input needs even dimensions; scale density with pixels so the
        // Android dp layout, text size and touch proportions stay consistent.
        int scaledWidth = Math.max(2, ((int) Math.round(width * scale)) & ~1);
        int scaledHeight = Math.max(2, ((int) Math.round(height * scale)) & ~1);
        int scaledDpi = Math.max(1, (int) Math.round(dpi * scale));
        return new DesktopDisplayGeometry(scaledWidth, scaledHeight, scaledDpi);
    }
}
