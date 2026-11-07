// WidgetKit extension: shows Claude + ChatGPT scheduled tasks in
// Notification Center / on the desktop. Reads status.json written by the helper.

import OSLog
import SwiftUI
import WidgetKit

let renderLog = Logger(subsystem: "AITasksWidget", category: "render")

struct Entry: TimelineEntry {
    let date: Date
    let file: StatusFile?
    let error: String?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), file: nil, error: nil) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The helper reloads us whenever the data changes; this is only a fallback.
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    func current() -> Entry {
        switch Paths.load() {
        case .success(let f): return Entry(date: Date(), file: f, error: nil)
        case .failure(let e): return Entry(date: Date(), file: nil, error: e.localizedDescription)
        }
    }
}

// MARK: - Pieces

struct Counts: View {
    let file: StatusFile
    var body: some View {
        HStack(spacing: 8) {
            chip("attention", file.count("attention"))
            chip("scheduled", file.count("scheduled") + file.count("running"))
            chip("completed", file.count("completed"))
        }
    }
    func chip(_ s: String, _ n: Int) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Look.color(s)).frame(width: 7, height: 7)
            Text("\(n)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
    }
}

struct Row: View {
    let task: TaskItem
    let now: Date
    let showDetail: Bool

    var timeText: String {
        if task.state == "completed" || task.state == "attention", let d = Dates.parse(task.last_run) {
            return Dates.short(d, relativeTo: now)
        }
        if let d = Dates.parse(task.next_run) { return Dates.short(d, relativeTo: now) }
        return ""
    }

    var body: some View {
        Link(destination: Look.openURL(task.source)) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: Look.symbol(task.state))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Look.color(task.state))
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if showDetail {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(task.state == "attention" ? Look.color("attention") : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(timeText)
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    var subtitle: String {
        let src = Look.sourceName(task.source)
        if let d = task.detail, !d.isEmpty, task.state == "attention" || task.state == "completed" {
            return "\(src) · \(d)"
        }
        return "\(src) · \(task.schedule)"
    }
}

struct SourceErrors: View {
    let file: StatusFile
    var body: some View {
        ForEach(file.sources.keys.sorted(), id: \.self) { k in
            if let s = file.sources[k], !s.ok {
                Text("\(Look.sourceName(k)) data unreadable").font(.system(size: 10)).foregroundStyle(.yellow)
            }
        }
    }
}

// MARK: - Sizes

struct SmallView: View {
    let file: StatusFile
    let now: Date
    var top: TaskItem? { file.tasks.first { $0.state != "paused" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AI tasks").font(.system(size: 12, weight: .bold))
                Spacer()
                Image(systemName: Look.expandSymbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                line("attention", file.count("attention"))
                line("scheduled", file.count("scheduled") + file.count("running"))
                line("completed", file.count("completed"))
            }
            Spacer(minLength: 0)
            if let t = top {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                    Text(t.state == "attention" ? (t.detail ?? "") : Look.label(t.state))
                        .font(.system(size: 10)).foregroundStyle(Look.color(t.state)).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(Look.expandURL)
    }

    func line(_ s: String, _ n: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: Look.symbol(s)).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Look.color(s)).frame(width: 13)
            Text("\(n)").font(.system(size: 13, weight: .bold)).monospacedDigit()
            Text(s == "attention" ? "need attention" : s).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}

struct ListView: View {
    let file: StatusFile
    let now: Date
    let maxRows: Int
    let showDetail: Bool

    var active: [TaskItem] { file.tasks.filter { $0.state != "paused" } }

    var body: some View {
        VStack(alignment: .leading, spacing: showDetail ? 7 : 5) {
            HStack {
                Text("Scheduled AI tasks").font(.system(size: 13, weight: .bold))
                Spacer()
                Counts(file: file)
                ExpandButton()
            }
            SourceErrors(file: file)
            ForEach(active.prefix(maxRows), id: \.key) { Row(task: $0, now: now, showDetail: showDetail) }
            Spacer(minLength: 0)
            let more = active.count - maxRows
            HStack {
                if more > 0 { Text("+\(more) more") }
                Spacer()
                if let d = Dates.parse(file.generated_at) { Text("Updated \(d.formatted(date: .omitted, time: .shortened))") }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ExpandButton: View {
    var body: some View {
        Link(destination: Look.expandURL) {
            Image(systemName: Look.expandSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(4)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
    }
}

struct TasksWidgetView: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.widgetRenderingMode) var renderingMode
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.showsWidgetContainerBackground) var showsBackground
    let entry: Entry

    var body: some View {
        let _ = renderLog.log("render family=\(String(describing: family), privacy: .public) mode=\(String(describing: renderingMode), privacy: .public) scheme=\(String(describing: colorScheme), privacy: .public) showsBackground=\(showsBackground, privacy: .public)")
        Group {
            if let f = entry.file {
                switch family {
                case .systemSmall: SmallView(file: f, now: entry.date)
                case .systemMedium: ListView(file: f, now: entry.date, maxRows: 4, showDetail: false)
                case .systemLarge: ListView(file: f, now: entry.date, maxRows: 8, showDetail: true)
                default: ListView(file: f, now: entry.date, maxRows: 8, showDetail: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI tasks").font(.system(size: 12, weight: .bold))
                    Text(entry.error == nil ? "Loading…" : "No data yet. Is the AI Tasks helper running?")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    if let e = entry.error { Text(e).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(3) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // macOS renders this widget twice, in light and in dark (seen in the render log), and
        // when another app is in front it shows the LIGHT render with brightness turned into
        // opacity. Light backgrounds then become a pale panel and dark text turns invisible.
        // So the widget always draws itself dark: a dark background that turns see-through in
        // that state, and light text that stays solid. Same look in both renders.
        .environment(\.colorScheme, .dark)
        .containerBackground(for: .widget) {
            if renderingMode == .fullColor { Color(white: 0.11) } else { Color.clear }
        }
    }
}

struct AITasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AITasksWidget", provider: Provider()) { entry in
            TasksWidgetView(entry: entry)
        }
        .configurationDisplayName("Scheduled AI tasks")
        .description("Claude and ChatGPT scheduled tasks: yellow needs attention, green completed.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct AITasksWidgetBundle: WidgetBundle {
    var body: some Widget { AITasksWidget() }
}
