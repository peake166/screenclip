import CoreGraphics
import Foundation

@main struct CaptureWindowSelectionTests {
    static func main() {
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            print("\(value ? "PASS" : "FAIL") \(message)")
            if !value { failures += 1 }
        }
        let selection = CGRect(x: 485, y: 197, width: 549, height: 635)
        let windows = [
            CaptureWindowCandidate(id: 1, processID: 40, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isOnScreen: true, layer: 0),
            CaptureWindowCandidate(id: 2, processID: 99, frame: CGRect(x: 234, y: 59, width: 1059, height: 866), isOnScreen: true, layer: 0),
            CaptureWindowCandidate(id: 3, processID: 99, frame: CGRect(x: 476, y: 114, width: 560, height: 720), isOnScreen: true, layer: 0),
            CaptureWindowCandidate(id: 4, processID: 99, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isOnScreen: false, layer: 0),
            CaptureWindowCandidate(id: 5, processID: 99, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isOnScreen: true, layer: 20)
        ]
        check(CaptureWindowSelection.windowID(for: selection, processID: 99, windows: windows, frontToBack: [5, 4, 3, 2, 1]) == 3,
              "a selected detached chat uses the front visible chat window rather than the main window behind it")
        check(CaptureWindowSelection.windowID(for: selection, processID: 99, windows: windows, frontToBack: [2, 3, 1]) == 2,
              "window stacking determines the target when both chat and main windows contain the selected area")
        check(CaptureWindowSelection.windowID(for: CGRect(x: 10, y: 100, width: 200, height: 200), processID: 99,
              windows: windows, frontToBack: [5, 4, 3, 2, 1]) == nil,
              "selecting outside a chat never captures a different window behind the selection")
        check(CaptureWindowSelection.windowID(for: selection, processID: 50, windows: windows, frontToBack: [1, 2, 3]) == nil,
              "a different application's windows cannot satisfy the selected target")
        check(CaptureWindowSelection.windowID(for: selection, processID: 99, windows: windows, frontToBack: []) == 3,
              "the smallest containing window is used when stacking metadata is unavailable")
        let negative = CaptureWindowCandidate(id: 6, processID: 99,
            frame: CGRect(x: -1800, y: -600, width: 1000, height: 800), isOnScreen: true, layer: 0)
        check(CaptureWindowSelection.windowID(for: CGRect(x: -1700, y: -500, width: 600, height: 500),
              processID: 99, windows: [negative], frontToBack: [6]) == 6,
              "negative display coordinates retain the correct selected window")
        check(CaptureWindowSelection.targetProcessID(for: selection, preferredProcessID: 609, ownProcessID: 40,
              windows: windows, frontToBack: [1, 5, 4, 3, 2]) == 99,
              "the window under the selection overrides a stale WindowManager activation record")
        check(CaptureWindowSelection.targetProcessID(for: selection, preferredProcessID: nil, ownProcessID: 40,
              windows: windows, frontToBack: [1, 3, 2]) == 99,
              "the screenshot target is resolved even when the target application never became active")
        let other = CaptureWindowCandidate(id: 7, processID: 77,
            frame: CGRect(x: 450, y: 100, width: 700, height: 800), isOnScreen: true, layer: 0)
        check(CaptureWindowSelection.targetProcessID(for: selection, preferredProcessID: 99, ownProcessID: 40,
              windows: windows + [other], frontToBack: [1, 7, 3, 2]) == 77,
              "another visible foreground window takes priority over the previously active background application")
        check(CaptureWindowSelection.targetProcessID(for: CGRect(x: -2500, y: 0, width: 10, height: 20),
              preferredProcessID: 99, ownProcessID: 40, windows: windows, frontToBack: [1, 3, 2]) == nil,
              "an uncovered desktop region never inherits an unrelated application's compatibility capture")
        check(CaptureWindowSelection.targetProcessID(for: selection, preferredProcessID: 77, ownProcessID: 40,
              windows: windows + [other], frontToBack: []) == 77,
              "the active app is only used to break ties when stacking information is unavailable")
        let floating = CaptureWindowCandidate(id: 8, processID: 88,
            frame: CGRect(x: 450, y: 100, width: 700, height: 800), isOnScreen: true, layer: 3)
        let ownFloating = CaptureWindowCandidate(id: 9, processID: 40,
            frame: floating.frame, isOnScreen: true, layer: 3)
        let desktop = CaptureWindowCandidate(id: 10, processID: 55,
            frame: windows[0].frame, isOnScreen: true, layer: Int(CGWindowLevelForKey(.desktopWindow)))
        let menu = CaptureWindowCandidate(id: 11, processID: 66,
            frame: floating.frame, isOnScreen: true, layer: Int(CGWindowLevelForKey(.mainMenuWindow)))
        let layered = windows + [other, floating, ownFloating, desktop, menu]
        check(CaptureWindowSelection.targetProcessID(for: selection, preferredProcessID: 77, ownProcessID: 40,
              windows: layered, frontToBack: [9, 11, 10, 8, 7, 3, 2, 1]) == 88,
              "a visible floating application window wins over a normal underlay in the actual stacking order")
        check(CaptureWindowSelection.windowID(for: selection, processID: 88,
              windows: layered, frontToBack: [9, 11, 10, 8, 7, 3, 2, 1]) == 8,
              "a complete selection inside a floating window resolves its actual window ID")
        check(CaptureWindowSelection.targetProcessID(for: selection, preferredProcessID: 88, ownProcessID: 40,
              windows: layered, frontToBack: [7, 8, 3, 2, 1]) == 77,
              "stacking metadata remains authoritative when choosing among normal and floating windows")
        check(CaptureWindowSelection.targetProcessID(for: selection, preferredProcessID: 55, ownProcessID: 40,
              windows: [desktop], frontToBack: [10]) == nil,
              "a desktop layer cannot become a screenshot target")
        check(CaptureWindowSelection.targetProcessID(for: selection, preferredProcessID: 66, ownProcessID: 40,
              windows: [menu, windows[4]], frontToBack: [11, 5]) == nil,
              "menu and higher overlay layers cannot become screenshot targets")
        check(CaptureWindowSelection.targetProcessID(for: selection, preferredProcessID: 40, ownProcessID: 40,
              windows: [ownFloating], frontToBack: [9]) == nil,
              "the helper's own floating controls cannot become a screenshot target")
        check(CaptureWindowSelection.windowID(for: selection, processID: 55,
              windows: [desktop], frontToBack: [10]) == nil &&
              CaptureWindowSelection.windowID(for: selection, processID: 66,
              windows: [menu], frontToBack: [11]) == nil,
              "window ID resolution also rejects desktop and menu layers")
        if failures > 0 { print("\(failures) window selection checks failed"); exit(1) }
        print("All window selection checks passed")
    }
}
