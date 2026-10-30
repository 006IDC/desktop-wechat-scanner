import Foundation
@main enum SyntheticResultFrameGateTests {
    static func main() {
        func admitted(receipt:Double=11,shown:Double=10,now:Double=12,route:Bool=true,frame:Int=3,current:Int=3)->Bool {
            SyntheticResultFrameGate.admits(currentRoute:route,frameGeneration:frame,currentGeneration:current,
                                           receivedAt:receipt,shownAt:shown,now:now)
        }
        precondition(admitted())
        precondition(!admitted(receipt:9),"An old exact-text frame before the new QR passed")
        precondition(!admitted(route:false),"Another mirror's exact text passed")
        precondition(!admitted(frame:2),"A retired mirror incarnation passed")
        precondition(!admitted(frame:0,current:0))
        precondition(!admitted(receipt:13))
        precondition(!admitted(receipt:.nan))
        precondition(!admitted(shown:.infinity))
        precondition(admitted(now:100),"A static post-QR result required another redundant decode")
        print("PASS post-QR current mirror provenance; old exact text, foreign route, generation and invalid/future receipt rejection")
    }
}
