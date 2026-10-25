import Foundation

@main enum AndroidApplicationTests {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() async throws {
        let valid = AndroidApplication(packageName: "org.example.app", component: "org.example.app/.Main$Nested", name: "示例应用")
        require(valid.isValid && valid.canonicalComponent == "org.example.app/org.example.app.Main$Nested", "Launcher component validation")
        for component in ["org.other/.Main", "org.example.app/.Main;id", "org.example.app/.Main'", "org.example.app/.Main\n", "org.example.app/", "org.example.app/$(id)"] {
            require(!AndroidApplication(packageName: valid.packageName, component: component, name: "Fixture").isValid, "Unsafe component accepted")
        }
        require(!AndroidApplication(packageName: valid.packageName, component: valid.component, name: "bad\nlabel").isValid, "Control label accepted")
        let encoded = try JSONEncoder().encode([valid])
        require(try AndroidApplication.decodeCatalog(encoded) == [valid], "Catalog round trip")
        for catalog in [Array(repeating: valid, count: 2), Array(repeating: valid, count: 501)] {
            do { _ = try AndroidApplication.decodeCatalog(JSONEncoder().encode(catalog)); fatalError("Duplicate/oversized catalog accepted") } catch {}
        }
        require(AndroidAppDisplay(id: 8, width: 1080, height: 2400, dpi: 420).isValid, "Valid geometry refused")
        require(!AndroidAppDisplay(id: 0, width: 1080, height: 2400, dpi: 420).isValid, "Physical display accepted")
        require(!AndroidAppDisplay(id: 8, width: 5000, height: 2400, dpi: 420).isValid, "Invalid geometry accepted")
        let dump = """
        Display #0 (activities from top to bottom):
          * Task{abc #10 type=standard}
            * Task{def #12 type=standard}
              * Hist #0: ActivityRecord{a u0 org.example.app/.Main t12}
          * Task{ghi #20 type=standard}
            * Hist #0: ActivityRecord{b u0 org.example.other/.Main t20}
        Display #8 (activities from top to bottom):
          topResumedActivity=ActivityRecord{c u0 org.example.window/.Main t30}
          * Task{jkl #30 type=standard}
            * Hist #0: ActivityRecord{c u0 org.example.window/.Main t30}
          * Hist #0: ActivityRecord{d u10 org.private.app/.Main t40}
        """
        let tasks = AndroidTaskSnapshot.parse(dump)
        require(tasks.count == 3 && tasks[0].id == 12 && tasks[0].rootID == 10 && tasks[0].display == 0, "Nested root task parsing failed")
        require(tasks[1].rootID == 20 && tasks[2].display == 8 && tasks[2].rootID == 30, "Display task isolation failed")
        require(PhoneSession.foregroundComponent(in: dump, display: 8) == "org.example.window/.Main", "Foreground display selection")
        print("PASS authenticated catalog bounds, strict launcher identifiers, display geometry, nested task roots, primary-user isolation and foreground parsing")
    }
}
