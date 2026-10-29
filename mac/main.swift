import AppKit
MainActor.assumeIsolated {
    let application=NSApplication.shared
    if CommandLine.arguments.contains("--run-background-scan-diagnostic") {
        application.setActivationPolicy(.prohibited)
        Task {exit(await BackgroundScanDiagnostic.run())}
        application.run()
        exit(1)
    }
    application.setActivationPolicy(.regular)
    let delegate=AppController()
    application.delegate=delegate
    withExtendedLifetime(delegate) { application.run() }
}
