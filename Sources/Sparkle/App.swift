import AppKit
import ApplicationServices
import Darwin
import SQLite3
import UserNotifications

@main
struct SparkleApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private lazy var integrations: [AssistantIntegration] = [ChatGPTIntegration(), ClaudeIntegration()]
    private let defaults = UserDefaults.standard
    private var stateItem: NSMenuItem!
    private var notificationsItem: NSMenuItem!
    private var soundItem: NSMenuItem!
    private var pendingProvider: AssistantProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureDefaults()
        configureMenuBar()
        configureNotifications()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceAppActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        for integration in integrations {
            integration.onEvent = { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            integration.start()
        }
    }

    private func configureDefaults() {
        defaults.register(defaults: [
            "notificationsEnabled": true,
            "soundEnabled": true
        ])
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.removeAllDeliveredNotifications()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("Notification permission error: \(error)") }
            if !granted { NSLog("Sparkle notifications are disabled") }
        }
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MascotIcon.image(for: .idle)
        statusItem.button?.toolTip = "Sparkle — watching ChatGPT and Claude"

        let menu = NSMenu()
        menu.delegate = self
        stateItem = NSMenuItem(title: "Watching ChatGPT and Claude", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())

        notificationsItem = NSMenuItem(title: "Notifications", action: #selector(toggleNotifications), keyEquivalent: "")
        notificationsItem.target = self
        notificationsItem.state = defaults.bool(forKey: "notificationsEnabled") ? .on : .off
        menu.addItem(notificationsItem)

        soundItem = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = defaults.bool(forKey: "soundEnabled") ? .on : .off
        menu.addItem(soundItem)

        let access = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(requestAccessibility), keyEquivalent: "")
        access.target = self
        menu.addItem(access)

        let test = NSMenuItem(title: "Send Test Alert", action: #selector(sendTestAlert), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        let playSound = NSMenuItem(title: "Play Sound", action: #selector(playTestSound), keyEquivalent: "")
        playSound.target = self
        menu.addItem(playSound)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open ChatGPT", action: #selector(openChatGPT), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let openClaude = NSMenuItem(title: "Open Claude", action: #selector(openClaude), keyEquivalent: "")
        openClaude.target = self
        menu.addItem(openClaude)

        let quit = NSMenuItem(title: "Quit Sparkle", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func handle(_ event: IntegrationEvent) {
        let state: ChatState
        let provider: AssistantProvider
        let notificationTitle: String
        let notificationBody: String

        switch event {
        case .needsAttention(let eventProvider, let taskTitle, let reason):
            provider = eventProvider
            state = .needsAttention(reason, taskTitle)
            notificationTitle = "\(provider.rawValue) needs you"
            notificationBody = taskTitle.map { "“\($0)” needs your attention. \(reason)" } ?? reason
        case .completed(let eventProvider, let taskTitle):
            provider = eventProvider
            state = .completed(taskTitle)
            notificationTitle = "\(provider.rawValue) replied"
            notificationBody = taskTitle.map { "“\($0)” is ready." } ?? "Your response is ready."
        }

        pendingProvider = provider
        statusItem.button?.image = MascotIcon.image(for: state)
        statusItem.button?.toolTip = "Sparkle — \(provider.rawValue) needs attention"
        stateItem.title = "\(provider.rawValue) needs attention"
        sendNotification(title: notificationTitle, body: notificationBody, provider: provider)
    }

    private func sendNotification(title: String, body: String, provider: AssistantProvider? = nil) {
        guard defaults.bool(forKey: "notificationsEnabled") else { return }
        playAlertSound()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = "ASSISTANT_ATTENTION"
        if let provider { content.userInfo = ["provider": provider.rawValue] }
        // Sparkle plays the sound itself. This remains audible when macOS is
        // configured to show notification banners silently and avoids two sounds.
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func playAlertSound() {
        guard defaults.bool(forKey: "soundEnabled") else { return }
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.stop()
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let providerName = response.notification.request.content.userInfo["provider"] as? String
        Task { @MainActor in
            providerName == AssistantProvider.claude.rawValue ? self.openClaude() : self.openChatGPT()
        }
        completionHandler()
    }

    func menuWillOpen(_ menu: NSMenu) {
        acknowledge()
    }

    @objc private func workspaceAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              integrations.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
        acknowledge()
    }

    @objc private func toggleNotifications() {
        let enabled = !defaults.bool(forKey: "notificationsEnabled")
        defaults.set(enabled, forKey: "notificationsEnabled")
        notificationsItem.state = enabled ? .on : .off
        if enabled { configureNotifications() }
    }

    @objc private func toggleSound() {
        let enabled = !defaults.bool(forKey: "soundEnabled")
        defaults.set(enabled, forKey: "soundEnabled")
        soundItem.state = enabled ? .on : .off
    }

    @objc private func requestAccessibility() {
        // Use the documented key value directly to avoid Swift 6 treating the
        // imported Core Foundation global as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func sendTestAlert() {
        sendNotification(title: "Sparkle is awake ✨", body: "I’ll let you know when ChatGPT needs you.")
    }

    @objc private func playTestSound() { playAlertSound() }

    @objc private func openChatGPT() {
        acknowledge()
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/ChatGPT.app"), configuration: configuration)
    }

    @objc private func openClaude() {
        acknowledge()
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Claude.app"), configuration: configuration)
    }

    private func acknowledge() {
        pendingProvider = nil
        statusItem.button?.image = MascotIcon.image(for: .idle)
        statusItem.button?.toolTip = "Sparkle — watching ChatGPT and Claude"
        stateItem.title = "Watching ChatGPT and Claude"
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

enum ChatState: Equatable {
    case notRunning
    case accessibilityNeeded
    case idle
    case working
    case needsAttention(String, String?)
    case completed(String?)

    var menuTitle: String {
        switch self {
        case .notRunning: "ChatGPT isn’t running"
        case .accessibilityNeeded: "Accessibility access needed"
        case .idle: "Watching for ChatGPT"
        case .working: "ChatGPT is working…"
        case .needsAttention: "ChatGPT needs you!"
        case .completed: "ChatGPT replied"
        }
    }

    var tooltip: String { "Sparkle — \(menuTitle)" }
}

final class ChatGPTIntegration: AssistantIntegration, @unchecked Sendable {
    let provider = AssistantProvider.chatGPT
    let bundleIdentifier = "com.openai.codex"
    var onEvent: (@Sendable (IntegrationEvent) -> Void)?

    private let queue = DispatchQueue(label: "app.sparkle.monitor", qos: .utility)
    private var fileSources: [URL: DispatchSourceFileSystemObject] = [:]
    private var directorySources: [URL: DispatchSourceFileSystemObject] = [:]
    private var sessionOffsets: [URL: UInt64] = [:]
    private var sessionRemainders: [URL: Data] = [:]

    func start() {
        debugLog("monitor starting; home=\(FileManager.default.homeDirectoryForCurrentUser.path)")
        raiseFileDescriptorLimit()
        discoverSessionFiles(initial: true)
    }

    func stop() {
        queue.async { [weak self] in
            self?.fileSources.values.forEach { $0.cancel() }
            self?.directorySources.values.forEach { $0.cancel() }
            self?.fileSources.removeAll()
            self?.directorySources.removeAll()
        }
    }

    private func emit(_ event: IntegrationEvent) {
        onEvent?(event)
    }

    private func raiseFileDescriptorLimit() {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return }
        limits.rlim_cur = min(limits.rlim_max, 2_048)
        _ = setrlimit(RLIMIT_NOFILE, &limits)
        debugLog("file descriptor limit=\(limits.rlim_cur)")
    }

    private func discoverSessionFiles(initial: Bool) {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        watchDirectory(root)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            debugLog("could not enumerate \(root.path)")
            return
        }

        var discovered = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                watchDirectory(url)
            } else if url.pathExtension == "jsonl", sessionOffsets[url] == nil {
                let size = freshFileSize(url)
                // Existing logs start at EOF so launching Sparkle never
                // replays old replies. New tasks are read from their beginning.
                sessionOffsets[url] = initial ? size : 0
                watchSessionFile(url)
                discovered += 1
            }
        }
        if discovered > 0 { debugLog("discovered \(discovered) session files; initial=\(initial)") }
    }

    private func watchSessionFile(_ url: URL) {
        guard fileSources[url] == nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            debugLog("failed to watch session file: \(url.lastPathComponent)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            self.readAppendedData(from: url)
            if let data = source?.data, data.contains(.delete) || data.contains(.rename) {
                source?.cancel()
                self.fileSources[url] = nil
                self.sessionOffsets[url] = nil
                self.sessionRemainders[url] = nil
            }
        }
        source.setCancelHandler { close(descriptor) }
        fileSources[url] = source
        source.resume()
    }

    private func watchDirectory(_ url: URL) {
        guard directorySources[url] == nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            if let data = source?.data, data.contains(.delete) || data.contains(.rename) {
                source?.cancel()
                self.directorySources[url] = nil
            }
            self.discoverSessionFiles(initial: false)
        }
        source.setCancelHandler { close(descriptor) }
        directorySources[url] = source
        source.resume()
    }

    private func readAppendedData(from url: URL) {
        let previousOffset = sessionOffsets[url] ?? 0
        let size = freshFileSize(url)
        guard size != previousOffset else { return }

        let offset = size < previousOffset ? 0 : previousOffset
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let appended = try handle.readToEnd() ?? Data()
            sessionOffsets[url] = size
            debugLog("read \(appended.count) bytes from \(url.lastPathComponent) at \(offset)")
            consumeSessionData(appended, from: url)
        } catch { }
    }

    private func freshFileSize(_ url: URL) -> UInt64 {
        // URLResourceValues can retain stale metadata for append-only files.
        // attributesOfItem performs a fresh stat, which is essential here.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }

    private func consumeSessionData(_ appended: Data, from url: URL) {
        var data = sessionRemainders[url] ?? Data()
        data.append(appended)
        let newline = UInt8(ascii: "\n")
        var lines = data.split(separator: newline, omittingEmptySubsequences: true)

        if data.last != newline, let remainder = lines.popLast() {
            sessionRemainders[url] = Data(remainder)
        } else {
            sessionRemainders[url] = nil
        }

        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let recordType = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else { continue }

            if recordType == "response_item",
               payloadType == "message",
               payload["role"] as? String == "assistant",
               payload["phase"] as? String == "final_answer" {
                debugLog("saw final_answer in \(url.lastPathComponent)")
                emit(.completed(provider: provider, title: taskTitle(for: url)))
            } else if recordType == "response_item",
                      payloadType == "custom_tool_call",
                      payload["name"] as? String == "request_user_input" {
                emit(.needsAttention(
                    provider: provider,
                    title: taskTitle(for: url),
                    reason: "An approval, question, or action is waiting."
                ))
            } else if recordType == "event_msg",
                      (payloadType.lowercased().contains("approval") ||
                       payloadType.lowercased().contains("elicitation")) {
                emit(.needsAttention(
                    provider: provider,
                    title: taskTitle(for: url),
                    reason: "An approval, question, or action is waiting."
                ))
            }
        }
    }

    private func taskTitle(for sessionURL: URL) -> String? {
        let basename = sessionURL.deletingPathExtension().lastPathComponent
        guard basename.count >= 36 else { return nil }
        let threadID = String(basename.suffix(36))
        guard UUID(uuidString: threadID) != nil else { return nil }

        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sqlite/codex-dev.db")
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return nil }
        defer { sqlite3_close(database) }

        let sql = "SELECT display_title FROM local_thread_catalog WHERE thread_id = ? ORDER BY source_updated_at DESC LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, threadID, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let title = sqlite3_column_text(statement, 0) else { return nil }
        let value = String(cString: title).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func debugLog(_ message: String) {
        let url = URL(fileURLWithPath: "/tmp/Sparkle-debug.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let data = Data(line.utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch { }
        }
    }
}

