import ApplicationServices
import Cocoa
import Foundation

// Undocumented macOS APIs (same technique as AltTab - lwouis/alt-tab-macos).
// @_silgen_name links directly to private C symbols that aren't in any public header.

// Creates an AXUIElement from a raw token — lets us find windows on other Spaces.
@_silgen_name("_AXUIElementCreateWithRemoteToken") @discardableResult
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

// Bridges AXUIElement -> CGWindowID so we can cross-reference with CGWindowList.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>)
    -> AXError

// Session connection ID, required by other private Space APIs.
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int

// Returns which Space(s) a window belongs to. Windows without a Space are browser
// tabs (they get a CGWindowID but no Space assignment).
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: Int, _ selector: Int, _ windowIDs: CFArray) -> CFArray?

typealias AXUIElementID = UInt

struct WindowInfo: Codable {
    let processName: String
    let windowTitle: String
    let bundleId: String
    let appPath: String
    let pid: Int32
    let windowIndex: Int
    let isMinimized: Bool
    let isFullscreen: Bool
    let isAppHidden: Bool
}

// AX attribute reads all follow the same pattern: pass an attribute name string
// and a pointer, get back a value. These helpers wrap that.

func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, attribute, &value)
    if err == .success, let flag = value as? Bool {
        return flag
    }
    return nil
}

func isMinimized(_ element: AXUIElement) -> Bool {
    return boolAttribute(element, kAXMinimizedAttribute as CFString) ?? false
}

func isFullscreen(_ element: AXUIElement) -> Bool {
    return boolAttribute(element, "AXFullScreen" as CFString) ?? false
}

func getTitle(of element: AXUIElement) -> String {
    var titleValue: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
    if err == .success, let title = titleValue as? String {
        return title
    }
    return ""
}

func getWindowID(of element: AXUIElement) -> CGWindowID? {
    var windowID: CGWindowID = 0
    let err = _AXUIElementGetWindow(element, &windowID)
    return err == .success && windowID != 0 ? windowID : nil
}

// Standard AX API — only returns windows on the current Space.
func axWindows(for pid: pid_t) -> [AXUIElement] {
    let appElement = AXUIElementCreateApplication(pid)
    var windowsValue: AnyObject?
    let err = AXUIElementCopyAttributeValue(
        appElement, kAXWindowsAttribute as CFString, &windowsValue)
    if err == .success, let windows = windowsValue as? [AXUIElement] {
        return windows
    }
    return []
}

// Brute-force discovery for windows on OTHER Spaces (fullscreen apps, etc.).
//
// The standard AX API only returns windows on the current Space. To find windows on
// other Spaces, we use a private API that accepts a "remote token" to create AX elements.
//
// Since there's no "give me all windows" function, we have to guess element IDs one by one.
// The private API can only fetch ONE element at a time by its ID:
//   _AXUIElementCreateWithRemoteToken(token) → returns element or nil
//
// We construct a 20-byte "remote token" for each guess:
//   bytes 0-3:   PID (which app to search in)
//   bytes 4-7:   reserved (zero)
//   bytes 8-11:  0x636f636f ("coco" — marks it as a Cocoa app)
//   bytes 12-19: element ID (the part we loop through: 0, 1, 2, 3...)
//
// We try IDs 0–499 with a 50ms timeout per app and keep standard windows/dialogs.
func windowsByBruteForce(for pid: pid_t) -> [AXUIElement] {
    // Build the base token with PID and "coco" marker
    var remoteToken = Data(count: 20)
    remoteToken.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })  // PID
    remoteToken.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })  // Reserved
    remoteToken.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })  // "coco"

    var results: [AXUIElement] = []
    let startTime = CFAbsoluteTimeGetCurrent()
    var consecutiveMisses = 0

    // Try element IDs 0, 1, 2, 3... until we hit 500, spend 50ms, or
    // see 50 consecutive misses (IDs cluster in low numbers, so gaps mean we're done).
    for elementId: AXUIElementID in 0..<500 {
        if consecutiveMisses > 50 { break }  // No more elements likely exist
        if CFAbsoluteTimeGetCurrent() - startTime > 0.05 { break }  // Don't spend more than 50ms per app

        // Update the token with this element ID
        remoteToken.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementId) { Data($0) })

        // Try to create an element with this ID
        // If this ID doesn't exist, the API returns nil and we skip to the next iteration
        guard
            let axElement = _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?
                .takeRetainedValue()
        else {
            consecutiveMisses += 1
            continue  // This element ID doesn't exist, try next number
        }
        consecutiveMisses = 0

        // Check if this element is a window (not a button, menu, tab, etc.)
        var subroleValue: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            axElement, kAXSubroleAttribute as CFString, &subroleValue)
        guard err == .success, let subrole = subroleValue as? String else { continue }

        // Only keep actual windows and dialogs, skip everything else
        if subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String {
            results.append(axElement)
        }
    }

    return results
}

