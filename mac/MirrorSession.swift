import Foundation
import Darwin
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox

/// Wire format from Genymobile/scrcpy v5.0.1 Streamer and ControlMessageReader.
enum MirrorProtocol {
    enum Header: Equatable {
        case session(width: Int, height: Int, clientResized: Bool)
        case packet(length: Int, config: Bool, keyFrame: Bool, pts: UInt64)
    }
    static func header(_ bytes: Data) throws -> Header {
        guard bytes.count == 12 else { throw ScanError("手机镜像包头长度无效。") }
        let b = Array(bytes)
        func u32(_ i: Int) -> UInt32 {
            (UInt32(b[i]) << 24) | (UInt32(b[i+1]) << 16) | (UInt32(b[i+2]) << 8) | UInt32(b[i+3])
        }
        if b[0] & 0x80 != 0 {
            let flags = u32(0), width = Int(u32(4)), height = Int(u32(8))
            guard flags & 0x7fff_fffe == 0, width > 0, height > 0,
                  width <= 8192, height <= 8192 else { throw ScanError("手机镜像尺寸无效。") }
            return .session(width:width,height:height,clientResized:flags & 1 != 0)
        }
        let high = UInt64(u32(0)), low = UInt64(u32(4)), length = Int(u32(8))
        guard length > 0 && length <= 8 * 1024 * 1024 else { throw ScanError("手机镜像帧长度无效。") }
        let flags = high << 32 | low
        return .packet(length:length,config:flags & (1 << 62) != 0,
                       keyFrame:flags & (1 << 61) != 0,pts:flags & ((1 << 61)-1))
    }
    static func nalUnits(_ annexB: Data) throws -> [Data] {
        let b = Array(annexB)
        var starts: [(Int,Int)] = [], i = 0
        while i + 3 <= b.count {
            if i + 4 <= b.count && b[i] == 0 && b[i+1] == 0 && b[i+2] == 0 && b[i+3] == 1 {
                starts.append((i,i+4)); i += 4
            } else if b[i] == 0 && b[i+1] == 0 && b[i+2] == 1 {
                starts.append((i,i+3)); i += 3
            } else { i += 1 }
        }
        guard !starts.isEmpty, starts[0].0 == 0 else { throw ScanError("手机镜像 H.264 数据缺少起始码。") }
        return try starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index+1].0 : b.count
            guard end > start.1 else { throw ScanError("手机镜像 H.264 空单元。") }
            return Data(b[start.1..<end])
        }
    }
    static func touch(action: UInt8, x: Double, y: Double, width: Int, height: Int) -> Data? {
        guard x.isFinite, y.isFinite, width > 0, height > 0,
              width <= 65535, height <= 65535 else { return nil }
        func be<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            withUnsafeBytes(of: value.bigEndian) { Array($0) }
        }
        let px = UInt32((min(1,max(0,x)) * Double(width-1)).rounded())
        let py = UInt32((min(1,max(0,y)) * Double(height-1)).rounded())
        var data = Data([2, action]) // inject touch, Android ACTION_DOWN/MOVE/UP
        data.append(contentsOf: be(UInt64.max - 1)) // SC_POINTER_ID_GENERIC_FINGER (-2)
        data.append(contentsOf: be(px)); data.append(contentsOf: be(py))
        data.append(contentsOf: be(UInt16(width))); data.append(contentsOf: be(UInt16(height)))
        data.append(contentsOf: be(UInt16(action == 1 ? 0 : 0xffff))) // pressure
        data.append(contentsOf: be(UInt32(0))); data.append(contentsOf: be(UInt32(0)))
        return data
    }
    static func key(action: UInt8, code: Int) -> Data? {
        guard code >= 0 && code <= Int(Int32.max) else { return nil }
        var data = Data([0,action]); var value = UInt32(code).bigEndian
        withUnsafeBytes(of:&value) { data.append(contentsOf:$0) }
        data.append(Data(repeating:0,count:8)) // repeat, meta state
        return data
    }
}

