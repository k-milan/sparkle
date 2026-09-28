import Darwin
import Foundation

final class ClaudeIntegration: AssistantIntegration, @unchecked Sendable {
    let provider = AssistantProvider.claude
    let bundleIdentifier = "com.anthropic.claudefordesktop"
    var onEvent: (@Sendable (IntegrationEvent) -> Void)?

    private let queue = DispatchQueue(label: "app.sparkle.claude-monitor", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var remainder = Data()

    private var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Claude/main.log")
    }

    private var sessionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    func start() {
        queue.async { [weak self] in self?.beginWatching() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
    }

    private func beginWatching() {
        guard source == nil else { return }
        offset = fileSize(logURL)
        let descriptor = open(logURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            debugLog("Claude log is not available at \(logURL.path)")
            return
        }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        newSource.setEventHandler { [weak self, weak newSource] in
            guard let self else { return }
            self.readAppendedLog()
            if let events = newSource?.data,
               events.contains(.delete) || events.contains(.rename) {
                newSource?.cancel()
                self.source = nil
            }
        }
        newSource.setCancelHandler { close(descriptor) }
        source = newSource
        newSource.resume()
        debugLog("watching Claude log from offset \(offset)")
    }

    private func readAppendedLog() {
        let size = fileSize(logURL)
        guard size != offset else { return }
        let readOffset = size < offset ? 0 : offset
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: readOffset)
            let data = try handle.readToEnd() ?? Data()
            offset = size
            consume(data)
        } catch {
            debugLog("could not read Claude log: \(error.localizedDescription)")
        }
    }

    private func consume(_ appended: Data) {
        remainder.append(appended)
        let newline = UInt8(ascii: "\n")
        var lines = remainder.split(separator: newline, omittingEmptySubsequences: true)
        if remainder.last != newline, let partial = lines.popLast() {
            remainder = Data(partial)
        } else {
            remainder.removeAll(keepingCapacity: true)
        }

        for bytes in lines {
            parse(String(decoding: bytes, as: UTF8.self))
        }
    }

    private func parse(_ line: String) {
        let completionMarker = "[Stop hook] Query completed for session "
        if let range = line.range(of: completionMarker) {
            let sessionID = token(after: range.upperBound, in: line)
            debugLog("saw completion for \(sessionID)")
            onEvent?(.completed(provider: provider, title: taskTitle(for: sessionID)))
            return
        }

        let permissionMarker = "Emitted tool permission request "
        let sessionMarker = " in session "
        if line.contains(permissionMarker), let range = line.range(of: sessionMarker) {
            let sessionID = token(after: range.upperBound, in: line)
            debugLog("saw attention request for \(sessionID)")
            onEvent?(.needsAttention(
                provider: provider,
                title: taskTitle(for: sessionID),
                reason: "A question, permission, or action is waiting."
            ))
        }
    }

    private func token(after index: String.Index, in line: String) -> String {
        String(line[index...].prefix { !$0.isWhitespace })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func taskTitle(for sessionID: String) -> String? {
        guard !sessionID.isEmpty,
              let enumerator = FileManager.default.enumerator(
                at: sessionsURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }

        let filename = "\(sessionID).json"
        for case let url as URL in enumerator where url.lastPathComponent == filename {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = object["title"] as? String else { return nil }
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func fileSize(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }

    private func debugLog(_ message: String) {
        let url = URL(fileURLWithPath: "/tmp/Sparkle-Claude-debug.log")
        let data = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