// Single pass over CGWindowList to get:
// - realWIDs: windows assigned to a Space (actual windows, not browser tabs)
// - pidsWithWindows: which PIDs have windows, so we can skip brute-forcing the rest
// - realWindowCountByPid: how many real windows each PID owns (used to skip brute-force)
func cgWindowScan() -> (
    realWIDs: Set<CGWindowID>, pidsWithWindows: Set<pid_t>,
    realWindowCountByPid: [pid_t: Int]
) {
    let conn = CGSMainConnectionID()
    var realWIDs = Set<CGWindowID>()
    var pidsWithWindows = Set<pid_t>()
    var realWindowCountByPid: [pid_t: Int] = [:]

    guard
        let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
    else { return (realWIDs, pidsWithWindows, realWindowCountByPid) }

    for info in windowInfoList {
        guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
            let layer = info[kCGWindowLayer as String] as? Int,
            layer == 0
        else { continue }  // layer 0 = normal windows

        let ownerPid = info[kCGWindowOwnerPID as String] as? Int32
        if let ownerPid = ownerPid {
            pidsWithWindows.insert(ownerPid)
        }

        // Check if this window is assigned to a macOS Space.
        // Real windows belong to a Space. Browser tabs get a CGWindowID but NO Space assignment.
        // This is how we tell them apart.
        let widArray = [wid] as CFArray
        if let spaces = CGSCopySpacesForWindows(conn, 0x7, widArray) as? [UInt64],
            !spaces.isEmpty
        {
            realWIDs.insert(wid)  // This window has a Space → it's real, not a tab
            if let ownerPid = ownerPid {
                realWindowCountByPid[ownerPid, default: 0] += 1
            }
        }
    }

    return (realWIDs, pidsWithWindows, realWindowCountByPid)
}

// Merges standard + brute-force results, deduplicating by CGWindowID.
// Returns (AXUIElement, title) tuples so callers don't need to re-read titles.
//
// Strategy:
// 1. Use standard API (fast) to get windows on current Space
// 2. If standard already found all windows (matching expectedCount), skip brute-force
// 3. Otherwise use brute-force (slow) to find windows on other Spaces
// 4. Deduplicate: if a window appears in both, keep the standard version
// 5. Filter: only keep brute-force windows that have a Space assignment (removes tabs)
func allWindows(for pid: pid_t, realWIDs: Set<CGWindowID>, expectedCount: Int)
    -> [(element: AXUIElement, title: String)]
{
    let standard = axWindows(for: pid)  // Fast: windows on current Space

    var seenWindowIDs = Set<CGWindowID>()
    var combined: [(element: AXUIElement, title: String)] = []

    // First pass: add all standard windows (trusted, fast API)
    for win in standard {
        let title = getTitle(of: win)
        guard !title.isEmpty else { continue }
        if let wid = getWindowID(of: win) {
            seenWindowIDs.insert(wid)  // Remember this window ID to avoid duplicates
        }
        combined.append((element: win, title: title))
    }

    // Skip brute-force if standard API already found all windows for this app.
    // This means the app has no windows on other Spaces.
    if combined.count >= expectedCount {
        return combined
    }

    // Brute-force: find windows on other Spaces
    let bruteForce = windowsByBruteForce(for: pid)

    // Second pass: add brute-force windows NOT already seen
    for win in bruteForce {
        let title = getTitle(of: win)
        guard !title.isEmpty else { continue }

        guard let wid = getWindowID(of: win) else { continue }
        if seenWindowIDs.contains(wid) { continue }  // Already got this from standard API
        guard realWIDs.contains(wid) else { continue }  // Must have a Space (filters out tabs)
        seenWindowIDs.insert(wid)
        combined.append((element: win, title: title))
    }

    return combined
}