/// One scheduled drain, bounded discrete work, and latest-only consecutive moves.
/// Accepted DOWN/UP edges stay paired; discrete gestures wait for a live finger's UP.
final class MirrorInputScheduler {
    enum Event: Equatable {
        case touch(UInt8, Double, Double)
        case tap(Double, Double)
        case swipe(Double, Double, Double, Double)
        case key(Int)
        var isSwipe: Bool { if case .swipe = self { return true }; return false }
        var isMove: Bool { if case .touch(2, _, _) = self { return true }; return false }
    }
    struct Submission { let accepted: Bool; let wake: Bool; let overflow: Bool }
    private let lock = NSLock()
    private let capacity: Int
    private var epoch = 0, enabled = false, draining = false, fingerDown = false
    private var queue: [Event] = [], deferred: [Event] = []
    init(capacity: Int = 64) { self.capacity = max(4, capacity) }
    func reset(epoch: Int, enabled: Bool) {
        lock.withLock {
            self.epoch = epoch; self.enabled = enabled; draining = false; fingerDown = false
            queue.removeAll(); deferred.removeAll()
        }
    }
    func cancel(epoch: Int) {
        lock.withLock {
            guard self.epoch == epoch else { return }
            enabled = false; draining = false; fingerDown = false
            queue.removeAll(); deferred.removeAll()
        }
    }
    var pendingCount: Int { lock.withLock { queue.count + deferred.count } }
    func submit(_ event: Event, epoch: Int) -> Submission {
        lock.withLock {
            guard enabled, self.epoch == epoch else { return Submission(accepted: false, wake: false, overflow: false) }
            func reject(_ overflow: Bool = false) -> Submission { Submission(accepted: false, wake: false, overflow: overflow) }
            switch event {
            case let .touch(action, _, _):
                if action == 0 {
                    guard !fingerDown else { return reject() }
                    guard queue.count + deferred.count <= capacity - 2 else { return reject(true) }
                    fingerDown = true; queue.append(event)
                } else if action == 2 {
                    guard fingerDown else { return reject() }
                    if queue.last?.isMove == true { queue[queue.count - 1] = event }
                    else {
                        guard queue.count + deferred.count < capacity - 1 else { return reject() }
                        queue.append(event)
                    }
                } else if action == 1 {
                    guard fingerDown else { return reject() }
                    fingerDown = false; queue.append(event)
                    queue.append(contentsOf: deferred); deferred.removeAll()
                } else { return reject() }
            default:
                if event.isSwipe {
                    if let index = deferred.firstIndex(where: \.isSwipe) { deferred[index] = event; return Submission(accepted: true, wake: false, overflow: false) }
                    if let index = queue.firstIndex(where: \.isSwipe) { queue.remove(at: index) }
                }
                guard queue.count + deferred.count < capacity - 1 else { return reject(true) }
                if fingerDown { deferred.append(event) } else { queue.append(event) }
            }
            let wake = !draining && !queue.isEmpty
            if wake { draining = true }
            return Submission(accepted: true, wake: wake, overflow: false)
        }
    }
    func next(epoch: Int) -> Event? {
        lock.withLock {
            guard enabled, self.epoch == epoch else { return nil }
            guard !queue.isEmpty else { draining = false; return nil }
            return queue.removeFirst()
        }
    }
    func hasPending(epoch: Int) -> Bool { lock.withLock { enabled && self.epoch == epoch && !queue.isEmpty } }
    func hasPendingTouch(epoch: Int) -> Bool {
        lock.withLock {
            enabled && self.epoch == epoch && queue.contains { if case .touch = $0 { return true }; return false }
        }
    }
}

private final class MirrorSocket {
    private(set) var fd: Int32 = -1
    init(port: UInt16) throws {
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ScanError("无法建立镜像连接。") }
        fd = socketFD
        var timeout = timeval(tv_sec:2,tv_usec:0), one:Int32 = 1
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to:&address) { p in
            p.withMemoryRebound(to:sockaddr.self,capacity:1) {
                Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 { Darwin.close(fd);fd = -1;throw ScanError("镜像服务尚未就绪。") }
    }
    deinit { if fd>=0 {Darwin.close(fd)} }
    func interrupt() { Darwin.shutdown(fd,SHUT_RDWR) }
    func read(_ length: Int, timeout: TimeInterval? = nil) throws -> Data {
        let deadline=timeout.map {Date().addingTimeInterval($0)}
        var data = Data(count:length)
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < length {
                let count = Darwin.recv(fd,base.advanced(by:offset),length-offset,0)
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    if let deadline, Date() >= deadline {throw ScanError("读取手机镜像数据超时。")}
                    continue // an unchanged display may legitimately emit no new frame
                }
                guard count > 0 else { throw ScanError("手机镜像连接中断。") }
                offset += count
            }
        }
        return data
    }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(fd,base.advanced(by:offset),raw.count-offset,0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ScanError("手机控制连接中断。") }
                offset += count
            }
        }
    }
}

