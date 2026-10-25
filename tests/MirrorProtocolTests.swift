import Foundation

@main
enum MirrorProtocolTests {
    static func main() throws {
        let session=Data([0x80,0,0,1,0,0,4,0x38,0,0,7,0x80])
        let sessionHeader=try MirrorProtocol.header(session)
        assert(sessionHeader == .session(width:1080,height:1920,clientResized:true))
        let config=Data([0x40,0,0,0,0,0,0,0,0,0,0,0x1b])
        let configHeader=try MirrorProtocol.header(config)
        assert(configHeader == .packet(length:27,config:true,keyFrame:false,pts:0))
        let key=Data([0x20,0,0,0,0,0,0,5,0,0,0,3])
        let keyHeader=try MirrorProtocol.header(key)
        assert(keyHeader == .packet(length:3,config:false,keyFrame:true,pts:5))
        do { _=try MirrorProtocol.header(Data([0x80,0,0,0,0,0,0,0,0,0,0,0]));fatalError("accepted zero dimensions") }
        catch { }
        do { _=try MirrorProtocol.header(Data([0,0,0,0,0,0,0,0,0,0,0,0]));fatalError("accepted empty frame") }
        catch { }
        let nal=try MirrorProtocol.nalUnits(Data([0,0,0,1,0x67,1,2,0,0,1,0x68,3,0,0,0,1,0x65,4]))
        assert(nal == [Data([0x67,1,2]),Data([0x68,3]),Data([0x65,4])])
        do { _=try MirrorProtocol.nalUnits(Data([0x65,1,2]));fatalError("accepted unframed NAL") }
        catch { }
        let touch=MirrorProtocol.touch(action:0,x:1.3,y:-0.1,width:1080,height:1920)!
        assert(touch.count == 32 && touch[0] == 2 && touch[1] == 0)
        assert(Array(touch[10..<14]) == [0,0,4,0x37]) // clipped x=1079
        assert(Array(touch[14..<18]) == [0,0,0,0])
        assert(Array(touch[18..<22]) == [4,0x38,7,0x80])
        assert(MirrorProtocol.key(action:0,code:4)?.count == 14)
        assert(MirrorProtocol.touch(action:0,x:.nan,y:0,width:1,height:1) == nil)
        print("Mirror protocol boundary tests passed")
    }
}