func listWindows() {
    let skipBundleIds = Set(["com.raycast.macos"])
    let (realWIDs, pidsWithWindows, realWindowCountByPid) = cgWindowScan()

    struct AppEntry {
        let name: String
        let bundleId: String
        let path: String
        let pid: pid_t
    }

    // Only process apps that own at least one window (skips background agents
    // with .regular activation policy but no visible windows).
    var apps: [AppEntry] = []
    for app in NSWorkspace.shared.runningApplications {
        guard app.activationPolicy == .regular else { continue }
        let bundleId = app.bundleIdentifier ?? ""
        guard !skipBundleIds.contains(bundleId) else { continue }
        let pid = app.processIdentifier
        guard pidsWithWindows.contains(pid) else { continue }

        apps.append(
            AppEntry(
                name: app.localizedName ?? "",
                bundleId: bundleId,
                path: app.bundleURL?.path ?? "",
                pid: pid
            ))
    }

    // Enumerate each app's windows in parallel (GCD) for speed.
    // Since we're modifying a shared array from multiple threads, we need a lock.
    let lock = NSLock()
    var allResults: [WindowInfo] = []

    DispatchQueue.concurrentPerform(iterations: apps.count) { i in
        let app = apps[i]
        let expectedCount = realWindowCountByPid[app.pid] ?? 0
        let windows = allWindows(for: app.pid, realWIDs: realWIDs, expectedCount: expectedCount)
        var localResults: [WindowInfo] = []

        // Titles are already resolved — no need to call getTitle again
        for (index, entry) in windows.enumerated() {
            localResults.append(
                WindowInfo(
                    processName: app.name,
                    windowTitle: entry.title,
                    bundleId: app.bundleId,
                    appPath: app.path,
                    pid: app.pid,
                    windowIndex: index,
                    isMinimized: isMinimized(entry.element),
                    isFullscreen: isFullscreen(entry.element),
                    isAppHidden: NSRunningApplication(processIdentifier: app.pid)?.isHidden ?? false
                ))
        }

        lock.lock()
        allResults.append(contentsOf: localResults)
        lock.unlock()
    }

    let encoder = JSONEncoder()
    if let data = try? encoder.encode(allResults) {
        print(String(data: data, encoding: .utf8)!)
    }
}

func focusWindow(pid: pid_t, windowIndex: Int) {
    if let app = NSRunningApplication(processIdentifier: pid) {
        app.activate()
    }

    let (realWIDs, _, realWindowCountByPid) = cgWindowScan()
    let expectedCount = realWindowCountByPid[pid] ?? 0
    let windows = allWindows(for: pid, realWIDs: realWIDs, expectedCount: expectedCount)
    if windowIndex < windows.count {
        AXUIElementPerformAction(windows[windowIndex].element, kAXRaiseAction as CFString)
    }

    print("{\"success\":true}")
}

// Check if a window with the given CGWindowID still exists for a given PID.
func windowExists(_ targetWindowID: CGWindowID, pid: pid_t) -> Bool {
    let (newRealWIDs, _, newRealWindowCountByPid) = cgWindowScan()
    let newExpectedCount = newRealWindowCountByPid[pid] ?? 0
    let newWindows = allWindows(for: pid, realWIDs: newRealWIDs, expectedCount: newExpectedCount)
    return newWindows.contains { getWindowID(of: $0.element) == targetWindowID }
}

