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
                    extra = " value=\(text.count)ch zw=\(zw) '\(String(text.prefix(30)).replacingOccurrences(of: "\n", with: "\\n"))'"
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
