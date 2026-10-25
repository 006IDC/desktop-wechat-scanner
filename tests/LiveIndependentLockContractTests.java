/** Standalone JVM contract tests. No Android Context/device/API call executes. */
public final class LiveIndependentLockContractTests {
    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private static void rejects(Runnable action, String message) {
        boolean rejected = false;
        try { action.run(); } catch (IllegalArgumentException | IllegalStateException | SecurityException expected) { rejected = true; }
        require(rejected, message);
    }
    public static void main(String[] unused) {
        String[] legacy = {"1", "006idc_scan_01234567", "0123456789abcdef0123456789abcdef"};
        String[] independent = {legacy[0], legacy[1], legacy[2], "independent-lock"};
        require(!LiveCameraServer.requestedIndependentLock(legacy), "Three-argument legacy mode changed");
        require(LiveCameraServer.requestedIndependentLock(independent), "Explicit independent-lock request rejected");
        for (String flag : new String[]{"", "true", "unlock", "independent-lock-extra", "independent-lock "}) {
            rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{legacy[0], legacy[1], legacy[2], flag}), "Unknown fourth argument accepted");
        }
        rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{}), "Missing arguments accepted");
        rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{legacy[0], legacy[1], legacy[2], "independent-lock", "extra"}), "Extra arguments accepted");
        rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{legacy[0], "unscoped_socket", legacy[2], "independent-lock"}), "Unscoped socket accepted");
        rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{legacy[0], legacy[1], "invalid", "independent-lock"}), "Malformed token accepted");

        LiveCameraServer.requireIndependentLockPrerequisites(0, true, true);
        rejects(() -> LiveCameraServer.requireIndependentLockPrerequisites(10, true, true), "Secondary user accepted");
        rejects(() -> LiveCameraServer.requireIndependentLockPrerequisites(0, false, true), "Pre-first-unlock user accepted");
        rejects(() -> LiveCameraServer.requireIndependentLockPrerequisites(0, true, false), "Missing existing permission accepted");
        require(!LiveCameraServer.verifyIndependentDisplayFlags(false, -1, false, 0, 0), "Default mode unexpectedly advertised independent lock");
        require(LiveCameraServer.verifyIndependentDisplayFlags(true, 7, true, 1 << 9, 1 << 9), "Actual Display always-unlocked flag rejected");
        require(LiveCameraServer.verifyIndependentDisplayFlags(true, 7, true, (1 << 9) | (1 << 14), 1 << 9), "Unrelated actual flags affected readiness");
        rejects(() -> LiveCameraServer.verifyIndependentDisplayFlags(true, 7, true, 1 << 12, 1 << 9), "VirtualDisplay request bit confused with actual Display flag");
        rejects(() -> LiveCameraServer.verifyIndependentDisplayFlags(true, 7, true, 1 << 12, 1 << 12), "Unexpected platform flag definition accepted");
        rejects(() -> LiveCameraServer.verifyIndependentDisplayFlags(true, 0, true, 1 << 9, 1 << 9), "Primary physical display accepted");
        rejects(() -> LiveCameraServer.verifyIndependentDisplayFlags(true, 7, false, 1 << 9, 1 << 9), "Invalid display accepted");
        rejects(() -> LiveCameraServer.verifyIndependentDisplayFlags(true, 7, true, 0, 1 << 9), "Requested-but-ineffective policy accepted");
        require(LiveCameraServer.independentDisplayOn(7, true, 2), "STATE_ON was not accepted");
        for (int state : new int[]{0, 1, 3, 4, 6})
            require(!LiveCameraServer.independentDisplayOn(7, true, state), "Non-ON power state reported ready");
        rejects(() -> LiveCameraServer.independentDisplayOn(0, true, 2), "Primary display accepted as a wake target");
        rejects(() -> LiveCameraServer.independentDisplayOn(7, false, 2), "Invalid power target accepted");
        LiveCameraServer.verifyPrimaryDisplayPower(1, 1);
        LiveCameraServer.verifyPrimaryDisplayPower(2, 2);
        LiveCameraServer.verifyPrimaryDisplayPower(2, 1);
        rejects(() -> LiveCameraServer.verifyPrimaryDisplayPower(1, 2), "Physical OFF-to-ON wake accepted");
        System.out.println("PASS legacy/explicit mode, exact argument contract, primary-user first unlock and existing permission gates, actual Display flag and owned ON-state verification; no Android runtime/device calls");
    }
}
