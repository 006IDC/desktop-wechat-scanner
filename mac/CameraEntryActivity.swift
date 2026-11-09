import Foundation
import Dispatch

/// A short process-local activity. Expiry is independent of a blocked status
/// RPC or the AppController loop. The same token is ended at most once.
final class CameraEntryActivity:@unchecked Sendable {
    private struct Record {let id:UUID,token:NSObjectProtocol,expiry:DispatchWorkItem}
    private let lock=NSLock()
    let duration:Double
    private let begin:@Sendable ()->NSObjectProtocol,end:@Sendable (NSObjectProtocol)->Void
    private var current:Record?
    init(duration:Double=1.25,
         begin:@escaping @Sendable ()->NSObjectProtocol={ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"响应手机镜像中的刚刚输入")},
         end:@escaping @Sendable (NSObjectProtocol)->Void={ProcessInfo.processInfo.endActivity($0)}) {
        self.duration=duration.isFinite && duration>0 ? min(1.25,duration):1.25
        self.begin=begin;self.end=end
    }
    @discardableResult func update(_ needed:Bool)->Bool {
        guard needed else{stop();return false}
        let work:DispatchWorkItem?=lock.withLock {
            guard current==nil else{return nil}
            let id=UUID(),token=begin()
            let expiry=DispatchWorkItem { [weak self] in self?.expire(id) }
            current=Record(id:id,token:token,expiry:expiry);return expiry
        }
        guard let work else{return false}
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+duration,execute:work)
        return true
    }
    private func expire(_ id:UUID) {
        let token:NSObjectProtocol?=lock.withLock {
            guard current?.id==id else{return nil}
            let token=current?.token;current=nil;return token
        }
        if let token {end(token)}
    }
    func stop() {
        let old:Record?=lock.withLock {let old=current;current=nil;return old}
        if let old {old.expiry.cancel();end(old.token)}
    }
    var isActive:Bool {lock.withLock{current != nil}}
    deinit {stop()}
}
