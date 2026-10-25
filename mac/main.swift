import AppKit
MainActor.assumeIsolated {
    let application=NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate=AppController()
    application.delegate=delegate
    withExtendedLifetime(delegate) { application.run() }
}