private final class H264Decoder: @unchecked Sendable {
    enum Output {
        case image(@Sendable (CGImage) -> Void)
        case pixelBuffer(@Sendable (CVPixelBuffer) -> Void)
    }
    private var sps: Data?, pps: Data?, format: CMVideoFormatDescription?, decoder: VTDecompressionSession?
    private let output:Output
    private let context:CIContext?
    private let timing: MirrorTiming
    private let timingLock = NSLock()
    private var pendingTiming: (MirrorTiming.Ticket, Double)?
    init(output:Output, timing:MirrorTiming) {
        self.output=output
        self.timing=timing
        if case .image = output {context=CIContext(options:[.useSoftwareRenderer:false])}
        else {context=nil}
    }
    deinit { if let decoder { VTDecompressionSessionInvalidate(decoder) } }
    func reset() {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder=nil; format=nil; sps=nil; pps=nil
    }
    private func configure() throws {
        guard let sps, let pps else { return }
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        self.decoder=nil; self.format=nil
        let status = try sps.withUnsafeBytes { s in
            try pps.withUnsafeBytes { p -> OSStatus in
                guard let sb = s.baseAddress?.assumingMemoryBound(to:UInt8.self),
                      let pb = p.baseAddress?.assumingMemoryBound(to:UInt8.self) else {
                    throw ScanError("手机镜像 H.264 配置为空。")
                }
                var pointers:[UnsafePointer<UInt8>] = [sb,pb]
                var lengths:[Int] = [s.count,p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator:kCFAllocatorDefault,parameterSetCount:2,
                    parameterSetPointers:&pointers,parameterSetSizes:&lengths,
                    nalUnitHeaderLength:4,formatDescriptionOut:&format)
            }
        }
        guard status == noErr, let format else { throw ScanError("手机镜像 H.264 参数无效。") }
        let callback:VTDecompressionOutputCallback = { ref, _, status, _, image, _, _ in
            let completedAt = ProcessInfo.processInfo.systemUptime
            guard let ref else { return }
            let owner = Unmanaged<H264Decoder>.fromOpaque(ref).takeUnretainedValue()
            owner.completeTiming(at: completedAt, succeeded: status == noErr && image != nil)
            guard status == noErr, let image else { return }
            switch owner.output {
            case let .pixelBuffer(onFrame):
                onFrame(image)
            case let .image(onFrame):
                let ci = CIImage(cvPixelBuffer:image)
                if let frame = owner.context?.createCGImage(ci,from:ci.extent) {onFrame(frame)}
            }
        }
        var record = VTDecompressionOutputCallbackRecord(decompressionOutputCallback:callback,
                                                         decompressionOutputRefCon:Unmanaged.passUnretained(self).toOpaque())
        let attributes:[NSString:Any] = [kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_32BGRA]
        let hardware:[NSString:Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder:true]
        let created = VTDecompressionSessionCreate(allocator:kCFAllocatorDefault,
                            formatDescription:format,decoderSpecification:hardware as CFDictionary,
                            imageBufferAttributes:attributes as CFDictionary,
                            outputCallback:&record,decompressionSessionOut:&decoder)
        guard created == noErr else { throw ScanError("Mac 无法创建 H.264 硬件解码器。") }
        // Public optional property; unsupported decoders retain their defaults.
        if let decoder { _ = VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
    }
    private func completeTiming(at completedAt: Double, succeeded: Bool) {
        let pending = timingLock.withLock { () -> (MirrorTiming.Ticket, Double)? in
            defer { pendingTiming = nil }
            return pendingTiming
        }
        if let (ticket, startedAt) = pending {
            timing.recordDecode(ticket, startedAt: startedAt, completedAt: completedAt, succeeded: succeeded)
        }
    }
    func feed(_ payload:Data, config:Bool, pts:UInt64, ticket:MirrorTiming.Ticket?) throws {
        var submitted = false
        defer {
            if !submitted, let ticket { timing.recordMissingDecode(ticket) }
        }
        let units = try MirrorProtocol.nalUnits(payload)
        var changed = false
        for unit in units {
            switch unit[unit.startIndex] & 0x1f {
            case 7: if sps != unit {sps=unit;changed=true}
            case 8: if pps != unit {pps=unit;changed=true}
            default: break
            }
        }
        if changed {try configure()}
        if config {return}
        guard let decoder, let format else { return } // wait for SPS/PPS and an IDR
        let media = units.filter { let type=$0[$0.startIndex] & 0x1f; return type != 7 && type != 8 }
        guard !media.isEmpty else { return }
        var avcc = Data()
        for unit in media {
            var length=UInt32(unit.count).bigEndian
            withUnsafeBytes(of:&length) {avcc.append(contentsOf:$0)}
            avcc.append(unit)
        }
        var block:CMBlockBuffer?
        let created = avcc.withUnsafeBytes { raw -> OSStatus in
            guard raw.baseAddress != nil else {return -1}
            return CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,
                memoryBlock:nil,blockLength:raw.count,blockAllocator:kCFAllocatorDefault,
                customBlockSource:nil,offsetToData:0,dataLength:raw.count,flags:0,blockBufferOut:&block)
        }
        guard created == noErr, let block else {throw ScanError("H.264 帧内存分配失败。")}
        let copy = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with:raw.baseAddress!,blockBuffer:block,offsetIntoDestination:0,dataLength:raw.count)
        }
        guard copy == noErr else {throw ScanError("H.264 帧拷贝失败。")}
        var sample:CMSampleBuffer?, size=avcc.count
        var sampleTiming = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(pts), timescale: 1_000_000), decodeTimeStamp: .invalid)
        let sampleStatus=CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,
            formatDescription:format,sampleCount:1,sampleTimingEntryCount:1,
            sampleTimingArray:&sampleTiming,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample)
        guard sampleStatus == noErr, let sample else {throw ScanError("H.264 样本无效。")}
        var flags:VTDecodeInfoFlags=[]
        // With both decode flags clear, Apple's API guarantees the callback
        // completes before DecodeFrame returns. One protected slot is sufficient;
        // it owns only numeric timing data, never a frame or retained refcon.
        if let ticket {
            timingLock.withLock { pendingTiming = (ticket, ProcessInfo.processInfo.systemUptime) }
        }
        submitted = true
        let status=VTDecompressionSessionDecodeFrame(decoder,sampleBuffer:sample,
                                flags:[],frameRefcon:nil,infoFlagsOut:&flags)
        let missing = timingLock.withLock { () -> MirrorTiming.Ticket? in
            defer { pendingTiming = nil }
            return pendingTiming?.0
        }
        if let missing { timing.recordMissingDecode(missing, failed: status != noErr) }
        guard status == noErr else {throw ScanError("H.264 硬件解码失败（\(status)）。")}
    }
}

