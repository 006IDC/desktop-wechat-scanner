import Foundation

enum LauncherCatalogRequest {
    static func body(package:String,supported:Bool) throws ->Data {
        guard package.utf8.count<=255,package.range(of:"^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+$",options:.regularExpression) != nil else {
            throw ScanError("手机应用包名无效。")
        }
        return supported ? Data(package.utf8):Data()
    }
}