func closeWindow(pid: pid_t, windowIndex: Int) {
    let (realWIDs, _, realWindowCountByPid) = cgWindowScan()
    let expectedCount = realWindowCountByPid[pid] ?? 0
    let windows = allWindows(for: pid, realWIDs: realWIDs, expectedCount: expectedCount)

    if windowIndex >= windows.count {
        print("{\"success\":false,\"error\":\"Window not found\"}")
        return
    }

    let window = windows[windowIndex].element
    let app = NSRunningApplication(processIdentifier: pid)

    // Get the window ID for later verification
    guard let targetWindowID = getWindowID(of: window) else {
        print("{\"success\":false,\"error\":\"Could not get window ID\"}")
        return
    }

    // Strategy 1: Try clicking the close button
    var closeButtonValue: AnyObject?
    let err = AXUIElementCopyAttributeValue(
        window, kAXCloseButtonAttribute as CFString, &closeButtonValue)
    if err == .success, let closeButton = closeButtonValue {
        AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        usleep(200000)  // 200ms - wait before verifying

        if !windowExists(targetWindowID, pid: pid) {
            // If this was the last window, terminate the app to prevent it staying in dock
            if windows.count == 1, let app = app {
                app.terminate()
            }
            print("{\"success\":true,\"method\":\"closeButton\"}")
            return
        }
    }

    // Strategy 2: Try AppleScript - more reliable for terminal emulators
    if let app = app, let bundleId = app.bundleIdentifier {
        // Use window title to identify the correct window, since AX enumeration
        // order does not necessarily match AppleScript's window ordering
        let title = windows[windowIndex].title
        let escapedTitle = title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource =
            "tell application id \"\(bundleId)\" to close (first window whose name is \"\(escapedTitle)\")"
        if let appleScript = NSAppleScript(source: scriptSource) {
            var scriptError: NSDictionary?
            appleScript.executeAndReturnError(&scriptError)
            if scriptError == nil {
                usleep(200000)  // 200ms - verify the window actually closed
                if !windowExists(targetWindowID, pid: pid) {
                    // If this was the last window, terminate the app to prevent it staying in dock
                    if windows.count == 1 {
                        app.terminate()
                    }
                    print("{\"success\":true,\"method\":\"applescript\"}")
                    return
                }
            }
        }
    }

    // Strategy 3: If it's the only window, terminate the app
    if windows.count == 1, let app = app {
        app.terminate()
        print("{\"success\":true,\"method\":\"terminate\"}")
        return
    }

    print("{\"success\":false,\"error\":\"All close methods failed\"}")
}

func minimizeWindow(pid: pid_t, windowIndex: Int) {
    let (realWIDs, _, realWindowCountByPid) = cgWindowScan()
    let expectedCount = realWindowCountByPid[pid] ?? 0
    let windows = allWindows(for: pid, realWIDs: realWIDs, expectedCount: expectedCount)

    if windowIndex >= windows.count {
        print("{\"success\":false,\"error\":\"Window not found\"}")
        return
    }

    var window = windows[windowIndex].element

    // Fullscreen windows often reject direct minimization. Exit fullscreen first,
    // wait for the transition, then minimize.
    if isFullscreen(window) {
        _ = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        usleep(250000)  // 250ms for Space/fullscreen transition start
    }

    // Retry for up to ~2s. Exiting fullscreen is asynchronous and can briefly reject minimize.
    for _ in 0..<10 {
        let err = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        if err == .success || boolAttribute(window, kAXMinimizedAttribute as CFString) == true {
            print("{\"success\":true}")
            return
        }

        usleep(200000)

        // Refresh the target element in case the fullscreen transition replaced the AX element.
        let (refreshRealWIDs, _, refreshCountByPid) = cgWindowScan()
        let refreshExpectedCount = refreshCountByPid[pid] ?? 0
        let refreshedWindows = allWindows(
            for: pid, realWIDs: refreshRealWIDs, expectedCount: refreshExpectedCount)
        if windowIndex < refreshedWindows.count {
            window = refreshedWindows[windowIndex].element
        }
    }

    print("{\"success\":false,\"error\":\"Failed to minimize window\"}")
}

func maximizeWindow(pid: pid_t, windowIndex: Int) {
    let (realWIDs, _, realWindowCountByPid) = cgWindowScan()
    let expectedCount = realWindowCountByPid[pid] ?? 0
    let windows = allWindows(for: pid, realWIDs: realWIDs, expectedCount: expectedCount)

    if windowIndex >= windows.count {
        print("{\"success\":false,\"error\":\"Window not found\"}")
        return
    }

    let window = windows[windowIndex].element
    let err = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    if err == .success || boolAttribute(window, kAXMinimizedAttribute as CFString) == false {
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        print("{\"success\":true}")
    } else {
        print("{\"success\":false,\"error\":\"Failed to maximize window\"}")
    }
}

func makeWindowFullscreen(pid: pid_t, windowIndex: Int) {
    let (realWIDs, _, realWindowCountByPid) = cgWindowScan()
    let expectedCount = realWindowCountByPid[pid] ?? 0
    let windows = allWindows(for: pid, realWIDs: realWIDs, expectedCount: expectedCount)

    if windowIndex >= windows.count {
        print("{\"success\":false,\"error\":\"Window not found\"}")
        return
    }

    let err = AXUIElementSetAttributeValue(
        windows[windowIndex].element, "AXFullScreen" as CFString, kCFBooleanTrue)
    if err == .success {
        print("{\"success\":true}")
    } else {
        print("{\"success\":false,\"error\":\"Failed to make window full screen\"}")
    }
}

