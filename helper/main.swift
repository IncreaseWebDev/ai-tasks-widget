// Background helper for the AI Tasks widget. No Dock icon, no menu bar item.
// 1. Every 60 s it runs the collector (which reads Claude + Codex data the sandboxed
//    widget is not allowed to read) and tells WidgetKit to reload when anything changed.
// 2. It handles the widget's links:
//      aitaskswidget://open?app=claude|codex  -> open that app
//      aitaskswidget://expand                 -> show the expanded task list beside the widget

import AppKit
import Combine
import SwiftUI
import WidgetKit

// MARK: - Data

final class Store: ObservableObject {
    @Published var file: StatusFile?
    @Published var refreshing = false
    private var lastReloaded: StatusFile?

    var collectorPath: String {
        Bundle.main.path(forResource: "collect", ofType: "py")
            ?? Paths.realHome + "/ai-tasks-widget/collector/collect.py"
    }

    func refresh() {
        if refreshing { return }
        refreshing = true
        let path = collectorPath
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-I", path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.refreshing = false
                self.load()
            }
        }
    }

    func load() {
        guard case .success(let f) = Paths.load() else { return }
        file = f
        // Reload the widget on content change, and at least every 10 minutes so relative times stay current.
        let stale = lastReloaded.flatMap { Dates.parse($0.generated_at) }.map { Date().timeIntervalSince($0) > 600 } ?? true
        if lastReloaded == nil || !lastReloaded!.sameContent(as: f) || stale {
            WidgetCenter.shared.reloadAllTimelines()
            lastReloaded = f
        }
    }
}

// MARK: - Expanded list

enum Category: String, CaseIterable, Identifiable {
    case attention, running, scheduled, completed, paused
    var id: String { rawValue }
    var title: String {
        switch self {
        case .attention: return "Needs attention"
        case .running: return "Running"
        case .scheduled: return "Scheduled"
        case .completed: return "Completed"
        case .paused: return "Paused"
        }
    }
}

