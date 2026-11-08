import Foundation

/// Match the actual CDM shell contract, including OEM backports, not SDK number.
/// No user/profile/package input is accepted; only this product's nonce MAC.
enum CompanionAssociationCommands:Equatable {
    case positional,options
    static func detect(help:String,runtimeOptions:Bool?=nil) throws ->Self {
        let advertised=try advertised(help:help)
        if advertised == .options {
            guard let runtimeOptions else{throw unsupported}
            return runtimeOptions ? .options:.positional
        }
        guard runtimeOptions != true else{throw unsupported}
        return .positional
    }
    static func runtimeOptions(in data:Data) throws ->Bool {
        struct Reply:Decodable {let version:Int;let cmdOptionsKnown:Bool;let cmdOptions:Bool?}
        guard data.count<=1024 else{throw unsupported}
        let reply=try JSONDecoder().decode(Reply.self,from:data)
        guard reply.version==1,reply.cmdOptionsKnown,let enabled=reply.cmdOptions else{throw unsupported}
        return enabled
    }
    static func associationID(in data:Data,mac:String,expected:Int?=nil) throws ->Int? {
        struct Reply:Decodable {
            let version:Int,associationKnown:Bool,targetMAC:String,userId:Int,ownerPackage:String,associationIDs:[Int]
        }
        guard data.count<=4096 else{throw unsupported}
        let reply=try JSONDecoder().decode(Reply.self,from:data)
        guard reply.version==1,reply.associationKnown,reply.targetMAC==mac,reply.userId==0,
              reply.ownerPackage=="com.android.shell",reply.associationIDs.count<=1,
              reply.associationIDs.allSatisfy({$0>0 && $0<=Int(Int32.max)}) else {
            throw ScanError("手机临时关联的归属无法唯一确认，已保留恢复记录。")
        }
        if let found=reply.associationIDs.first,let expected,found != expected {
            throw ScanError("临时连接编号不匹配，已停止自动清理。")
        }
        return reply.associationIDs.first
    }
    static func confirmAssociation(read:() throws ->Int?,now:()->TimeInterval={ProcessInfo.processInfo.systemUptime},
                                   wait:()->Void={Thread.sleep(forTimeInterval:0.1)},check:()throws->Void={}) throws ->Int {
        let deadline=now()+3
        repeat {
            try check()
            if let id=try read() {guard id>0 else{throw unsupported};return id}
            wait()
        }while now()<deadline
        throw ScanError("手机尚未确认临时关联的创建结果，已保留恢复记录；稍后重新连接时会继续清理。")
    }
    static func advertised(help:String) throws ->Self {
        guard help.utf8.count<=65_536 else{throw unsupported}
        let lines=help.split(separator:"\n").map{$0.split(whereSeparator:{$0==" " || $0=="\t"}).joined(separator:" ")}
        let create=lines.filter{$0.hasPrefix("associate ")},remove=lines.filter{$0.hasPrefix("disassociate ")}
        guard create.count==1,remove.count==1 else{throw unsupported}
        if ["associate USER_ID PACKAGE MAC_ADDRESS [DEVICE_PROFILE]",
            "associate USER_ID PACKAGE MAC_ADDRESS [DEVICE_PROFILE] [SELF_MANAGED]"].contains(create[0]),
           remove[0]=="disassociate USER_ID PACKAGE MAC_ADDRESS" {return .positional}
        guard create[0]=="associate USER_ID PACKAGE",remove[0]=="disassociate USER_ID PACKAGE",
              let start=lines.firstIndex(of:create[0]),let end=lines.firstIndex(of:remove[0]),start<end else{throw unsupported}
        let createOptions=lines[(start+1)..<end]
        let removeOptions=lines.dropFirst(end+1).prefix(while:{!$0.hasPrefix("disassociate-all ")})
        guard createOptions.contains("--mac-address [MAC_ADDRESS]"),createOptions.contains("--profile [DEVICE_PROFILE]"),
              removeOptions.contains("--mac-address [MAC_ADDRESS]") else{throw unsupported}
        return .options
    }
    private static var unsupported:ScanError {
        ScanError("当前手机系统的临时连接接口暂不兼容。请更新 MiraDroid 后重试。")
    }
    private func validate(_ mac:String) throws {
        guard mac.utf8.count==17,mac.range(of:"^02:06:1D:([0-9A-F]{2}:){2}[0-9A-F]{2}$",options:.regularExpression) != nil else {
            throw ScanError("临时连接标记无效，已停止操作。")
        }
    }
    func associate(mac:String) throws ->String {
        try validate(mac)
        let prefix="cmd companiondevice associate 0 com.android.shell "
        let profile="android.app.role.COMPANION_DEVICE_APP_STREAMING"
        return prefix+(self == .options ? "--mac-address \(mac) --profile \(profile)":"\(mac) \(profile)")
    }
    func disassociate(mac:String) throws ->String {
        try validate(mac)
        return "cmd companiondevice disassociate 0 com.android.shell "+(self == .options ? "--mac-address ":"")+mac
    }
}
