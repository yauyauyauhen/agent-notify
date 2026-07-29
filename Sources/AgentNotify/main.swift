// agent-notify — single-supervisor notification daemon for AI-agent sessions.
//
// v2: modern UNUserNotificationCenter API, running as its own real app
// bundle. v1 impersonated the terminal's bundle identity over the legacy
// NSUserNotification API — that died the day the terminal was Ghostty:
// usernoted refuses legacy connections for any bundle id that has ever
// registered as a modern notification client ("You can't mix modern clients
// with legacy clients"), and modern terminals register. Owning our own
// identity removes the hack entirely — and with it the whole class of
// connection-scoped races that plague per-banner notifier processes
// (https://github.com/vjeantet/alerter/issues/75).
//
// Protocol: newline-delimited JSON over a unix stream socket.
//   {"cmd":"post","group":G,"title":T,"message":M,"replace_same_title":B,"focus_hint":H} -> {"ok":true}
//   {"cmd":"remove","group":G}       -> {"ok":true,"removed":N}
//   {"cmd":"remove-title","title":T} -> {"ok":true,"removed":N}
//   {"cmd":"list"}                   -> {"ok":true,"notifications":[...]}
// Unknown command or bad JSON -> {"ok":false,"error":"..."}
//
// The daemon never removes banners on its own exit: delivered notifications
// belong to the bundle identity, so a restarted daemon manages banners
// posted by its predecessor.

import AppKit
import UserNotifications

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: agent-notify <focus-bundle-id> <socket-path>\n".data(using: .utf8)!)
    exit(2)
}
// The app to bring forward when a banner is clicked — your terminal.
let focusTarget = args[1]
let socketPath = args[2]

func log(_ message: String) {
    FileHandle.standardError.write("agent-notify: \(message)\n".data(using: .utf8)!)
}

let center = UNUserNotificationCenter.current()

// MARK: - Window targeting (optional, needs one Accessibility grant)
// A clicked banner's own title ("chat / worktree / repo") doubles as the
// focus hint: match its parts, most specific first, against the terminal's
// window titles and raise the matched window before activating the app.
// Without the Accessibility grant this quietly degrades to app-level focus.

func raiseWindow(exactHints: [String], hints: [String]) -> Bool {
    guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: focusTarget).first else {
        log("raise: focus target not running")
        return false
    }
    let ax = AXUIElementCreateApplication(running.processIdentifier)
    var winsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &winsRef) == .success,
          let windows = winsRef as? [AXUIElement] else {
        log("raise: window enumeration failed")
        return false
    }
    var titles: [(AXUIElement, String)] = []
    for window in windows {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        titles.append((window, (titleRef as? String) ?? ""))
    }
    log("raise: exactHints=\(exactHints.map { $0.unicodeScalars.count }) hints=\(hints) windows=\(titles.map { $0.1 })")
    // Exact hints first: invisible zero-width window markers (a pane's tty
    // number encoded into the title by the launcher). MUST use literal
    // substring matching — localized comparison treats zero-width characters
    // as ignorable, so a zero-width-only needle would "match" every title.
    // .literal: code-unit-exact search. Default String.contains compares
    // grapheme clusters, and zero-width characters cluster with neighboring
    // letters — the marker would intermittently fail to match its own window.
    for hint in exactHints where !hint.isEmpty {
        for (window, title) in titles where !title.isEmpty {
            if title.range(of: hint, options: .literal) != nil {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                log("raise: matched '\(title)' via exact marker")
                return true
            }
        }
    }
    // All EXACT attempts must run before any fuzzy guessing: the AX list
    // above only covers the current Space, but the app's Window menu lists
    // every window on every Space — a banner whose window sits on another
    // Space is exactly findable there by its marker, and a premature fuzzy
    // hit on a same-named twin here would steal the click (observed live).
    if pressWindowMenuItem(hints: exactHints, exact: true, appAX: ax) {
        return true
    }
    // Fuzzy fallback, via the Window menu so uniqueness is judged GLOBALLY:
    // "unique on the current Space" can still be the wrong twin when its
    // namesake lives on another Space. Only an app-wide unique title match
    // is safe to raise; anything ambiguous degrades to app-level focus.
    if pressWindowMenuItem(hints: hints, exact: false, appAX: ax) {
        return true
    }
    log("raise: no window matched")
    return false
}