final class MirrorSession: @unchecked Sendable {
    private let lock=NSLock()
    private let timing = MirrorTiming()
    var timingSnapshot: MirrorTiming.Snapshot { timing.snapshot }
    private let inputScheduler = MirrorInputScheduler()
    private let inputQueue=DispatchQueue(label:"com.idc006.mirror.input",qos:.userInitiated)
    private var generation=0, video:MirrorSocket?, control:MirrorSocket?, server:Process?
    private var adbURL:URL?, serial:String?, serverSocket:String?, port:UInt16?, socketName:String?, remotePath:String?
    private var directSession=false
    private var width=0, height=0
    private var started=false, stopping=false
    private var preparing:DispatchGroup?
    private var failureCallback: (@Sendable (String)->Void)?
    private var stopWaiters:[CheckedContinuation<Void,Never>]=[]
    private func begin(adbURL:URL,serial:String,serverSocket:String?,direct:DirectMirrorDescriptor?,
                       onFailure:@escaping @Sendable (String)->Void) throws -> (Int,String,DispatchGroup) {
        lock.lock();defer {lock.unlock()}
        guard !started && !stopping else {throw ScanError("手机镜像已经运行或正在关闭。")}
        started=true;generation += 1
        timing.begin(epoch: generation)
        inputScheduler.reset(epoch: generation, enabled: true)
        self.adbURL=adbURL;self.serial=serial;self.serverSocket=serverSocket
        failureCallback=onFailure
        let token=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let scid="0"+String(token.prefix(7)) // 31-bit signed scid, 8 hex digits
        if let direct {
            socketName=direct.socket;remotePath=nil;directSession=true
        } else {
            socketName="scrcpy_"+scid
            remotePath="/data/local/tmp/006idc-mirror-\(token).jar"
            directSession=false
        }
        let group=DispatchGroup();group.enter();preparing=group
        return (generation,scid,group)
    }
    func start(adbURL:URL,serverURL:URL,serial:String,displayID:Int,serverSocket:String?=nil,
               onFrame:@escaping @Sendable (CGImage)->Void,
               onFailure:@escaping @Sendable (String)->Void) async throws {
        try await start(adbURL:adbURL,serverURL:serverURL,serial:serial,displayID:displayID,serverSocket:serverSocket,
                        direct:nil,output:.image(onFrame),onFailure:onFailure)
    }
    /// Delivers the decoder's pixel buffer directly. The receiver must retain it
    /// (for example, in a latest-only mailbox) before this callback returns.
    func startVideo(adbURL:URL,serverURL:URL,serial:String,displayID:Int,serverSocket:String?=nil,
                    direct:DirectMirrorDescriptor?=nil,
                    onFrame:@escaping @Sendable (CVPixelBuffer)->Void,
                    onFailure:@escaping @Sendable (String)->Void) async throws {
        try await start(adbURL:adbURL,serverURL:serverURL,serial:serial,displayID:displayID,serverSocket:serverSocket,
                        direct:direct,output:.pixelBuffer(onFrame),onFailure:onFailure)
    }
    private func start(adbURL:URL,serverURL:URL,serial:String,displayID:Int,serverSocket:String?,
                       direct:DirectMirrorDescriptor?,
                       output:H264Decoder.Output,
                       onFailure:@escaping @Sendable (String)->Void) async throws {
        guard displayID >= 0, !serial.isEmpty, !serial.contains("\n"),
              (direct == nil || (direct?.isValid == true && direct?.display == displayID)),
              (direct != nil || FileManager.default.fileExists(atPath:serverURL.path)) else {
            throw ScanError("手机镜像参数或 scrcpy 服务文件无效。")
        }
        let (epoch,scid,group)=try begin(adbURL:adbURL,serial:serial,serverSocket:serverSocket,
                                          direct:direct,onFailure:onFailure)
        do {
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                DispatchQueue.global(qos:.userInitiated).async {
                    defer {group.leave()}
                    do {
                        if let direct {
                            try self.prepareDirect(adbURL:adbURL,serial:serial,displayID:displayID,
                                                   descriptor:direct,epoch:epoch,serverSocket:serverSocket)
                        } else {
                            try self.prepare(adbURL:adbURL,serverURL:serverURL,serial:serial,
                                             displayID:displayID,scid:scid,epoch:epoch,serverSocket:serverSocket)
                        }
                        continuation.resume()
                    } catch {continuation.resume(throwing:error)}
                }
            }
            let deliver:H264Decoder.Output
            switch output {
            case let .image(onFrame):
                deliver = .image { [weak self] image in
                    guard let self, self.isCurrent(epoch) else {return}
                    onFrame(image)
                }
            case let .pixelBuffer(onFrame):
                deliver = .pixelBuffer { [weak self] pixelBuffer in
                    guard let self, self.isCurrent(epoch) else {return}
                    onFrame(pixelBuffer)
                }
            }
            let decoder=H264Decoder(output:deliver,timing:timing)
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                guard let self else {return}
                do {try self.receive(epoch:epoch,decoder:decoder)}
                catch {
                    if self.isCurrent(epoch) {onFailure(error.localizedDescription)}
                }
            }
        } catch {
            // A canceled preparation may complete after a newer start. It must
            // never stop that newer session from its delayed error path.
            if isCurrent(epoch) {await stop()}
            throw error
        }
    }
    private func isCurrent(_ epoch:Int)->Bool {
        lock.lock();defer {lock.unlock()};return started && generation==epoch
    }
    private func adb(_ args:[String],url:URL,serial:String,serverSocket:String?,timeout:TimeInterval=15,cancelEpoch:Int?=nil) throws -> String {
        try ShellCommand.run(url,(serverSocket.map { ["-L", $0] } ?? []) + ["-s",serial]+args,timeout:timeout,cancellationRequested:{ [weak self] in
            guard let cancelEpoch else{return false}
            return self?.isCurrent(cancelEpoch) != true
        })
    }
    private func prepareDirect(adbURL:URL,serial:String,displayID:Int,
                               descriptor:DirectMirrorDescriptor,epoch:Int,serverSocket:String?) throws {
        guard isCurrent(epoch), descriptor.isValid, descriptor.display == displayID else {
            throw ScanError("手机镜像已停止或直连参数无效。")
        }
        let forwarded=try adb(["forward","tcp:0","localabstract:"+descriptor.socket],
                              url:adbURL,serial:serial,serverSocket:serverSocket,cancelEpoch:epoch)
        guard let port=UInt16(forwarded),port>0 else {throw ScanError("无法建立独立应用镜像转发。")}
        // stop() waits for preparation before taking its cleanup snapshot. Save
        // the owned forward even if cancellation arrived during adb's reply.
        lock.withLock {self.port=port}
        guard isCurrent(epoch) else {throw ScanError("手机镜像已停止。")}

        let token=Array(descriptor.token.utf8)
        guard token.count == 32,token.allSatisfy({$0 < 128}) else {throw ScanError("直连鉴权参数无效。")}
        func authenticate(_ channel:MirrorSocket,role:UInt8) throws {
            var hello=Data(token);hello.append(role)
            try channel.write(hello)
            guard try channel.read(1,timeout:2)==Data([0]) else {throw ScanError("手机镜像直连鉴权失败。")}
        }
        func register(_ channel:MirrorSocket,videoRole:Bool) throws {
            let accepted=lock.withLock { () -> Bool in
                guard started && generation==epoch else {return false}
                if videoRole {video=channel} else {control=channel}
                return true
            }
            guard accepted else {channel.interrupt();throw ScanError("手机镜像已停止。")}
        }

        let videoChannel=try MirrorSocket(port:port)
        try register(videoChannel,videoRole:true)
        try authenticate(videoChannel,role:0)
        guard isCurrent(epoch) else {throw ScanError("手机镜像已停止。")}
        let controlChannel=try MirrorSocket(port:port)
        try register(controlChannel,videoRole:false)
        try authenticate(controlChannel,role:1)
        guard isCurrent(epoch) else {throw ScanError("手机镜像已停止。")}
    }
    private func prepare(adbURL:URL,serverURL:URL,serial:String,displayID:Int,
                         scid:String,epoch:Int,serverSocket:String?) throws {
        guard isCurrent(epoch) else {throw ScanError("手机镜像已停止。")}
        lock.lock();let path=remotePath!, name=socketName!;lock.unlock()
        _=try adb(["push",serverURL.path,path],url:adbURL,serial:serial,serverSocket:serverSocket,timeout:30,cancelEpoch:epoch)
        guard isCurrent(epoch) else {throw ScanError("手机镜像已停止。")}
        let forwarded=try adb(["forward","tcp:0","localabstract:"+name],url:adbURL,serial:serial,serverSocket:serverSocket,cancelEpoch:epoch)
        guard let port=UInt16(forwarded),port>0 else {throw ScanError("无法建立手机镜像 USB 转发。")}
        lock.lock();self.port=port;lock.unlock()
        let process=Process(), pipe=Pipe()
        process.executableURL=adbURL
        process.arguments=(serverSocket.map { ["-L", $0] } ?? []) + ["-s",serial,"shell",
            "CLASSPATH=\(path) app_process / com.genymobile.scrcpy.Server 5.0.1 scid=\(scid) tunnel_forward=true video=true audio=false control=true display_id=\(displayID) video_codec=h264 max_size=1600 max_fps=60 clipboard_autosync=false send_device_meta=false send_dummy_byte=true cleanup=true power_on=\(displayID == 0 ? "true" : "false")"]
        process.standardOutput=pipe;process.standardError=pipe
        // Drain stderr/stdout continuously: a full ADB pipe would stall the server.
        pipe.fileHandleForReading.readabilityHandler={handle in
            if handle.availableData.isEmpty {handle.readabilityHandler=nil}
        }
        try process.run()
        lock.lock();server=process;lock.unlock()
        let deadline=Date().addingTimeInterval(12)
        var video:MirrorSocket?
        while Date()<deadline && isCurrent(epoch) {
            if let connected=try? MirrorSocket(port:port),
               let dummy=try? connected.read(1,timeout:min(2,deadline.timeIntervalSinceNow)),
               dummy==Data([0]) {video=connected;break}
            if !process.isRunning {break}
            Thread.sleep(forTimeInterval:0.12)
        }
        guard let video, isCurrent(epoch) else {throw ScanError("手机镜像服务未启动，请检查手机连接。")}
        let control=try MirrorSocket(port:port)
        lock.lock()
        if generation==epoch && started {self.video=video;self.control=control}
        lock.unlock()
        guard isCurrent(epoch) else {video.interrupt();control.interrupt();throw ScanError("手机镜像已停止。")}
    }
    private func receive(epoch:Int,decoder:H264Decoder) throws {
        lock.lock();let video=self.video;lock.unlock()
        guard let video else {throw ScanError("手机镜像连接丢失。")}
        // A prewarmed empty virtual display may not emit codec data until a task arrives.
        // The visible-route first-frame deadline is owned by AppController; stop interrupts this read.
        let codec=try video.read(4)
        guard codec==Data([0x68,0x32,0x36,0x34]) else {throw ScanError("手机未提供 H.264 镜像流。")}
        while isCurrent(epoch) {
            let header=try MirrorProtocol.header(video.read(12))
            switch header {
            case let .session(width,height,_):
                lock.withLock {
                    guard started && generation == epoch else { return }
                    self.width=width;self.height=height
                    timing.startStream(epoch: epoch)
                }
                decoder.reset()
            case let .packet(length,config,_,pts):
                let payload=try video.read(length,timeout:10)
                let receivedAt = ProcessInfo.processInfo.systemUptime
                if isCurrent(epoch) {
                    let ticket = timing.recordPacket(epoch: epoch, ptsMicroseconds: pts, config: config,
                                                     receivedAt: receivedAt, bytes: payload.count)
                    try decoder.feed(payload,config:config,pts:pts,ticket:ticket)
                }
            }
        }
    }
    func touch(action: UInt8, x: Double, y: Double) {
        guard [0, 1, 2].contains(action), x.isFinite, y.isFinite else { return }
        enqueueInput(.touch(action, x, y))
    }
    func tap(x:Double,y:Double) {
        guard x.isFinite, y.isFinite else { return }
        enqueueInput(.tap(x, y))
    }
    func swipe(x1:Double,y1:Double,x2:Double,y2:Double) {
        guard [x1, y1, x2, y2].allSatisfy(\.isFinite) else { return }
        enqueueInput(.swipe(x1, y1, x2, y2))
    }
    func key(_ code:Int) {
        guard MirrorProtocol.key(action: 0, code: code) != nil else { return }
        enqueueInput(.key(code))
    }
    private func enqueueInput(_ event: MirrorInputScheduler.Event) {
        guard let epoch = currentEpoch() else { return }
        let result = inputScheduler.submit(event, epoch: epoch)
        if result.overflow { reportInputFailure(ScanError("手机控制繁忙，请稍后重试。"), epoch: epoch) }
        if result.wake { inputQueue.async { [weak self] in self?.drainInputs(epoch: epoch) } }
    }
    private func drainInputs(epoch: Int) {
        guard isCurrent(epoch) else { return }
        do {
            while let event = inputScheduler.next(epoch: epoch) {
                switch event {
                case let .touch(action, x, y): try sendTouch(action, x, y, epoch: epoch)
                case let .tap(x, y):
                    try sendTouch(0, x, y, epoch: epoch); try sendTouch(1, x, y, epoch: epoch)
                case let .key(code):
                    if let down = MirrorProtocol.key(action: 0, code: code), let up = MirrorProtocol.key(action: 1, code: code) {
                        try send(down, epoch: epoch); try send(up, epoch: epoch)
                    }
                case let .swipe(x1, y1, x2, y2):
                    try sendTouch(0, x1, y1, epoch: epoch)
                    scheduleSwipe(x1: x1, y1: y1, x2: x2, y2: y2, step: 1, epoch: epoch)
                    return
                }
            }
        } catch {
            inputScheduler.cancel(epoch: epoch)
            reportInputFailure(error, epoch: epoch)
        }
    }
    private func scheduleSwipe(x1: Double, y1: Double, x2: Double, y2: Double, step: Int, epoch: Int) {
        inputQueue.asyncAfter(deadline: .now() + .milliseconds(12)) { [weak self] in
            guard let self, self.isCurrent(epoch) else { return }
            do {
                let t = Double(step - 1) / 8
                if self.inputScheduler.hasPending(epoch: epoch) {
                    // A live gesture never waits behind an old wheel animation.
                    let progress: Double
                    if self.inputScheduler.hasPendingTouch(epoch: epoch) { progress = t }
                    else {
                        // A stream of wheel events still makes progress while replacing its tail.
                        progress = Double(step) / 8
                        try self.sendTouch(2, x1 + (x2 - x1) * progress, y1 + (y2 - y1) * progress, epoch: epoch)
                    }
                    try self.sendTouch(1, x1 + (x2 - x1) * progress, y1 + (y2 - y1) * progress, epoch: epoch)
                    self.drainInputs(epoch: epoch)
                    return
                }
                let next = Double(step) / 8
                try self.sendTouch(2, x1 + (x2 - x1) * next, y1 + (y2 - y1) * next, epoch: epoch)
                if step == 8 {
                    try self.sendTouch(1, x2, y2, epoch: epoch)
                    self.drainInputs(epoch: epoch)
                } else {
                    self.scheduleSwipe(x1: x1, y1: y1, x2: x2, y2: y2, step: step + 1, epoch: epoch)
                }
            } catch {
                self.inputScheduler.cancel(epoch: epoch)
                self.reportInputFailure(error, epoch: epoch)
            }
        }
    }
    private func currentEpoch()->Int? {
        lock.withLock {started ? generation:nil}
    }
    private func sendTouch(_ action:UInt8,_ x:Double,_ y:Double,epoch:Int) throws {
        let (w,h)=lock.withLock {(width,height)}
        guard let message=MirrorProtocol.touch(action:action,x:x,y:y,width:w,height:h) else {
            if isCurrent(epoch) {throw ScanError("手机镜像画面尚未就绪。")}
            return
        }
        try send(message,epoch:epoch)
    }
    private func send(_ data:Data,epoch:Int) throws {
        let (current,channel)=lock.withLock {(started && generation==epoch,control)}
        guard current else {return}
        guard let channel else {throw ScanError("手机控制连接尚未就绪。")}
        try channel.write(data)
    }
    private func reportInputFailure(_ error:Error,epoch:Int) {
        let callback=lock.withLock {started && generation==epoch ? failureCallback:nil}
        callback?(error.localizedDescription)
    }
    func stop() async {
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            let state: (MirrorSocket?,MirrorSocket?,DispatchGroup?)? = lock.withLock {
                if stopping {
                    stopWaiters.append(continuation)
                    return nil
                }
                timing.invalidate(epoch: generation)
                stopping=true;generation += 1;started=false
                inputScheduler.reset(epoch: generation, enabled: false)
                return (video,control,preparing)
            }
            guard let (video,control,preparing)=state else {return}
            video?.interrupt();control?.interrupt()
            DispatchQueue.global(qos:.utility).async {
                preparing?.wait()
                let (server,adbURL,serial,serverSocket,port,name,path,direct) = self.lock.withLock { () -> (Process?,URL?,String?,String?,UInt16?,String?,String?,Bool) in
                    let snapshot=(self.server,self.adbURL,self.serial,self.serverSocket,self.port,self.socketName,self.remotePath,self.directSession)
                    self.video=nil;self.control=nil;self.server=nil;self.serverSocket=nil;self.port=nil
                    self.directSession=false
                    self.width=0;self.height=0;self.preparing=nil
                    return snapshot
                }
                if let server,server.isRunning {server.terminate()}
                guard let adbURL,let serial else {
                    let waiters=self.finishStopping()
                    continuation.resume()
                    for waiter in waiters {waiter.resume()}
                    return
                }
                if let name,
                   let listing=try? self.adb(["forward","--list"],url:adbURL,serial:serial,serverSocket:serverSocket) {
                    let owned = listing.split(separator:"\n").filter { line in
                        line.hasPrefix("\(serial) tcp:") && line.hasSuffix(" localabstract:\(name)")
                    }
                    let localPort:UInt16?
                    if let port {
                        localPort=owned.contains(where:{$0 == "\(serial) tcp:\(port) localabstract:\(name)"}) ? port:nil
                    } else if direct,owned.count == 1 {
                        let fields=owned[0].split(separator:" ")
                        localPort=fields.count == 3 ? UInt16(fields[1].dropFirst(4)):nil
                    } else {localPort=nil}
                    if let localPort {
                        _=try? self.adb(["forward","--remove","tcp:\(localPort)"],url:adbURL,serial:serial,serverSocket:serverSocket)
                    }
                }
                if let path { _=try? self.adb(["shell","rm","-f",path],url:adbURL,serial:serial,serverSocket:serverSocket) }
                let waiters=self.finishStopping()
                continuation.resume()
                for waiter in waiters {waiter.resume()}
            }
        }
    }
    private func finishStopping()->[CheckedContinuation<Void,Never>] {
        lock.withLock {
            stopping=false;failureCallback=nil
            let waiters=stopWaiters;stopWaiters=[]
            return waiters
        }
    }
}
