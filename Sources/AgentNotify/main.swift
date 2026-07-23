// agent-notify — a single supervisor daemon for macOS CLI notifications.
//
// Why this exists: tools like alerter/terminal-notifier spawn one process per
// banner, all impersonating the same app bundle. Those processes share one
// delivered-notification list and one delegate slot inside macOS's
// notification daemon; when any of them exits while its banner is still
// registered, usernoted's connection cleanup sometimes sweeps SIBLING banners
// too (races observed as: clicking one notification dismisses several,
// killing one process wipes the whole stack). One long-lived process owning
// ALL banners through one connection removes that race by construction.
// Full diagnosis in the README.
//
// Protocol: newline-delimited JSON over a unix stream socket.
//   {"cmd":"post","group":G,"title":T,"message":M}  -> {"ok":true}
//   {"cmd":"remove","group":G}                      -> {"ok":true,"removed":N}
//   {"cmd":"list"}                                  -> {"ok":true,"notifications":[...]}
// Unknown command or bad JSON -> {"ok":false,"error":"..."}
//
// The daemon never removes banners on its own exit: delivered notifications
// belong to the (spoofed) bundle, so a restarted daemon manages banners
// posted by its predecessor.

import AppKit
import BundleHook

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: agent-notify <sender-bundle-id> <socket-path>\n".data(using: .utf8)!)
    exit(2)
}
let sender = args[1]
let socketPath = args[2]

_ = InstallFakeBundleIdentifierHook(sender)

final class Delegate: NSObject, NSUserNotificationCenterDelegate {
    // Show banners even while the impersonated app (Cursor) is frontmost.
    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    // Click routing lands HERE (the daemon holds the identity's connection),
    // so body/button clicks must be handled explicitly: dismiss exactly the
    // clicked banner and bring the real app forward. Scoped by identifier —
    // no other banner is touched.
    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                didActivate notification: NSUserNotification) {
        if let id = notification.identifier {
            for n in center.deliveredNotifications where n.identifier == id {
                center.removeDeliveredNotification(n)
            }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sender) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

let delegate = Delegate()
let center = NSUserNotificationCenter.default
center.delegate = delegate

// MARK: - Notification operations (main thread only)

func removeGroup(_ group: String) -> Int {
    var removed = 0
    for n in center.deliveredNotifications
    where n.userInfo?["groupID"] as? String == group {
        center.removeDeliveredNotification(n)
        removed += 1
    }
    return removed
}

func post(group: String, title: String, message: String) {
    _ = removeGroup(group)
    let n = NSUserNotification()
    n.title = title
    n.informativeText = message
    let uuid = UUID().uuidString
    n.identifier = uuid
    n.userInfo = ["groupID": group, "uuid": uuid]
    center.deliver(n)
}

func listAll() -> [[String: String]] {
    return center.deliveredNotifications.map { n in
        [
            "group": n.userInfo?["groupID"] as? String ?? "",
            "title": n.title ?? "",
            "message": n.informativeText ?? "",
            "deliveredAt": n.actualDeliveryDate.map { "\($0)" } ?? "",
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
        post(group: group, title: title, message: message)
        return ["ok": true]
    case "remove":
        guard let group = request["group"] as? String else {
            return ["ok": false, "error": "remove needs group"]
        }
        return ["ok": true, "removed": removeGroup(group)]
    case "list":
        return ["ok": true, "notifications": listAll()]
    default:
        return ["ok": false, "error": "unknown cmd"]
    }
}

// MARK: - Unix socket server

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
guard listen(serverFD, 16) == 0 else { perror("listen"); exit(1) }

DispatchQueue.global().async {
    while true {
        let clientFD = accept(serverFD, nil, nil)
        guard clientFD >= 0 else { continue }
        DispatchQueue.global().async {
            defer { close(clientFD) }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while !data.contains(0x0A) {
                let n = read(clientFD, &buf, buf.count)
                guard n > 0 else { break }
                data.append(contentsOf: buf[0..<n])
            }
            guard let lineEnd = data.firstIndex(of: 0x0A) else { return }
            let reply: [String: Any]
            if let request = try? JSONSerialization.jsonObject(with: data[..<lineEnd]) as? [String: Any] {
                reply = DispatchQueue.main.sync { handle(request) }
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

RunLoop.main.run()