func pressWindowMenuItem(hints: [String], exact: Bool, appAX: AXUIElement) -> Bool {
    var menubarRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appAX, kAXMenuBarAttribute as CFString, &menubarRef) == .success,
          CFGetTypeID(menubarRef!) == AXUIElementGetTypeID() else { return false }
    let menubar = menubarRef as! AXUIElement
    var menusRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(menubar, kAXChildrenAttribute as CFString, &menusRef) == .success,
          let menus = menusRef as? [AXUIElement] else { return false }
    for menu in menus {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(menu, kAXTitleAttribute as CFString, &titleRef)
        guard (titleRef as? String) == "Window" else { continue }
        var subRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &subRef) == .success,
              let submenus = subRef as? [AXUIElement], let itemsMenu = submenus.first else { return false }
        var itemsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(itemsMenu, kAXChildrenAttribute as CFString, &itemsRef) == .success,
              let items = itemsRef as? [AXUIElement] else { return false }
        var itemTitles: [(AXUIElement, String)] = []
        for item in items {
            var itemTitleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &itemTitleRef)
            if let t = itemTitleRef as? String, !t.isEmpty { itemTitles.append((item, t)) }
        }
        for hint in hints where !hint.isEmpty {
            if exact {
                // Zero-width markers: literal code-unit matching (see
                // raiseWindow); markers are unique by construction, so the
                // first hit is THE window.
                for (item, itemTitle) in itemTitles {
                    if itemTitle.range(of: hint, options: .literal) != nil {
                        AXUIElementPerformAction(item, kAXPressAction as CFString)
                        log("raise: pressed Window-menu item '\(itemTitle)' via exact marker")
                        return true
                    }
                }
            } else {
                // Fuzzy: raise only on an app-wide UNIQUE title match.
                let candidates = itemTitles.filter { $0.1.localizedCaseInsensitiveContains(hint) }
                if candidates.count == 1 {
                    let (item, itemTitle) = candidates[0]
                    AXUIElementPerformAction(item, kAXPressAction as CFString)
                    log("raise: pressed Window-menu item '\(itemTitle)' via hint '\(hint)'")
                    return true
                }
                if candidates.count > 1 {
                    log("raise: menu hint '\(hint)' ambiguous across \(candidates.count) items — not guessing")
                }
            }
        }
        log("raise: no Window-menu match")
        return false
    }
    log("raise: no Window menu found")
    return false
}

