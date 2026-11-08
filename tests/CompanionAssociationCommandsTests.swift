import Foundation
// Pure contract tests; no ADB, permissions, device or real recovery journal.
struct ScanError:LocalizedError {
    let message:String
    init(_ message:String){self.message=message}
    var errorDescription:String?{message}
}
@main enum CompanionAssociationCommandsTests {
    static func require(_ value:Bool) {precondition(value)}
    static func main() throws {
        let legacy="""
        Companion Device Manager (companiondevice) commands:
          associate USER_ID PACKAGE MAC_ADDRESS [DEVICE_PROFILE] [SELF_MANAGED]
          disassociate USER_ID PACKAGE MAC_ADDRESS
        """
        let modern="""
        Companion Device Manager (companiondevice) commands:
          associate USER_ID PACKAGE
            --mac-address [MAC_ADDRESS]
            --profile [DEVICE_PROFILE]
            --self-managed [SELF_MANAGED]
          disassociate USER_ID PACKAGE
            --id [ASSOCIATION_ID]
            --mac-address [MAC_ADDRESS]
          disassociate-all USER_ID
        """
        require(try CompanionAssociationCommands.detect(help:legacy) == .positional)
        require(try CompanionAssociationCommands.detect(help:modern,runtimeOptions:true) == .options)
        require(try CompanionAssociationCommands.detect(help:modern,runtimeOptions:false) == .positional)
        do {_=try CompanionAssociationCommands.detect(help:modern);fatalError("Help overrode unknown runtime switch")}catch{}
        func rejected(_ help:String) {
            do {_=try CompanionAssociationCommands.detect(help:help);fatalError("Unknown/incomplete contract accepted")}catch{}
        }
        rejected("Permission Denial");rejected(legacy+modern)
        rejected(modern.replacingOccurrences(of:"--profile [DEVICE_PROFILE]",with:"--other-profile [PROFILE]"))
        rejected(modern.replacingOccurrences(of:"  disassociate USER_ID PACKAGE",with:"  unknown USER_ID PACKAGE"))
        rejected(String(repeating:"x",count:65_537)+modern)
        for enabled in [false,true] {
            let data=try JSONSerialization.data(withJSONObject:["version":1,"cmdOptionsKnown":true,"cmdOptions":enabled])
            require(try CompanionAssociationCommands.runtimeOptions(in:data)==enabled)
        }
        for invalid in ["{}", "{\"version\":1,\"cmdOptionsKnown\":false,\"cmdOptions\":false}",
                        "{\"version\":1,\"cmdOptionsKnown\":true,\"cmdOptions\":0}",
                        "{\"version\":2,\"cmdOptionsKnown\":true,\"cmdOptions\":true}"] {
            do {_=try CompanionAssociationCommands.runtimeOptions(in:Data(invalid.utf8));fatalError("Unknown/malformed runtime state accepted")}catch{}
        }
        let target="02:06:1D:12:34:56"
        func reply(_ ids:[Int],targetMAC:String=target,user:Int=0,owner:String="com.android.shell",known:Bool=true) throws ->Data {
            try JSONSerialization.data(withJSONObject:["version":1,"associationKnown":known,"targetMAC":targetMAC,
                "userId":user,"ownerPackage":owner,"associationIDs":ids])
        }
        require(try CompanionAssociationCommands.associationID(in:reply([]),mac:target)==nil)
        require(try CompanionAssociationCommands.associationID(in:reply([15]),mac:target)==15)
        for invalid in [try reply([15,16]),try reply([0]),try reply([Int(Int32.max)+1]),try reply([15],targetMAC:"02:06:1D:00:00:00"),
                        try reply([15],user:1),try reply([15],owner:"org.example.other"),try reply([],known:false),Data("unrecognized CLI table".utf8)] {
            do {_=try CompanionAssociationCommands.associationID(in:invalid,mac:target);fatalError("Unverified association result accepted")}catch{}
        }
        require(try CompanionAssociationCommands.associationID(in:reply([15]),mac:target,expected:15)==15)
        do {_=try CompanionAssociationCommands.associationID(in:reply([15]),mac:target,expected:16);fatalError("Replacement association ID adopted")}catch{}
        var reads=0,clock=0.0
        let observed=try CompanionAssociationCommands.confirmAssociation(read:{reads+=1;return reads<3 ? nil:15},now:{clock},wait:{clock+=0.1})
        require(observed==15 && reads==3)
        do {_=try CompanionAssociationCommands.confirmAssociation(read:{nil},now:{clock},wait:{clock+=0.1});fatalError("Unknown pending creation was called absent")}catch{}
        do {_=try CompanionAssociationCommands.confirmAssociation(read:{throw ScanError("transport")});fatalError("Read failure became absent")}catch{}
        do {_=try CompanionAssociationCommands.confirmAssociation(read:{15},check:{throw CancellationError()});fatalError("Cancelled confirmation succeeded")}catch is CancellationError {}catch{fatalError("Wrong cancellation")}
        let mac="02:06:1D:12:34:56"
        require(try CompanionAssociationCommands.positional.associate(mac:mac)=="cmd companiondevice associate 0 com.android.shell 02:06:1D:12:34:56 android.app.role.COMPANION_DEVICE_APP_STREAMING")
        require(try CompanionAssociationCommands.options.associate(mac:mac)=="cmd companiondevice associate 0 com.android.shell --mac-address 02:06:1D:12:34:56 --profile android.app.role.COMPANION_DEVICE_APP_STREAMING")
        for syntax:CompanionAssociationCommands in [.positional,.options] {
            let remove=try syntax.disassociate(mac:mac)
            require(remove.hasPrefix("cmd companiondevice disassociate 0 com.android.shell ") && remove.hasSuffix(mac))
            require(remove.contains("--mac-address")==Bool(syntax == .options))
            for invalid in ["02:06:1D:12:34:56; id","02:06:1D:12:34:56\n", "00:11:22:33:44:55", "02:06:1d:12:34:56"] {
                do {_=try syntax.associate(mac:invalid);fatalError("Unsafe identity accepted")}catch{}
                do {_=try syntax.disassociate(mac:invalid);fatalError("Unsafe cleanup identity accepted")}catch{}
            }
        }
        print("PASS actual-format detection, exact scoped create/remove, malformed/ambiguous help and unsafe identity rejection")
    }
}
