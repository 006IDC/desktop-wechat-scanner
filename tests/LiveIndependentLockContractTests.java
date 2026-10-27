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
        String[] desktop = {legacy[0], legacy[1], legacy[2], "desktop-home"};
        String[] both = {legacy[0], legacy[1], legacy[2], "desktop-home", "independent-lock"};
        require(!LiveCameraServer.requestedIndependentLock(legacy), "Three-argument legacy mode changed");
        require(!LiveCameraServer.requestedDesktopHome(legacy), "Legacy mode unexpectedly enabled desktop HOME");
        require(LiveCameraServer.requestedIndependentLock(independent), "Explicit independent-lock request rejected");
        require(!LiveCameraServer.requestedDesktopHome(independent), "Independent lock unexpectedly enabled desktop HOME");
        require(!LiveCameraServer.requestedIndependentLock(desktop), "Desktop HOME unexpectedly enabled independent lock");
        require(LiveCameraServer.requestedDesktopHome(desktop), "Explicit desktop HOME request rejected");
        require(LiveCameraServer.requestedIndependentLock(both) && LiveCameraServer.requestedDesktopHome(both), "Combined flags rejected");
        require(LiveCameraServer.requestedIndependentLock(new String[]{legacy[0], legacy[1], legacy[2], "independent-lock", "desktop-home"}), "Reverse flag order rejected");
        require(java.util.Arrays.equals(LiveCameraServer.cameraPackagesForMode(false), new String[]{"com.tencent.mm"}), "Legacy camera grant scope expanded");
        require(java.util.Arrays.equals(LiveCameraServer.cameraPackagesForMode(true),
                new String[]{"com.tencent.mm", "com.eg.android.AlipayGphone"}), "Desktop camera grant scope is not exactly WeChat and Alipay");
        require(LiveCameraServer.isOwnedCameraEvent("virtual-7", "virtual-7"), "Own virtual camera event filtered");
        require(!LiveCameraServer.isOwnedCameraEvent("virtual-7", "physical-0"), "Physical camera event accepted");
        require(!LiveCameraServer.isOwnedCameraEvent(null, "virtual-7"), "Unknown owned camera ID accepted");
        require(!LiveCameraServer.isOwnedCameraEvent("", ""), "Empty camera ID accepted");
        require(LiveCameraServer.isOwnedCameraEvent("virtual-7", "0", "0"), "Verified mapped alias filtered");
        require(!LiveCameraServer.isOwnedCameraEvent("virtual-7", null, "0"), "Unverified physical alias accepted");
        require(!LiveCameraServer.isOwnedCameraEvent("virtual-7", "0", "1"), "Unrelated camera ID accepted");
        require("0".equals(LiveCameraServer.verifiedMappedBackCameraId(7, true,
                new String[]{"0", "1"}, java.util.Map.of("0", 1, "1", 0), java.util.Map.of("0", 7, "1", 0))),
                "Virtual-device-tagged BACK alias rejected");
        require(LiveCameraServer.verifiedMappedBackCameraId(7, true,
                new String[]{"0"}, java.util.Map.of("0", 1), java.util.Map.of("0", 0)) == null,
                "Physical camera with ID 0 accepted");
        require(LiveCameraServer.verifiedMappedBackCameraId(7, true,
                new String[]{"0"}, java.util.Map.of("0", 1), java.util.Map.of()) == null,
                "Missing virtual device metadata accepted");
        require(LiveCameraServer.verifiedMappedBackCameraId(7, false,
                new String[]{"0"}, java.util.Map.of("0", 1), java.util.Map.of("0", 7)) == null,
                "Default camera policy accepted alias");
        require(LiveCameraServer.verifiedMappedBackCameraId(7, true,
                new String[]{"0", "2"}, java.util.Map.of("0", 1, "2", 1), java.util.Map.of("0", 7, "2", 7)) == null,
                "Ambiguous virtual BACK alias accepted");
        require(LiveCameraServer.verifiedMappedBackCameraId(7, true,
                new String[]{"1"}, java.util.Map.of("1", 1), java.util.Map.of("1", 7)) == null,
                "Nonzero BACK alias accepted");
        String scanner = "com.tencent.mm/com.tencent.mm.plugin.scanner.ui.BaseScanUI";
        require(LiveCameraServer.isVerifiedScanner(scanner), "Verified full WeChat scanner rejected");
        require(LiveCameraServer.isVerifiedScanner("com.tencent.mm/.plugin.scanner.ui.BaseScanUI"), "Verified short WeChat scanner rejected");
        require(!LiveCameraServer.isVerifiedScanner("com.tencent.mm/.plugin.scanner.ui.OtherScanUI"), "Unverified WeChat scanner accepted");
        require(!LiveCameraServer.isVerifiedScanner("com.eg.android.AlipayGphone/.scan.ScanActivity"), "Unverified Alipay scanner accepted");
        String alipayScanner = "com.eg.android.AlipayGphone/com.alipay.mobile.scan.as.main.MainCaptureActivity";
        require(LiveCameraServer.isVerifiedScanner(alipayScanner), "Verified full Alipay scanner rejected");
        require(LiveCameraServer.scannerDisplayForOwner("com.eg.android.AlipayGphone",
                java.util.Map.of(7, alipayScanner), 7, java.util.Map.of()) == 7,
                "Owned Alipay scanner/owner pair rejected");
        require(LiveCameraServer.scannerDisplayForOwner("com.tencent.mm",
                java.util.Map.of(7, alipayScanner), 7, java.util.Map.of()) == -1,
                "WeChat camera owner routed to Alipay scanner");
        require(LiveCameraServer.scannerDisplayForOwner("com.eg.android.AlipayGphone",
                java.util.Map.of(7, alipayScanner, 11, "com.eg.android.AlipayGphone/.ui.LauncherActivity"),
                7, java.util.Map.of(11, "owned")) == -1,
                "Ambiguous second Alipay window accepted");
        java.util.Map<Integer, String> scannerOnly = java.util.Map.of(7, scanner);
        require(LiveCameraServer.scannerDisplayForOwner("com.tencent.mm", scannerOnly, 7, java.util.Map.of()) == 7,
                "Owned scanner/owner pair rejected");
        require(LiveCameraServer.scannerDisplayForOwner("com.eg.android.AlipayGphone", scannerOnly, 7, java.util.Map.of()) == -1,
                "Another camera owner routed to WeChat scanner");
        require(LiveCameraServer.scannerDisplayForOwner("com.tencent.mm", java.util.Map.of(8, scanner), 7, java.util.Map.of()) == -1,
                "Unowned scanner display accepted");
        require(LiveCameraServer.scannerDisplayForOwner("com.tencent.mm",
                java.util.Map.of(7, scanner, 11, "com.tencent.mm/.ui.LauncherUI"), 7, java.util.Map.of(11, "owned")) == -1,
                "Ambiguous second WeChat window accepted");
        require(LiveCameraServer.scannerDisplayForOwner("com.tencent.mm",
                java.util.Map.of(7, scanner, 11, "com.example.camera/.CameraActivity"), 7, java.util.Map.of(11, "owned")) == 7,
                "Unrelated app window rejected despite exact camera owner");
        for (String flag : new String[]{"", "true", "unlock", "independent-lock-extra", "independent-lock "}) {
            rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{legacy[0], legacy[1], legacy[2], flag}), "Unknown fourth argument accepted");
        }
        rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{}), "Missing arguments accepted");
        rejects(() -> LiveCameraServer.parseSessionFlags(null), "Null arguments accepted");
        rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{legacy[0], legacy[1], legacy[2], "independent-lock", "extra"}), "Extra arguments accepted");
        rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{legacy[0], legacy[1], legacy[2], "independent-lock", "independent-lock"}), "Duplicate independent lock accepted");
        rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{legacy[0], legacy[1], legacy[2], "desktop-home", "desktop-home"}), "Duplicate desktop HOME accepted");
        rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{legacy[0], legacy[1], legacy[2], "desktop-home", "independent-lock", "extra"}), "Six arguments accepted");
        rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{legacy[0], "unscoped_socket", legacy[2], "independent-lock"}), "Unscoped socket accepted");
        rejects(() -> LiveCameraServer.requestedIndependentLock(new String[]{legacy[0], legacy[1], "invalid", "independent-lock"}), "Malformed token accepted");

        LiveCameraServer.SessionFlags normalFlags = LiveCameraServer.parseSessionFlags(legacy);
        require(!normalFlags.balancedDisplay && !normalFlags.displayBeforeCamera, "Research paths enabled by default");
        LiveCameraServer.SessionFlags research = LiveCameraServer.parseSessionFlags(new String[]{legacy[0],legacy[1],legacy[2],"desktop-home","balanced-display","display-before-camera"});
        require(research.balancedDisplay && research.displayBeforeCamera && research.desktopHome, "Explicit research flags lost");
        rejects(() -> LiveCameraServer.parseSessionFlags(new String[]{legacy[0],legacy[1],legacy[2],"balanced-display"}), "Unscoped research accepted");
        rejects(() -> LiveCameraServer.parseSessionFlags(new String[]{legacy[0],legacy[1],legacy[2],"desktop-home","balanced-display","balanced-display"}), "Duplicate research accepted");
        java.util.Map<Integer, String> ownedApps = java.util.Map.of(11, "owned");
        require(LiveCameraServer.isOwnedDisplayId(7, 7, ownedApps), "Owned desktop display filtered");
        require(LiveCameraServer.isOwnedDisplayId(11, 7, ownedApps), "Owned app display filtered");
        for (int id : new int[]{-1, 0, 8, 12})
            require(!LiveCameraServer.isOwnedDisplayId(id, 7, ownedApps), "Unowned display accepted");

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
        System.out.println("PASS legacy/desktop HOME/independent lock exact argument contract, exact camera package/ID and scanner routing, owned display activity filter, primary-user first unlock and existing permission gates, actual Display flag and owned ON-state verification; no Android runtime/device calls");
    }
}