final class Delegate: NSObject, UNUserNotificationCenterDelegate {
    // Present even if this (background) app were ever considered frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    // Body click: macOS already dismisses the clicked banner; we add the
    // second half of the gesture — bring the terminal forward, at the
    // specific window when the banner title identifies one.
    //
    // Focus mechanics (macOS 26): cooperative activation ignores a plain
    // "activate that app" request from a background process. The click grants
    // THIS app the activation, so we must explicitly yield it to the terminal
    // and activate the running instance — openApplication alone silently
    // does nothing.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        log("didReceive action=\(response.actionIdentifier)")
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let id = response.notification.request.identifier
            let bannerTitle = response.notification.request.content.title
            let focusHint = response.notification.request.content.userInfo["focusHint"] as? String ?? ""
            center.removeDeliveredNotifications(withIdentifiers: [id])
            DispatchQueue.main.async {
                let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                if AXIsProcessTrustedWithOptions(prompt as CFDictionary) {
                    _ = raiseWindow(exactHints: [focusHint],
                                    hints: bannerTitle.components(separatedBy: " / "))
                } else {
                    log("accessibility not granted — window targeting skipped")
                }
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(toApplicationWithBundleIdentifier: focusTarget)
                }
                if let running = NSRunningApplication
                        .runningApplications(withBundleIdentifier: focusTarget).first {
                    let ok: Bool
                    if #available(macOS 14.0, *) {
                        ok = running.activate(from: .current, options: [])
                    } else {
                        ok = running.activate(options: [.activateIgnoringOtherApps])
                    }
                    log("activate \(focusTarget) -> \(ok)")
                } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: focusTarget) {
                    NSWorkspace.shared.openApplication(at: url,
                                                       configuration: NSWorkspace.OpenConfiguration())
                    log("launched \(focusTarget)")
                } else {
                    log("focus target \(focusTarget) not found")
                }
                // Belt and suspenders: a child `open` process is a fresh
                // non-app client of LaunchServices, exempt from the
                // cooperative-activation rules that ignore background apps.
                let opener = Process()
                opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                opener.arguments = ["-b", focusTarget]
                try? opener.run()
            }
        }
        completionHandler()
    }
}

// MARK: - Seating map (exact session restore)
// Terminal panes carry an invisible zero-width tty marker in their on-screen
// text (the Claude statusline emits it; window titles carry the same code).
// A periodic sampler walks every split's AXTextArea, decodes the marker, and
// records tty -> (window frame + split path). After a terminal relaunch the
// restoring pane prints a nonce marker, asks `seat-locate` where it appears,
// and matches that slot against this table to find EXACTLY the session that
// lived there. The table persists across daemon restarts.

let seatingPath = NSString(string: "~/.claude-profiles/seating.json").expandingTildeInPath
var seatingMap: [String: [String: Int]] = [:]

func decodeTtyMarker(_ text: String) -> Int? {
    // last occurrence of U+2060 [12 x U+200B/U+200C, MSB first] U+2060
    let s = Array(text.unicodeScalars)
    var i = s.count - 1
    while i >= 13 {
        if s[i].value == 0x2060 && s[i - 13].value == 0x2060 {
            var n = 0, ok = true
            for k in 1...12 {
                switch s[i - 13 + k].value {
                case 0x200C: n = (n << 1) | 1
                case 0x200B: n = n << 1
                default: ok = false
                }
                if !ok { break }
            }
            if ok { return n }
        }
        i -= 1
    }
    return nil
}

func windowFrame(_ w: AXUIElement) -> (Int, Int, Int, Int)? {
    var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posVal = posRef, let sizeVal = sizeRef,
          CFGetTypeID(posVal) == AXValueGetTypeID(), CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero; var sz = CGSize.zero
    AXValueGetValue(posVal as! AXValue, .cgPoint, &p)
    AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz)
    return (Int(p.x), Int(p.y), Int(sz.width), Int(sz.height))
}

// Visit every split leaf (AXTextArea) with its L/R nesting path.
func walkSplits(_ el: AXUIElement, _ path: String, _ visit: (String, String) -> Void) {
    var roleRef: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
    if (roleRef as? String) == "AXTextArea" {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success,
           let t = v as? String { visit(path, t) }
        return
    }
    var descRef: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef)
    var seg = ""
    switch descRef as? String {
    case "Left pane": seg = "L"
    case "Right pane": seg = "R"
    default: break
    }
    var chRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef) == .success,
          let ch = chRef as? [AXUIElement] else { return }
    for c in ch { walkSplits(c, seg.isEmpty ? path : path + "." + seg, visit) }
}

