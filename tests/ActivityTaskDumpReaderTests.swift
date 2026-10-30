import Foundation

// Link this standalone transport test with the real reader, task parser and
// camera-state decoder. No PhoneSession/device/capture implementation is linked.
struct ScanError:Error {let message:String;init(_ message:String){self.message=message}}
@main enum ActivityTaskDumpReaderTests {
    enum Fault:Error {case transport}
    static func main() throws {
        let fixture="""
        Display #7 (activities from top to bottom):
          * Task{a #90 type=standard U=0 sz=1}
            * TaskFragment{ab mode=fullscreen}
              * Hist #0: ActivityRecord{abc u0 org.example/.Main t90}
        """
        var native=0,legacy=0,failed=0
        func reset(){native=0;legacy=0;failed=0}
        func old()->String {legacy+=1;return fixture}
        let original=try ActivityTaskDumpReader.read(native:nil,legacy:old,nativeFailed:{failed+=1})
        precondition(original==fixture && legacy==1 && failed==0)
        reset()
        let direct=try ActivityTaskDumpReader.read(native:{native+=1;return Data(fixture.utf8)},legacy:old,nativeFailed:{failed+=1})
        precondition(direct==fixture && native==1 && legacy==0 && failed==0)
        let tasks=try AndroidTaskSnapshot.parseChecked(direct,requiredDisplay:7)
        precondition(tasks.count==1 && tasks[0].id==90 && tasks[0].packageName=="org.example")
        reset()
        _=try ActivityTaskDumpReader.read(native:{native+=1;throw ScanError("Activity task dump unavailable")},legacy:old,nativeFailed:{failed+=1})
        precondition(native==1 && legacy==1 && failed==1)

        for error in ["Activity task dump timed out","Unknown command","other"] {
            reset()
            do {
                _=try ActivityTaskDumpReader.read(native:{native+=1;throw ScanError(error)},legacy:old,nativeFailed:{failed+=1})
                preconditionFailure("Unsafe legacy retry")
            }catch let e as ScanError {precondition(e.message==(error=="Activity task dump timed out" ? "手机任务读取超时，请重试打开应用。":error))}
            precondition(native==1 && failed==1 && legacy==0)
        }
        for bytes in [Data(),Data([0xff]),Data(repeating:32,count:ActivityTaskDumpReader.maximumBytes+1)] {
            reset()
            do {
                _=try ActivityTaskDumpReader.read(native:{native+=1;return bytes},legacy:old,nativeFailed:{failed+=1})
                preconditionFailure("Invalid body accepted")
            }catch let e as ScanError {precondition(e.message=="手机任务树响应无效。")}
            precondition(native==1 && failed==1 && legacy==0)
        }
        reset()
        do {
            _=try ActivityTaskDumpReader.read(native:{throw Fault.transport},legacy:old,nativeFailed:{failed+=1})
            preconditionFailure()
        }catch Fault.transport{}
        precondition(failed==1 && legacy==0)

        func state(_ capability:Any?) throws ->PhoneCameraState {
            var fields:[String:Any]=["version":1,"generation":0,"activeStreams":0,"activities":[],"desktopHome":true]
            if let capability {fields["activityTaskDumpSupported"]=capability}
            return try PhoneCameraState.decode(JSONSerialization.data(withJSONObject:fields))
        }
        let oldState=try state(nil),disabledState=try state(false),enabledState=try state(true)
        precondition(!oldState.activityTaskDumpSupported && !disabledState.activityTaskDumpSupported && enabledState.activityTaskDumpSupported)
        do {_=try state("true");preconditionFailure("Non-boolean capability accepted")}catch{}
        print("PASS same TaskFragment parser, exact fallback, timeout/corrupt/transport rejection and old-service capability")
    }
}
