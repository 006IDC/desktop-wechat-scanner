import AppKit

private final class MemoryPreviewPreferences:UserDefaults {
    var values=[String:Bool](),writes=[String]()
    override func bool(forKey name:String)->Bool {values[name] ?? false}
    override func set(_ value:Any?,forKey name:String) {writes.append(name);values[name]=value as? Bool}
}

@main enum NativePreviewChoiceTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        precondition(!NativePreviewSelection.enabled(commandLine:false,selection:nil),"A diagnostic inherited a remembered native choice")
        precondition(!NativePreviewSelection.enabled(commandLine:false,selection:false))
        precondition(NativePreviewSelection.enabled(commandLine:false,selection:true))
        precondition(NativePreviewSelection.enabled(commandLine:true,selection:nil))
        let preferences=MemoryPreviewPreferences()
        preferences.values=["nativeInterleavedPreview.v1":true]
        let chooser=ConnectionWindowController(adbURL:URL(fileURLWithPath:"/nonexistent-test-adb"),preferences:preferences,onSelect:{_ in preconditionFailure("No device selected")})
        guard let window=chooser.window,let root=window.contentView else{fatalError("Missing chooser")}
        func buttons(_ view:NSView)->[NSButton] {(view as? NSButton).map{[$0]} ?? view.subviews.flatMap(buttons)}
        let all=buttons(root)
        guard let desktop=all.first(where:{$0.title=="桌面相机（通用）"}),let native=all.first(where:{$0.title=="原生扫码界面（试用）"}) else{fatalError("Missing native scan choice")}
        precondition(!window.isVisible && !chooser.usesDesktopCamera && !chooser.usesNativeScanPreview)
        precondition(!native.isEnabled && native.state == .on,"Remembered native choice bypassed desktop source selection")
        desktop.performClick(nil)
        precondition(chooser.usesDesktopCamera && native.isEnabled && chooser.usesNativeScanPreview)
        native.performClick(nil)
        precondition(!chooser.usesNativeScanPreview && chooser.usesDesktopCamera,"Turning native scanning off disabled ordinary photo/video input")
        native.performClick(nil);desktop.performClick(nil)
        precondition(!chooser.usesNativeScanPreview && !native.isEnabled)
        precondition(preferences.writes.isEmpty,"Opening/cancelling a chooser persisted uncommitted options")
        precondition(!window.isVisible,"A component test ordered a window")
        print("PASS hidden native-scan choice, source gating, remembered selection and unchanged preferences")
    }
}