func seatSample() {
    // Ghostty strips zero-width characters from AX *text* (verified: on-screen
    // markers read back as zw=0) but preserves them in window TITLES. A window
    // title shows only its FOCUSED split's title, so two passes:
    //  1. every window's title -> its marker's slot. Single-split windows are
    //     recorded continuously regardless of app focus; multi-split windows
    //     record whichever split is currently focused within them.
    //  2. the app's focused element -> its exact L/R split path, refining the
    //     one currently-focused pane's slot.
    guard AXIsProcessTrusted(),
          let running = NSRunningApplication.runningApplications(withBundleIdentifier: focusTarget).first else { return }
    let ax = AXUIElementCreateApplication(running.processIdentifier)
    let now = Int(Date().timeIntervalSince1970)
    var dirty = false

    var winsRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &winsRef) == .success,
       let windows = winsRef as? [AXUIElement] {
        for w in windows {
            var tRef: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &tRef)
            guard let title = tRef as? String, let n = decodeTtyMarker(title),
                  let f = windowFrame(w) else { continue }
            // Pass 1 can't know the split path (title is path-agnostic); keep any
            // path already learned for this tty, else default to 0 (whole window).
            let key = "\(running.processIdentifier):\(n)"
            let prevPath = seatingMap[key]?["p"] ?? 0
            seatingMap[key] = ["x": f.0, "y": f.1, "w": f.2, "h": f.3, "seen": now, "p": prevPath]
            dirty = true
        }
    }

    var focRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &focRef) == .success,
       let fv = focRef, CFGetTypeID(fv) == AXUIElementGetTypeID() {
        var el = fv as! AXUIElement
        var path = ""
        var win: AXUIElement? = nil
        for _ in 0..<12 {
            var roleRef: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXWindow" { win = el; break }
            var descRef: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef)
            switch descRef as? String {
            case "Left pane": path = path.isEmpty ? "L" : "L." + path
            case "Right pane": path = path.isEmpty ? "R" : "R." + path
            default: break
            }
            var parRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parRef) == .success,
                  let pv = parRef, CFGetTypeID(pv) == AXUIElementGetTypeID() else { break }
            el = pv as! AXUIElement
        }
        if let w = win, let f = windowFrame(w) {
            var tRef: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &tRef)
            if let title = tRef as? String, let n = decodeTtyMarker(title) {
                seatingMap["\(running.processIdentifier):\(n)"] = ["x": f.0, "y": f.1, "w": f.2, "h": f.3, "seen": now, "p": pathCode(path)]
                dirty = true
            }
        }
    }

    if dirty, let data = try? JSONSerialization.data(withJSONObject: seatingMap) {
        try? data.write(to: URL(fileURLWithPath: seatingPath))
    }
}

// Paths are short strings like "R.L.R" — encode as an int so the map stays
// [String: Int]-typed (L=1, R=2, base-3 digits).
func pathCode(_ path: String) -> Int {
    var n = 0
    for c in path where c == "L" || c == "R" { n = n * 3 + (c == "L" ? 1 : 2) }
    return n
}

if let data = try? Data(contentsOf: URL(fileURLWithPath: seatingPath)),
   let saved = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Int]] {
    // epoch-keyed entries only ("<terminal-pid>:<tty>"); legacy plain-tty
    // keys predate epochs and cannot be trusted across relaunches.
    seatingMap = saved.filter { $0.key.contains(":") }
}
let seatTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
seatTimer.schedule(deadline: .now() + 10, repeating: 20)
seatTimer.setEventHandler { seatSample() }
seatTimer.resume()

let delegate = Delegate()
center.delegate = delegate

// One-time system permission prompt (state is per bundle id; notDetermined
// only on the very first launch). On current macOS the prompt itself arrives
// AS a notification — click it and Allow. Style must be set to Alerts by the
// user in System Settings; that part is not programmable.
center.requestAuthorization(options: [.alert, .sound]) { granted, error in
    log("authorization granted=\(granted)" + (error.map { " error=\($0)" } ?? ""))
}

// MARK: - Notification operations
// All requests run on one serial queue; modern-API async calls are bridged
// with semaphores (their completions fire on the framework's own queue, so
// waiting here cannot deadlock).

let ops = DispatchQueue(label: "agent-notify.ops")

