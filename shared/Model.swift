// Shared between the widget extension and the background helper.

import Foundation
import SwiftUI

struct SourceStatus: Codable, Equatable {
    let ok: Bool
    let error: String?
    let count: Int
}

struct TaskItem: Codable, Equatable, Identifiable {
    let source: String
    let id: String
    let title: String
    let description: String?
    let schedule: String
    let enabled: Bool
    let next_run: String?
    let last_run: String?
    let state: String
    let detail: String?

    var key: String { source + ":" + id }
}

struct StatusFile: Codable, Equatable {
    let generated_at: String
    let sources: [String: SourceStatus]
    let tasks: [TaskItem]
    let counts: [String: Int]?

    func count(_ s: String) -> Int { counts?[s] ?? 0 }

    /// Same content apart from the timestamp: used to skip needless widget reloads.
    func sameContent(as o: StatusFile) -> Bool {
        sources == o.sources && tasks == o.tasks && counts == o.counts
    }
}

enum Paths {
    /// Real home folder, even inside the widget's sandbox container.
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }
    static var statusFile: URL {
        // AITW_STATUS_FILE lets the helper show a sample file (used for the README screenshot).
        if let p = ProcessInfo.processInfo.environment["AITW_STATUS_FILE"] { return URL(fileURLWithPath: p) }
        return URL(fileURLWithPath: realHome + "/Library/Application Support/AITasksWidget/status.json")
    }
    static func load() -> Result<StatusFile, Error> {
        Result { try JSONDecoder().decode(StatusFile.self, from: Data(contentsOf: statusFile)) }
    }
}

enum Dates {
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
    static func short(_ d: Date, relativeTo now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDate(d, inSameDayAs: now) { return time }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "Tmrw " + time }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yest " + time }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

enum Look {
    static func color(_ state: String) -> Color {
        switch state {
        case "attention": return .yellow
        case "completed": return .green
        case "running": return .blue
        default: return .secondary
        }
    }
    static func label(_ state: String) -> String {
        switch state {
        case "attention": return "Needs attention"
        case "completed": return "Completed"
        case "running": return "Running"
        case "paused": return "Paused"
        default: return "Scheduled"
        }
    }
    static func symbol(_ state: String) -> String {
        switch state {
        case "attention": return "exclamationmark.triangle.fill"
        case "completed": return "checkmark.circle.fill"
        case "running": return "arrow.triangle.2.circlepath.circle.fill"
        case "paused": return "pause.circle"
        default: return "clock"
        }
    }
    static func sourceName(_ s: String) -> String { s == "codex" ? "ChatGPT" : "Claude" }
    static func bundleID(_ s: String) -> String {
        s == "codex" ? "com.openai.codex" : "com.anthropic.claudefordesktop"
    }
    static let expandURL = URL(string: "aitaskswidget://expand")!
    static let expandSymbol = "arrow.up.left.and.arrow.down.right"
    static func openURL(_ source: String) -> URL {
        URL(string: "aitaskswidget://open?app=\(source)")!
    }
}
