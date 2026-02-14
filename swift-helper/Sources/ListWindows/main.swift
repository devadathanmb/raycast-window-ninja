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
}

// AX attribute reads all follow the same pattern: pass an attribute name string
// and a pointer, get back a value. These helpers wrap that.

func isMinimized(_ element: AXUIElement) -> Bool {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value)
    if err == .success, let minimized = value as? Bool {
        return minimized
    }
    return false
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

    // Try element IDs 0, 1, 2, 3... until we hit 500 or spend 50ms
    for elementId: AXUIElementID in 0..<500 {
        if CFAbsoluteTimeGetCurrent() - startTime > 0.05 { break }  // Don't spend more than 50ms per app

        // Update the token with this element ID
        remoteToken.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementId) { Data($0) })

        // Try to create an element with this ID
        // If this ID doesn't exist, the API returns nil and we skip to the next iteration
        guard
            let axElement = _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?
                .takeRetainedValue()
        else {
            continue  // This element ID doesn't exist, try next number
        }

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
func cgWindowScan() -> (realWIDs: Set<CGWindowID>, pidsWithWindows: Set<pid_t>) {
    let conn = CGSMainConnectionID()
    var realWIDs = Set<CGWindowID>()
    var pidsWithWindows = Set<pid_t>()

    guard
        let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
    else { return (realWIDs, pidsWithWindows) }

    for info in windowInfoList {
        guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
            let layer = info[kCGWindowLayer as String] as? Int,
            layer == 0
        else { continue }  // layer 0 = normal windows

        if let ownerPid = info[kCGWindowOwnerPID as String] as? Int32 {
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
        }
    }

    return (realWIDs, pidsWithWindows)
}

// Merges standard + brute-force results, deduplicating by CGWindowID.
//
// Strategy:
// 1. Use standard API (fast) to get windows on current Space
// 2. Use brute-force (slow) to find windows on other Spaces
// 3. Deduplicate: if a window appears in both, keep the standard version
// 4. Filter: only keep brute-force windows that have a Space assignment (removes tabs)
func allWindows(for pid: pid_t, realWIDs: Set<CGWindowID>) -> [AXUIElement] {
    let standard = axWindows(for: pid)  // Fast: windows on current Space
    let bruteForce = windowsByBruteForce(for: pid)  // Slow: windows on ALL Spaces

    var seenWindowIDs = Set<CGWindowID>()
    var combined: [AXUIElement] = []

    // First pass: add all standard windows (trusted, fast API)
    for win in standard {
        let title = getTitle(of: win)
        guard !title.isEmpty else { continue }
        if let wid = getWindowID(of: win) {
            seenWindowIDs.insert(wid)  // Remember this window ID to avoid duplicates
        }
        combined.append(win)
    }

    // Second pass: add brute-force windows NOT already seen
    for win in bruteForce {
        let title = getTitle(of: win)
        guard !title.isEmpty else { continue }

        guard let wid = getWindowID(of: win) else { continue }
        if seenWindowIDs.contains(wid) { continue }  // Already got this from standard API
        guard realWIDs.contains(wid) else { continue }  // Must have a Space (filters out tabs)
        seenWindowIDs.insert(wid)
        combined.append(win)
    }

    return combined
}

func listWindows() {
    let skipBundleIds = Set(["com.raycast.macos"])
    let (realWIDs, pidsWithWindows) = cgWindowScan()

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
        let windows = allWindows(for: app.pid, realWIDs: realWIDs)
        var localResults: [WindowInfo] = []

        for (index, window) in windows.enumerated() {
            let title = getTitle(of: window)
            guard !title.isEmpty else { continue }

            localResults.append(
                WindowInfo(
                    processName: app.name,
                    windowTitle: title,
                    bundleId: app.bundleId,
                    appPath: app.path,
                    pid: app.pid,
                    windowIndex: index,
                    isMinimized: isMinimized(window)
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

    let (realWIDs, _) = cgWindowScan()
    let windows = allWindows(for: pid, realWIDs: realWIDs)
    if windowIndex < windows.count {
        AXUIElementPerformAction(windows[windowIndex], kAXRaiseAction as CFString)
    }

    print("{\"success\":true}")
}

func closeWindow(pid: pid_t, windowIndex: Int) {
    let (realWIDs, _) = cgWindowScan()
    let windows = allWindows(for: pid, realWIDs: realWIDs)
    if windowIndex < windows.count {
        let window = windows[windowIndex]
        var closeButtonValue: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            window, kAXCloseButtonAttribute as CFString, &closeButtonValue)
        if err == .success, let closeButton = closeButtonValue {
            AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        }
    }

    print("{\"success\":true}")
}

// Usage: list-windows              → JSON array of all windows
//        list-windows focus <pid> <index>  → activate that window
//        list-windows close <pid> <index>  → close that window

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

    default:
        listWindows()
    }
}