func delivered() -> [UNNotification] {
    var result: [UNNotification] = []
    let sem = DispatchSemaphore(value: 0)
    center.getDeliveredNotifications { list in
        result = list
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 5)
    return result
}

func removeGroup(_ group: String) -> Int {
    let matching = delivered().filter {
        $0.request.identifier == group ||
        $0.request.content.userInfo["groupID"] as? String == group
    }
    // Identifier addressing is server-side and works even for records this
    // process never delivered (a predecessor daemon's banners).
    center.removeDeliveredNotifications(withIdentifiers: [group] + matching.map { $0.request.identifier })
    return matching.count
}

func removeTitle(_ title: String) -> Int {
    let ids = delivered().filter { $0.request.content.title == title }
        .map { $0.request.identifier }
    center.removeDeliveredNotifications(withIdentifiers: ids)
    return ids.count
}

func post(group: String, title: String, message: String, replaceSameTitle: Bool, focusHint: String?) {
    // replace_same_title serves renamed-but-regrouped sessions (Claude Code's
    // /clear keeps a chat's name but changes its history anchor): the newer
    // banner replaces any same-titled older one. Clients set it only for
    // explicitly named chats; unnamed chats share bare repo titles and must
    // keep strict per-group isolation.
    if replaceSameTitle {
        let stale = delivered().filter {
            $0.request.content.title == title && $0.request.identifier != group
        }.map { $0.request.identifier }
        center.removeDeliveredNotifications(withIdentifiers: stale)
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = message
    var info: [String: Any] = ["groupID": group]
    // Optional invisible window marker (see raiseWindow) — rides along so a
    // click can find the exact window even when visible titles are ambiguous.
    if let focusHint, !focusHint.isEmpty { info["focusHint"] = focusHint }
    content.userInfo = info
    // Fixed identifier per session: adding with an existing identifier
    // replaces the previous banner in place, atomically.
    let request = UNNotificationRequest(identifier: group, content: content, trigger: nil)
    let sem = DispatchSemaphore(value: 0)
    center.add(request) { error in
        if let error { log("add failed: \(error)") }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 5)
}

let deliveredAtFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return f
}()

func listAll() -> [[String: String]] {
    return delivered().map { n in
        [
            "group": n.request.identifier,
            "title": n.request.content.title,
            "message": n.request.content.body,
            "deliveredAt": deliveredAtFormat.string(from: n.date),
        ]
    }
}

