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
        let legacyDisplay=try JSONDecoder().decode(AndroidAppDisplay.self,from:Data(#"{"id":8,"width":720,"height":1280,"dpi":320}"#.utf8))
        require(legacyDisplay.independentLock != true,"Old recovery must not grant independent lock access")
        let log=ServerLog()
        log.append(Data("QR_LIVE independent_lock_ready=1\n".utf8))
        require(!log.independentLockReady(),"Policy alone must not authorize a server before ready")
        log.append(Data("QR_LIVE rea".utf8));log.append(Data("dy=1\n".utf8))
        require(log.independentLockReady(),"Fragmented verified readiness was lost")
        let oldLog=ServerLog();oldLog.append(Data("QR_LIVE ready=1\n".utf8))
        require(!oldLog.independentLockReady(),"Legacy server readiness must not imply independent lock support")
        let nonce=String(repeating:"a",count:32)
        require(DirectMirrorDescriptor(display:8,socket:"006idc_video_"+nonce,token:nonce,width:720,height:1280).isValid,"Valid direct stream rejected")
        require(!DirectMirrorDescriptor(display:0,socket:"006idc_video_"+nonce,token:nonce,width:720,height:1280).isValid,"Direct physical display accepted")
        require(!DirectMirrorDescriptor(display:8,socket:"scrcpy_12345678",token:nonce,width:720,height:1280).isValid,"Unscoped direct socket accepted")
        require(!DirectMirrorDescriptor(display:8,socket:"006idc_video_"+nonce,token:nonce+"\n",width:720,height:1280).isValid,"Invalid direct token accepted")
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
        require(tasks.allSatisfy { !$0.isHome }, "Ordinary task was mistaken for the home root")
        require(PhoneSession.foregroundComponent(in: dump, display: 8) == "org.example.window/.Main", "Foreground display selection")
        // Redacted shape of the real failure: an empty split root followed by
        // orientation/focus diagnostics must not invent a WeChat task under it.
        let staleReferences = """
        ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)
          Display #0 (activities from top to bottom):
            * Task{home #7 type=home}
              * Task{homeLeaf #700 type=home}
                * Hist #0: ActivityRecord{homeRecord u0 org.example.launcher/.Home t700}
            * Task{emptySplit #6 type=undefined}
            mResumedActivity: ActivityRecord{stale u0 com.tencent.mm/.ui.LauncherUI t5385}
          mFocusedApp=ActivityRecord{stale u0 com.tencent.mm/.ui.LauncherUI t5385}
          RootWindowContainer:
            Display #0 displayId=0
              * Task{duplicate #6 type=undefined}
                * Hist #0: ActivityRecord{duplicate u0 com.tencent.mm/.ui.LauncherUI t5385}
          mLastOrientationSource=ActivityRecord{stale u0 com.tencent.mm/.ui.LauncherUI t5385}
        """
        let staleTasks = AndroidTaskSnapshot.parse(staleReferences)
        require(staleTasks.count == 1 && staleTasks[0].id == 700 && staleTasks[0].rootID == 7 && staleTasks[0].packageName == "org.example.launcher", "Non-authoritative or mismatched task records invented a WeChat task")
        require(staleTasks[0].isHome, "Explicit type=home at the authoritative root was lost")
        let homeTypes = """
        Display #0 (activities from top to bottom):
          * Task{type=home #10 type=standard sz=1}
            * Task{contains_home_in_name #11 type=home sz=1}
              * Hist  #0: ActivityRecord{homeLike u0 org.example.launcher/.Home t11}
          * Task{actualRoot #20 type=home sz=1}
            * Task{child #21 type=standard sz=1}
              * Hist  #0: ActivityRecord{real u0 org.example.app/.Main t21}
          * Task{unknownRoot #30 type=undefined sz=1}
            * Hist  #0: ActivityRecord{unknown u0 org.example.other/.Main t30}
        RootWindowContainer:
          Display #0 (activities from top to bottom):
            * Task{duplicate #30 type=home sz=1}
              * Hist  #0: ActivityRecord{stale u0 org.example.other/.Main t30}
        """
        let typedTasks = try AndroidTaskSnapshot.parseChecked(homeTypes, requiredDisplay: 0)
        require(typedTasks.count == 3 && typedTasks.first(where: { $0.id == 11 })?.isHome == false,
                "A home-like name or child type promoted an ordinary root")
        require(typedTasks.first(where: { $0.id == 21 })?.isHome == true,
                "The explicit home root type did not propagate to its leaf")
        require(typedTasks.first(where: { $0.id == 30 })?.isHome == false,
                "Unknown type or a non-authoritative duplicate promoted a normal task")
        require(!AndroidTaskSnapshot(id: 1, display: 0, packageName: "org.example.app", rootID: 1).isHome,
                "Legacy snapshot construction must default to non-home")
        let authoritative = """
          Display #0 (activities from top to bottom):
            topResumedActivity=ActivityRecord{stale u0 com.tencent.mm/.ui.LauncherUI t5385}
            * Task{root #10 type=standard}
              * Task{leaf #12 type=standard}
                * Hist #0: ActivityRecord{real u0 org.example.app/.Main t12}
              * Task{empty #6 type=undefined}
                mResumedActivity: ActivityRecord{stale u0 com.tencent.mm/.ui.LauncherUI t5385}
                * Hist #0: ActivityRecord{wrongTask u0 com.tencent.mm/.ui.LauncherUI t5385}
          Display #8 (activities from top to bottom):
            * Task{window #30 type=standard}
              * Hist #0: ActivityRecord{real u0 org.example.window/.Main t30}
          mFocusedApp=ActivityRecord{stale u0 org.example.app/.Wrong t12}
          mLastOrientationSource=ActivityRecord{stale u0 com.tencent.mm/.ui.LauncherUI t5385}
          RootWindowContainer:
            Display #0 (activities from top to bottom):
              * Task{duplicate #12 type=standard}
                * Hist #0: ActivityRecord{duplicate u0 org.example.app/.Wrong t12}
        """
        let authoritativeTasks = AndroidTaskSnapshot.parse(authoritative)
        require(authoritativeTasks.count == 2 && authoritativeTasks[0].id == 12 && authoritativeTasks[0].display == 0 && authoritativeTasks[0].rootID == 10 && authoritativeTasks[0].packageName == "org.example.app", "Tail diagnostics changed an authoritative root/display")
        require(authoritativeTasks[1].id == 30 && authoritativeTasks[1].rootID == 30 && authoritativeTasks[1].display == 8, "Authoritative second display was lost")
        // Android's actual formatting has two spaces after Hist; this must
        // produce a real task, rather than a falsely safe empty cleanup list.
        let canonicalSpacing = """
        Display #0 (activities from top to bottom):
          * Task{emptySplit #6 type=undefined}
          * Task{wechatRoot #5385 type=standard}
              * Hist  #0: ActivityRecord{realWechat u0 com.tencent.mm/.ui.LauncherUI t5385}
        Display #9 (activities from top to bottom):
          * Task{nestedRoot #40 type=standard}
            * Task{nestedLeaf #41 type=standard}
              * Hist  #0: ActivityRecord{nested u0 org.example.window/.Main t41}
        """
        let spacedTasks = AndroidTaskSnapshot.parse(canonicalSpacing)
        require(spacedTasks.count == 2 && spacedTasks.contains(where: { $0.id == 5385 && $0.rootID == 5385 && $0.display == 0 && $0.packageName == "com.tencent.mm" }), "Actual double-space Hist formatting lost a real WeChat task")
        require(spacedTasks.contains(where: { $0.id == 41 && $0.rootID == 40 && $0.display == 9 }), "Actual double-space Hist formatting lost nested task ownership")
        let invalidTrees = """
        Display #0 (activities from top to bottom):
          * Hist #0: ActivityRecord{noTask u0 org.example.app/.Main t12}
          * Task{empty #6 type=undefined}
            * Hist #0: ActivityRecord{mismatch u0 org.example.app/.Main t12}
        Display #8:
          * Task{notAnActivitiesTree #30 type=standard}
            * Hist #0: ActivityRecord{wrongTree u0 org.example.window/.Main t30}
        """
        require(AndroidTaskSnapshot.parse(invalidTrees).isEmpty, "Unverified task nesting or non-activity display accepted")
        let checkedEmpty = """
        Display #0 (activities from top to bottom):
          * Task{split #6 type=undefined sz=2}
            * Task{emptyLeft #7 type=undefined sz=0}
            * Task{emptyRight #8 type=undefined sz=0}
        Display #9 (activities from top to bottom):
        """
        require(try AndroidTaskSnapshot.parseChecked(checkedEmpty, requiredDisplay: 9).isEmpty, "Trusted empty display or split container child counts rejected")
        let checkedHistory = """
        Display #0 (activities from top to bottom):
          * Task{root #10 type=standard sz=1}
            * Task{leaf #12 type=standard sz=1}
              * Hist  #0: ActivityRecord{real u0 org.example.app/.Main t12}
        Display #9 (activities from top to bottom):
          * Task{empty #6 type=undefined sz=0}
        """
        let checkedTasks = try AndroidTaskSnapshot.parseChecked(checkedHistory, requiredDisplay: 0)
        require(checkedTasks.count == 1 && checkedTasks[0].id == 12 && checkedTasks[0].rootID == 10, "Checked parser lost real double-space Hist")
        let multipleHistory = """
        Display #0 (activities from top to bottom):
          * Task{splitRoot #6 type=undefined sz=2}
            * Task{empty #7 type=undefined sz=0}
            * Task{twoActivities #12 type=standard sz=2}
              * Hist  #1: ActivityRecord{top u0 org.example.app/.Second t12}
              * Hist  #0: ActivityRecord{base u0 org.example.app/.Main t12}
        """
        let multiTasks = try AndroidTaskSnapshot.parseChecked(multipleHistory, requiredDisplay: 0)
        require(multiTasks.count == 1 && multiTasks[0].id == 12 && multiTasks[0].rootID == 6, "sz direct child task count was confused with descendant Hist count")
        let withOtherUser = multipleHistory + "\nDisplay #8 (activities from top to bottom):\n  * Task{foreign #9 U=999 sz=1}\n    * Hist  #0: ActivityRecord{x u999 org.example.other/.Main t9}"
        let allUsers = try AndroidTaskSnapshot.parseChecked(withOtherUser, requiredDisplay: 0)
        require(allUsers.count == 2 && allUsers.first(where: { $0.id == 12 })?.userID == 0 &&
                allUsers.first(where: { $0.id == 9 })?.userID == 999,
                "An unrelated, valid cloned-app task must remain visible for root safety without blocking the primary user")
        do { _ = try AndroidTaskSnapshot.parseChecked(withOtherUser, requiredDisplay: 8); fatalError("Other user accepted on an owned display") } catch {}
        let emptyForeignDisplay = "Display #0 (activities from top to bottom):\n  * Task{primary #12 U=0 sz=0}\nDisplay #8 (activities from top to bottom):\n  * Task{clone #13 U=999 sz=0}"
        do { _ = try AndroidTaskSnapshot.parseChecked(emptyForeignDisplay, requiredDisplay: 8); fatalError("An empty other-user task on an owned display was invisible") } catch {}
        let physicalClone = """
        Display #0 (activities from top to bottom):
          * Task{primary #12 U=0 sz=1}
            * Hist  #0: ActivityRecord{main u0 org.example.app/.Main t12}
          * Task{clone #13 U=999 sz=1}
            * Hist  #0: ActivityRecord{other u999 org.example.app/.Main t13}
        Display #8 (activities from top to bottom):
        """
        let physicalTasks = try AndroidTaskSnapshot.parseChecked(physicalClone, requiredDisplay: 0)
        require(physicalTasks.count == 2 && physicalTasks.first(where: { $0.id == 13 })?.userID == 999 &&
                physicalTasks.first(where: { $0.id == 12 })?.rootContainsOtherUsers == false,
                "An unrelated clone on the physical display blocked a complete primary-user snapshot")
        let mixedRoot = """
        Display #0 (activities from top to bottom):
          * Task{shared #6 U=0 sz=2}
            * Task{primary #12 U=0 sz=1}
              * Hist  #0: ActivityRecord{main u0 org.example.app/.Main t12}
            * Task{otherEmpty #13 U=999 sz=0}
        """
        let shared = try AndroidTaskSnapshot.parseChecked(mixedRoot)
        require(shared.count == 1 && shared[0].userID == 0 && shared[0].rootContainsOtherUsers,
                "A foreign empty child must block moving its primary-user root")
        let mismatchedUser = "Display #0 (activities from top to bottom):\n  * Task{foreign #9 U=999 sz=1}\n    * Hist  #0: ActivityRecord{x u0 org.example.other/.Main t9}"
        do { _ = try AndroidTaskSnapshot.parseChecked(mismatchedUser); fatalError("Task header/history user mismatch accepted") } catch {}
        let rejectedTrees = [
            "Display #0 (unknown tree):\n  * Task{x #6 sz=0}",
            "Display #0 (activities from top to bottom):\n  * Task{x #6 sz=1}",
            "Display #0 (activities from top to bottom):\n  * Task{x #6 sz=0}\n    * Hist  #0: UnknownRecord{u0 org.example.app/.Main t6}",
            "Display #0 (activities from top to bottom):\n  * Task{x #6 sz=1}\n    * Hist  #0: ActivityRecord{x u0 org.example.app/.Main t7}",
            "Display #0 (activities from top to bottom):\n  * Task{x #6 sz=0}\n    Hist #0: ActivityRecord{x u0 org.example.app/.Main t6}",
            "Display #0 (activities from top to bottom):\n  * Task{x #6 sz=2}\n    * Task{oneKnownChild #7 sz=0}",
            "Display #0 (activities from top to bottom):\n  * Task{x #6}",
            "Display #0 (activities from top to bottom):\nDisplay #9 (unknown tree):\n  * Task{x #6 sz=0}",
            "Display #0 (activities from top to bottom):\n  * Task{x #6 U=10 sz=1}\n    * Hist  #0: ActivityRecord{x u0 org.example.app/.Main t6}"
        ]
        for tree in rejectedTrees {
            do { _ = try AndroidTaskSnapshot.parseChecked(tree, requiredDisplay: 0); fatalError("Unknown or incomplete tree accepted as safe") } catch {}
        }
        do { _ = try AndroidTaskSnapshot.parseChecked(checkedHistory, requiredDisplay: 99); fatalError("Unrecognized target accepted as empty") } catch {}
        print("PASS authoritative task parser and fail-closed checked production path, trusted empty displays/split children, real Hist spacing and unknown/partial/absent target rejection")
    }
}
