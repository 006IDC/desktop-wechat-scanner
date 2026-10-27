import Foundation
import QuartzCore
import Metal

@main enum NativeMetalDisplayDriverTests {
    @MainActor static func main() async {
        guard let device=MTLCreateSystemDefaultDevice() else{fatalError("Metal device required")}
        let layer=CAMetalLayer();layer.device=device;layer.pixelFormat = .bgra8Unorm
        layer.drawableSize=CGSize(width:2,height:2)
        let stopped=NativeMetalDisplayDriver(layer:layer,active:{true},render:{_ in},failure:{})
        stopped.stop();stopped.start();await stopped.waitUntilStopped()
        for _ in 0..<20 {
            let driver=NativeMetalDisplayDriver(layer:layer,active:{true},render:{_ in},failure:{})
            driver.start()
            try? await Task.sleep(nanoseconds:5_000_000)
            driver.stop();await driver.waitUntilStopped()
        }
        let invalid=NativeMetalDisplayDriver(layer:layer,active:{false},render:{_ in
            fatalError("Invalid source rendered a frame")
        },failure:{})
        invalid.start();await invalid.waitUntilStopped()
        print("PASS native display driver: stop before start, rapid start/stop, and inactive-source exit without an attached window. No capture or phone.")
    }
}