func exitWindowFullscreen(pid: pid_t, windowIndex: Int) {
    let (realWIDs, _, realWindowCountByPid) = cgWindowScan()
    let expectedCount = realWindowCountByPid[pid] ?? 0
    let windows = allWindows(for: pid, realWIDs: realWIDs, expectedCount: expectedCount)

    if windowIndex >= windows.count {
        print("{\"success\":false,\"error\":\"Window not found\"}")
        return
    }

    let err = AXUIElementSetAttributeValue(
        windows[windowIndex].element, "AXFullScreen" as CFString, kCFBooleanFalse)
    if err == .success {
        print("{\"success\":true}")
    } else {
        print("{\"success\":false,\"error\":\"Failed to exit full screen\"}")
    }
}

func hideApplication(pid: pid_t) {
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        print("{\"success\":false,\"error\":\"Application not found\"}")
        return
    }

    if app.hide() {
        print("{\"success\":true}")
    } else {
        print("{\"success\":false,\"error\":\"Failed to hide application\"}")
    }
}

func showApplication(pid: pid_t) {
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        print("{\"success\":false,\"error\":\"Application not found\"}")
        return
    }

    let unhidden = app.unhide()
    _ = app.activate()
    if unhidden {
        print("{\"success\":true}")
    } else {
        print("{\"success\":false,\"error\":\"Failed to show application\"}")
    }
}

// Usage: list-windows              → JSON array of all windows
//        list-windows focus <pid> <index>  → activate that window
//        list-windows close <pid> <index>  → close that window
//        list-windows minimize <pid> <index>  → minimize that window
//        list-windows maximize <pid> <index>  → unminimize that window
//        list-windows fullscreen <pid> <index>  → make that window full screen
//        list-windows unfullscreen <pid> <index>  → exit full screen for that window
//        list-windows hide-app <pid>  → hide that application
//        list-windows show-app <pid>  → unhide that application

let args = CommandLine.arguments

if args.count < 2 {
    listWindows()
} else {
    switch args[1] {
    case "focus":
        guard args.count >= 4,
            let pid = Int32(args[2]),
            let idx = Int(args[3])
        else {
            fputs("Usage: list-windows focus <pid> <windowIndex>\n", stderr)
            exit(1)
        }
        focusWindow(pid: pid, windowIndex: idx)

    case "close":
        guard args.count >= 4,
            let pid = Int32(args[2]),
            let idx = Int(args[3])
        else {
            fputs("Usage: list-windows close <pid> <windowIndex>\n", stderr)
            exit(1)
        }
        closeWindow(pid: pid, windowIndex: idx)

    case "minimize":
        guard args.count >= 4,
            let pid = Int32(args[2]),
            let idx = Int(args[3])
        else {
            fputs("Usage: list-windows minimize <pid> <windowIndex>\n", stderr)
            exit(1)
        }
        minimizeWindow(pid: pid, windowIndex: idx)

    case "maximize":
        guard args.count >= 4,
            let pid = Int32(args[2]),
            let idx = Int(args[3])
        else {
            fputs("Usage: list-windows maximize <pid> <windowIndex>\n", stderr)
            exit(1)
        }
        maximizeWindow(pid: pid, windowIndex: idx)

    case "fullscreen":
        guard args.count >= 4,
            let pid = Int32(args[2]),
            let idx = Int(args[3])
        else {
            fputs("Usage: list-windows fullscreen <pid> <windowIndex>\n", stderr)
            exit(1)
        }
        makeWindowFullscreen(pid: pid, windowIndex: idx)

    case "unfullscreen":
        guard args.count >= 4,
            let pid = Int32(args[2]),
            let idx = Int(args[3])
        else {
            fputs("Usage: list-windows unfullscreen <pid> <windowIndex>\n", stderr)
            exit(1)
        }
        exitWindowFullscreen(pid: pid, windowIndex: idx)

    case "hide-app":
        guard args.count >= 3,
            let pid = Int32(args[2])
        else {
            fputs("Usage: list-windows hide-app <pid>\n", stderr)
            exit(1)
        }
        hideApplication(pid: pid)

    case "show-app":
        guard args.count >= 3,
            let pid = Int32(args[2])
        else {
            fputs("Usage: list-windows show-app <pid>\n", stderr)
            exit(1)
        }
        showApplication(pid: pid)

    default:
        listWindows()
    }
}