enum AccessibilitySnapshot {
    struct Snapshot {
        var strings: [String]
        var interactiveLabels: [String]
    }

    static func capture(from root: AXUIElement, limit: Int) -> Snapshot {
        var result: [String] = []
        var interactiveLabels: [String] = []
        var stack: [AXUIElement] = [root]
        var visited = 0

        while let element = stack.popLast(), visited < limit {
            visited += 1
            var roleValue: CFTypeRef?
            var enabledValue: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
            AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue)
            let role = roleValue as? String
            let enabled = (enabledValue as? Bool) ?? true
            let isInteractive = enabled && [
                kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
                kAXPopUpButtonRole, kAXMenuItemRole
            ].contains(where: { role == $0 as String })

            for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let text = value as? String, !text.isEmpty {
                    result.append(text)
                    if isInteractive { interactiveLabels.append(text) }
                }
            }

            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
        return Snapshot(strings: result, interactiveLabels: interactiveLabels)
    }

    static func context(around needle: String, in text: String) -> String {
        guard let range = text.range(of: needle) else { return "" }
        let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

}

enum MascotIcon {
    static func image(for state: ChatState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let color: NSColor = switch state {
            case .needsAttention, .completed: .systemPink
            case .notRunning: .tertiaryLabelColor
            case .idle, .working, .accessibilityNeeded: .labelColor
            }

            color.setStroke()
            let bubble = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3.5, width: 15, height: 12), xRadius: 5, yRadius: 5)
            bubble.lineWidth = 1.7
            bubble.stroke()

            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 5.5, y: 4.2))
            tail.line(to: NSPoint(x: 4.0, y: 1.8))
            tail.line(to: NSPoint(x: 8.0, y: 4.0))
            tail.lineWidth = 1.5
            tail.lineJoinStyle = .round
            tail.stroke()

            color.setFill()
            for x in [6.2, 11.8] {
                NSBezierPath(ovalIn: NSRect(x: x - 1, y: 9.3, width: 2, height: 2)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
