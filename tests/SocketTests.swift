import Foundation
import Darwin

// Integration test for the actual host transport against a bounded local peer.
@main struct SocketTests {
    static func exact(_ fd:Int32,_ size:Int)->[UInt8] {
        var result=[UInt8](repeating:0,count:size),offset=0
        while offset<size {
            let n=result.withUnsafeMutableBytes { Darwin.recv(fd,$0.baseAddress!.advanced(by:offset),size-offset,0) }
            precondition(n>0,"peer disconnected");offset+=n
        }
        return result
    }
    static func main() throws {
        let listener=socket(AF_INET,SOCK_STREAM,0)
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family=sa_family_t(AF_INET);address.sin_addr=in_addr(s_addr:inet_addr("127.0.0.1"))
        let bound=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_in>.size))} }
        precondition(bound==0);precondition(listen(listener,1)==0)
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        _=withUnsafeMutablePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(listener,$0,&length)}}
        let token=String(repeating:"a",count:32),done=DispatchSemaphore(value:0)
        DispatchQueue.global().async {
            let client=accept(listener,nil,nil);defer {Darwin.close(client);Darwin.close(listener);done.signal()}
            precondition(String(bytes:exact(client,32),encoding:.ascii)==token)
            precondition(exact(client,5)==[1,0,0,0,3]);precondition(exact(client,3)==[1,2,3])
            // Deliberately fragmented response exercises exact-read framing.
            for byte:UInt8 in [0,0,0,0,2,8,9] {var b=byte;_=Darwin.send(client,&b,1,0)}
            precondition(exact(client,5)==[2,0,0,0,0])
            var invalid:[UInt8]=[0,0x7f,0xff,0xff,0xff]
            _=Darwin.send(client,&invalid,invalid.count,0)
        }
        let client=try CameraSocket(port:UInt16(bigEndian:address.sin_port),token:token)
        let response=try client.request(1,Data([1,2,3]));precondition(response==Data([8,9]))
        do {_=try client.request(2);fatalError("oversized response accepted")}
        catch {precondition(error.localizedDescription.contains("长度"))}
        client.close();precondition(done.wait(timeout:.now()+2) == .success)
        print("PASS: token, big-endian framing, fragmented reads, oversized response rejection, socket close")
    }
}