struct CategoryChip: View {
    let title: String
    let color: Color
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.system(size: 12, weight: .semibold))
                Text("\(count)").font(.system(size: 11, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(selected ? color.opacity(0.25) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(selected ? color.opacity(0.9) : Color.primary.opacity(0.1), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ExpandedRow: View {
    let task: TaskItem
    @State private var hover = false

    var statusLine: (label: String, text: String) {
        let d = task.detail ?? ""
        switch task.state {
        case "attention":
            return ("Action needed", d.isEmpty ? "Open the app and check the last run" : d)
        case "running":
            return ("Running", d)
        case "completed":
            return ("Completed", d.isEmpty ? "Finished cleanly" : d)
        case "paused":
            return ("Paused", "Turned off. It will not run until re-enabled.")
        default:
            if let n = Dates.parse(task.next_run) {
                return ("Waiting", "Next run \(Dates.short(n))" + (d.isEmpty ? "" : ". \(d)"))
            }
            return ("Waiting", d.isEmpty ? "No upcoming run" : d)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Look.symbol(task.state))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Look.color(task.state))
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(task.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(Look.sourceName(task.source))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.09)))
                    Text(task.schedule).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                let s = statusLine
                (Text(s.label + ": ").fontWeight(.semibold) + Text(s.text))
                    .font(.system(size: 12))
                    .foregroundStyle(task.state == "attention" ? Look.color("attention") : Color.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if let desc = task.description, !desc.isEmpty {
                    Text(desc).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                timeLine("Next", task.next_run)
                timeLine("Last", task.last_run)
            }
            .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(task.state == "attention" ? Look.color("attention").opacity(0.10)
                      : (hover ? Color.primary.opacity(0.06) : Color.primary.opacity(0.025)))
        )
        .opacity(task.state == "paused" ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { openApp(task.source) }
        .help("Click to open \(Look.sourceName(task.source))")
    }

    @ViewBuilder func timeLine(_ label: String, _ iso: String?) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(Dates.parse(iso).map { Dates.short($0) } ?? "–")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
    }
}

struct ExpandedView: View {
    @ObservedObject var store: Store
    let close: () -> Void
    /// Empty = show all.
    @State private var selected: Set<Category> = []

    var tasks: [TaskItem] {
        let all = store.file?.tasks ?? []
        if selected.isEmpty { return all }
        return all.filter { t in selected.contains { $0.rawValue == t.state } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Scheduled AI tasks").font(.system(size: 16, weight: .bold))
                if let d = Dates.parse(store.file?.generated_at) {
                    Text("Updated \(d.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh now")
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close (Esc)")
            }

            // Categories: "All" by default; tap one or more to show only those.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    CategoryChip(title: "All", color: .secondary, count: store.file?.tasks.count ?? 0,
                                 selected: selected.isEmpty) { selected.removeAll() }
                    ForEach(Category.allCases) { c in
                        CategoryChip(title: c.title, color: Look.color(c.rawValue),
                                     count: store.file?.count(c.rawValue) ?? 0,
                                     selected: selected.contains(c)) {
                            if selected.contains(c) { selected.remove(c) } else { selected.insert(c) }
                        }
                    }
                }
            }

            if let srcs = store.file?.sources {
                ForEach(srcs.keys.sorted(), id: \.self) { k in
                    if let s = srcs[k], !s.ok {
                        Text("\(Look.sourceName(k)) data could not be read: \(s.error ?? "unknown error")")
                            .font(.system(size: 11.5)).foregroundStyle(Look.color("attention"))
                    }
                }
            }

            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(tasks, id: \.key) { ExpandedRow(task: $0) }
                    if tasks.isEmpty {
                        Text(store.file == nil ? "Loading…" : "Nothing in this category")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

func openApp(_ source: String) {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Look.bundleID(source)) {
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

// MARK: - Panel window

final class ExpandedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }  // Esc closes
}

final class Helper: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store()
    var timer: Timer?
    var panel: ExpandedPanel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.load()
        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.store.refresh() }
        // Debug aid: AITW_SNAPSHOT=/path.png renders the expanded panel to a PNG and quits.
        if let out = ProcessInfo.processInfo.environment["AITW_SNAPSHOT"] {
            let s = NSScreen.main!.visibleFrame
            showPanel(near: NSPoint(x: s.maxX - 900, y: s.maxY - 40))
            if let size = ProcessInfo.processInfo.environment["AITW_SNAPSHOT_SIZE"]?.split(separator: "x"),
               size.count == 2, let w = Double(size[0]), let h = Double(size[1]) {
                panel!.setFrame(NSRect(x: panel!.frame.minX, y: panel!.frame.maxY - h, width: w, height: h), display: true)
            }
            print("panel frame:", panel!.frame, "screen:", s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if let v = self.panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                NSApp.terminate(nil)
            }
        }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        // Read the pointer position first: it is where the user just clicked inside the widget.
        let click = NSEvent.mouseLocation
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let comps = URLComponents(string: s) else { return }
        switch comps.host {
        case "expand":
            if let p = panel, p.isVisible { p.orderOut(nil) } else { showPanel(near: click) }
        default:
            openApp(comps.queryItems?.first { $0.name == "app" }?.value ?? "claude")
        }
    }

    /// macOS does not tell apps where a desktop widget sits, so the panel is placed from the
    /// click point. The expand button is in the widget's top-right corner, so the widget's top
    /// edge is just above the click and its body is to the left of it.
    func frameForPanel(near click: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(click, $0.frame, false) } ?? NSScreen.main!
        let v = screen.visibleFrame
        let gap: CGFloat = 12
        let assumedWidgetWidth: CGFloat = 340   // medium/large widget width on macOS
        let widgetRight = min(click.x + 22, v.maxX)
        let widgetLeft = max(widgetRight - assumedWidgetWidth, v.minX)
        let spaceRight = v.maxX - (widgetRight + gap) - gap
        let spaceLeft = (widgetLeft - gap) - v.minX - gap

        let useRight = spaceRight >= min(spaceLeft, 800) || spaceRight >= 800
        let width = max(min(800, useRight ? spaceRight : spaceLeft), 420)
        let x = useRight ? widgetRight + gap : widgetLeft - gap - width

        let top = min(click.y + 26, v.maxY - gap)
        let height = max(min(1000, top - v.minY - gap), 300)
        return NSRect(x: max(x, v.minX + gap), y: top - height, width: width, height: height)
    }

    func showPanel(near click: NSPoint) {
        let frame = frameForPanel(near: click)
        if panel == nil {
            let p = ExpandedPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.delegate = self
            p.contentView = NSHostingView(rootView: ExpandedView(store: store) { [weak p] in p?.orderOut(nil) })
            panel = p
        }
        panel!.setFrame(frame, display: true)
        store.refresh()
        NSApp.activate(ignoringOtherApps: true)
        panel!.makeKeyAndOrderFront(nil)
    }

    // Click anywhere outside the panel to dismiss it, like a popover.
    func windowDidResignKey(_ notification: Notification) {
        panel?.orderOut(nil)
    }
}

let app = NSApplication.shared
let helper = Helper()
app.delegate = helper
app.setActivationPolicy(.accessory)
app.run()