func handle(_ request: [String: Any]) -> [String: Any] {
    switch request["cmd"] as? String {
    case "post":
        guard let group = request["group"] as? String,
              let title = request["title"] as? String,
              let message = request["message"] as? String else {
            return ["ok": false, "error": "post needs group/title/message"]
        }
        post(group: group, title: title, message: message,
             replaceSameTitle: request["replace_same_title"] as? Bool ?? false,
             focusHint: request["focus_hint"] as? String)
        return ["ok": true]
    case "remove":
        guard let group = request["group"] as? String else {
            return ["ok": false, "error": "remove needs group"]
        }
        return ["ok": true, "removed": removeGroup(group)]
    case "remove-title":
        guard let title = request["title"] as? String else {
            return ["ok": false, "error": "remove-title needs title"]
        }
        return ["ok": true, "removed": removeTitle(title)]
    case "list":
        return ["ok": true, "notifications": listAll()]
    case "windows":
        // Diagnostic: the focus target's window titles as AX sees them
        // (current Space only — that's the API's limit, not ours).
        guard let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: focusTarget).first else {
            return ["ok": false, "error": "focus target not running"]
        }
        guard AXIsProcessTrusted() else {
            return ["ok": false, "error": "accessibility not granted"]
        }
        let ax = AXUIElementCreateApplication(running.processIdentifier)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let windows = winsRef as? [AXUIElement] else {
            return ["ok": false, "error": "ax window enumeration failed"]
        }
        let titles = windows.map { window -> String in
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            return (titleRef as? String) ?? "<untitled>"
        }
        return ["ok": true, "windows": titles]
    case "seat-debug":
        // Step-by-step trace of exactly what the sampler sees.
        guard AXIsProcessTrusted(),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: focusTarget).first else {
            return ["ok": false, "error": "no accessibility or target"]
        }
        let dax = AXUIElementCreateApplication(running.processIdentifier)
        var out: [String] = ["appActive=\(running.isActive)"]
        var focRef: CFTypeRef?
        let ferr = AXUIElementCopyAttributeValue(dax, kAXFocusedUIElementAttribute as CFString, &focRef)
        out.append("focusedElement err=\(ferr.rawValue)")
        if ferr == .success, let fv = focRef, CFGetTypeID(fv) == AXUIElementGetTypeID() {
            var el = fv as! AXUIElement
            var path = ""
            for hop in 0..<12 {
                var roleRef: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
                let role = (roleRef as? String) ?? "?"
                var descRef: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef)
                let desc = (descRef as? String) ?? ""
                out.append("hop\(hop): \(role) '\(desc)'")
                if role == "AXWindow" {
                    var tRef: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &tRef)
                    let title = (tRef as? String) ?? ""
                    let zw = title.unicodeScalars.filter { [0x200b, 0x200c, 0x2060].contains($0.value) }.count
                    out.append("windowTitle zw=\(zw) decoded=\(decodeTtyMarker(title).map(String.init) ?? "nil") path=\(path)")
                    break
                }
                switch desc {
                case "Left pane": path = path.isEmpty ? "L" : "L." + path
                case "Right pane": path = path.isEmpty ? "R" : "R." + path
                default: break
                }
                var parRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parRef) == .success,
                      let pv = parRef, CFGetTypeID(pv) == AXUIElementGetTypeID() else {
                    out.append("parent dead-end at hop \(hop)")
                    break
                }
                el = pv as! AXUIElement
            }
        }
        return ["ok": true, "debug": out]
    case "seat-locate":
        // Find which split currently displays the zero-width marker for the
        // given tty number (the restoring pane just printed it as a nonce).
        guard let n = request["tty"] as? Int else {
            return ["ok": false, "error": "seat-locate needs tty"]
        }
        guard AXIsProcessTrusted(),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: focusTarget).first else {
            return ["ok": false, "error": "no accessibility or target"]
        }
        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        var wRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wRef) == .success,
              let wins = wRef as? [AXUIElement] else {
            return ["ok": false, "error": "no windows"]
        }
        var found: [String: Any]? = nil
        for w in wins {
            guard let f = windowFrame(w) else { continue }
            walkSplits(w, "") { path, text in
                guard found == nil else { return }
                // A freshly restored shell VISIBLY prints its tty in the
                // login banner ("Last login: ... on ttysNNN") — zero-width
                // nonces don't survive into AX text, but this does.
                var search = text[text.startIndex...]
                while let r = search.range(of: "ttys") {
                    let digits = search[r.upperBound...].prefix(while: { $0.isNumber })
                    if let m = Int(digits), m == n {
                        found = ["ok": true, "x": f.0, "y": f.1, "w": f.2, "h": f.3, "p": pathCode(path)]
                        return
                    }
                    search = search[r.upperBound...]
                }
            }
            if found != nil { break }
        }
        return found ?? ["ok": false, "error": "tty not visible in any pane"]
    case "axtree":
        // Diagnostic: dump the focus target's AX hierarchy (roles + titles),
        // to establish what per-split/per-tab structure is actually exposed.
        guard let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: focusTarget).first else {
            return ["ok": false, "error": "focus target not running"]
        }
        guard AXIsProcessTrusted() else {
            return ["ok": false, "error": "accessibility not granted"]
        }
        var lines: [String] = []
        func dump(_ el: AXUIElement, _ depth: Int) {
            guard depth <= 9, lines.count < 500 else { return }
            var r: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
            var t: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &t)
            var d: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &d)
            let role = (r as? String) ?? "?"
            let title = (t as? String) ?? ""
            let desc = (d as? String) ?? ""
            // For text-bearing elements, report how much of the screen text is
            // readable and a short head sample — the load-bearing question for
            // nonce-based pane identification.
            var extra = ""
            if role == "AXTextArea" || role == "AXStaticText" {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success,
                   let text = v as? String {
                    let zw = text.unicodeScalars.filter { [0x200b, 0x200c, 0x2060].contains($0.value) }.count
                    let marker = decodeTtyMarker(text).map { " marker=\($0)" } ?? ""
                    extra = " value=\(text.count)ch zw=\(zw)\(marker) '\(String(text.prefix(30)).replacingOccurrences(of: "\n", with: "\\n"))'"
                } else {
                    extra = " value=unreadable"
                }
            }
            lines.append(String(repeating: "  ", count: depth) + role
                         + (title.isEmpty ? "" : " title='\(title)'")
                         + (desc.isEmpty ? "" : " desc='\(desc)'")
                         + extra)
            var c: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &c) == .success,
               let children = c as? [AXUIElement] {
                for child in children { dump(child, depth + 1) }
            }
        }
        let ax = AXUIElementCreateApplication(running.processIdentifier)
        var winsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &winsRef) == .success,
           let windows = winsRef as? [AXUIElement] {
            for (i, w) in windows.enumerated() {
                lines.append("WINDOW \(i)")
                dump(w, 1)
            }
        }
        return ["ok": true, "tree": lines]
    default:
        return ["ok": false, "error": "unknown cmd"]
    }
}

