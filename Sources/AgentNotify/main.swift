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
//   {"cmd":"post","group":G,"title":T,"message":M,"replace_same_title":B} -> {"ok":true}
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

final class Delegate: NSObject, UNUserNotificationCenterDelegate {
    // Present even if this (background) app were ever considered frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    // Body click: macOS already dismisses the clicked banner; we add the
    // second half of the gesture — bring the terminal forward. Scoped to the
    // clicked identifier only; no other banner is touched.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let id = response.notification.request.identifier
            center.removeDeliveredNotifications(withIdentifiers: [id])
            DispatchQueue.main.async {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: focusTarget) {
                    NSWorkspace.shared.openApplication(at: url,
                                                       configuration: NSWorkspace.OpenConfiguration())
                }
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

func post(group: String, title: String, message: String, replaceSameTitle: Bool) {
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
    content.userInfo = ["groupID": group]
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
             replaceSameTitle: request["replace_same_title"] as? Bool ?? false)
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
// NSApplication-less process can miss them.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
