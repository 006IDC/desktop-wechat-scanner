import java.security.SecureRandom;

/** Per-lease spatial carrier. Its blue intensity is removed by the native UI
 * renderer; the random field distinguishes a real key frame from a blue desktop.
 * It is not an authentication token and is never logged or persisted.
 */
final class NativePreviewPattern {
    static final int COLUMNS = 9, ROWS = 16, LOW = 192, HIGH = 255;
    private final boolean[] bits = new boolean[COLUMNS * ROWS];
    NativePreviewPattern() {
        SecureRandom random = new SecureRandom();
        int high;
        do {
            high = 0;
            for (int i = 0; i < bits.length; i++) { bits[i] = random.nextBoolean(); if (bits[i]) high++; }
        } while (high < 48 || high > bits.length - 48);
    }
    int blue(int column, int row) {
        if (column < 0 || column >= COLUMNS || row < 0 || row >= ROWS)
            throw new IllegalArgumentException("Invalid key cell");
        return bits[row * COLUMNS + column] ? HIGH : LOW;
    }
}