// MARK: - Unix socket server

// Refuse to unlink anything that isn't a socket — protects against a
// mistyped path in the LaunchAgent deleting a real file.
var existing = stat()
if stat(socketPath, &existing) == 0 && (existing.st_mode & S_IFMT) != S_IFSOCK {
    FileHandle.standardError.write("refusing to replace non-socket at \(socketPath)\n".data(using: .utf8)!)
    exit(1)
}
unlink(socketPath)
let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard serverFD >= 0 else { perror("socket"); exit(1) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: socketPath.utf8.prefix(raw.count - 1))
}
let bindResult = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bindResult == 0 else { perror("bind"); exit(1) }
// The socket is the write path for banners — keep it private to this user.
chmod(socketPath, 0o600)
guard listen(serverFD, 16) == 0 else { perror("listen"); exit(1) }

DispatchQueue.global().async {
    while true {
        let clientFD = accept(serverFD, nil, nil)
        guard clientFD >= 0 else { continue }
        DispatchQueue.global().async {
            defer { close(clientFD) }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            // 1 MB cap: a well-formed request is <4 KB; anything larger is
            // not a client we want to serve.
            while !data.contains(0x0A) && data.count < 1_048_576 {
                let n = read(clientFD, &buf, buf.count)
                guard n > 0 else { break }
                data.append(contentsOf: buf[0..<n])
            }
            guard let lineEnd = data.firstIndex(of: 0x0A) else { return }
            let reply: [String: Any]
            if let request = try? JSONSerialization.jsonObject(with: data[..<lineEnd]) as? [String: Any] {
                reply = ops.sync { handle(request) }
            } else {
                reply = ["ok": false, "error": "bad json"]
            }
            if var out = try? JSONSerialization.data(withJSONObject: reply) {
                out.append(0x0A)
                out.withUnsafeBytes { _ = write(clientFD, $0.baseAddress, $0.count) }
            }
        }
    }
}

// Full AppKit event machinery (not a bare RunLoop): notification click
// responses are routed by the system through app activation, and an
// NSApplication-less process can miss them. Policy .accessory (not
// .prohibited): a prohibited app cannot be activated at all, so it can never
// hold the activation a banner click grants — and its focus hand-off to the
// terminal is silently ignored.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
