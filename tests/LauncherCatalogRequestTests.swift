import Foundation
@main enum LauncherCatalogRequestTests {
    static func main() throws {
        let package="com.example.camera"
        let scoped=try LauncherCatalogRequest.body(package:package,supported:true)
        let legacy=try LauncherCatalogRequest.body(package:package,supported:false)
        precondition(scoped==Data(package.utf8));precondition(legacy==Data())
        let boundary="a."+String(repeating:"b",count:253)
        let maximum=try LauncherCatalogRequest.body(package:boundary,supported:true)
        precondition(maximum.count==255)
        for invalid in ["single","com.example/.Home","com.example\n","com.example;cmd",boundary+"b"] {
            for supported in [true,false] {
                do {_=try LauncherCatalogRequest.body(package:invalid,supported:supported);fatalError("Invalid launcher package accepted")}
                catch is ScanError {}
            }
        }
        print("PASS scoped launcher query, legacy empty payload and package bounds; no UI or phone")
    }
}
