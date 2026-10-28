import Foundation

@main enum SolidCalibrationFrameTests {
    static func main() throws {
        let black=try PhoneSession.solidCalibrationBody(epoch:0,blue:false)
        precondition(black==Data(repeating:0,count:9),"Black command contains data beyond the fixed fixture")
        let blue=try PhoneSession.solidCalibrationBody(epoch:0x0102030405060708,blue:true)
        precondition(blue==Data([1,2,3,4,5,6,7,8,1]),"Calibration epoch is not big endian")
        let maximum=try PhoneSession.solidCalibrationBody(epoch:Int.max,blue:false)
        precondition(maximum.count==9 && maximum.first==127 && maximum.last==0,"Maximum epoch did not fit the wire format")
        do {
            _=try PhoneSession.solidCalibrationBody(epoch:-1,blue:true)
            fatalError("Negative calibration epoch accepted")
        } catch is ScanError {}
        print("PASS solid calibration payload, fixed size, color tags and epoch bounds")
    }
}
