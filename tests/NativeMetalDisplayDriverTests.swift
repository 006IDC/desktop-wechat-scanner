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
        invalid.requestDrawableSize(CGSize(width:6,height:8))
        invalid.requestDrawableSize(CGSize(width:10,height:12))
        invalid.requestDrawableSize(CGSize(width:0,height:0))
        invalid.requestDrawableSize(CGSize(width:CGFloat.nan,height:20))
        invalid.start();await invalid.waitUntilStopped()
        precondition(layer.drawableSize==CGSize(width:10,height:12),"Latest valid resize was not applied on the worker")
        invalid.requestDrawableSize(CGSize(width:20,height:20))
        precondition(layer.drawableSize==CGSize(width:10,height:12),"Stopped driver accepted a resize")
        print("PASS native display driver: stop races, latest valid worker resize, inactive-source exit. No capture or phone.")
    }
}
