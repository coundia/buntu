import SwiftUI
import Observation
import CndCoreBridge

enum LogStatusStyle: Equatable {
    case none
    case success
    case redirect
    case failure

    /// `2xx` green, `3xx` blue, `4xx` / `5xx` red.
    static func of(_ status: UInt16?) -> LogStatusStyle {
        guard let status else { return .none }
        switch status {
        case 200..<300: return .success
        case 300..<400: return .redirect
        case 400...: return .failure
        default: return .none
        }
    }

    var color: Color {
        switch self {
        case .none: return .secondary
        case .success: return .green
        case .redirect: return .blue
        case .failure: return .red
        }
    }
}

enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all
    case warnings
    case errors

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Tous les niveaux"
        case .warnings: return "Avertissements et erreurs"
        case .errors: return "Erreurs"
        }
    }

    func matches(_ level: LogLevel) -> Bool {
        switch self {
        case .all: return true
        case .warnings: return level == .warn || level == .error
        case .errors: return level == .error
        }
    }
}

/// Live view of the engine's network log. It only polls inside `run()`, which the drawer starts
/// when it is expanded and cancels when it collapses or disappears: nothing ticks otherwise.
@Observable
@MainActor
final class ConsoleModel {
    nonisolated static var capacity: Int { 1_000 }
    nonisolated static var batchSize: UInt32 { 200 }

    let engine: CndEngine
    let pollInterval: Duration
    let appLog: AppLog

    private(set) var entries: [NetworkLogEntry] = []
    private(set) var isPolling = false
    private(set) var pollCount = 0
    var selectedCategories: Set<String> = []
    var levelFilter: LogLevelFilter = .all

    @ObservationIgnored private var lastSeq: UInt64 = 0
    @ObservationIgnored private var lastLocalSeq: UInt64 = 0

    init(engine: CndEngine, pollInterval: Duration = .milliseconds(500), appLog: AppLog = .shared) {
        self.engine = engine
        self.pollInterval = pollInterval
        self.appLog = appLog
    }

    var categories: [String] { Array(Set(entries.map(\.category))).sorted() }

    var filtered: [NetworkLogEntry] {
        entries.filter { entry in
            levelFilter.matches(entry.level)
                && (selectedCategories.isEmpty || selectedCategories.contains(entry.category))
        }
    }

    /// Fetches everything newer than the last entry seen, in batches of 200.
    func poll() async {
        let engine = self.engine
        while true {
            let after = lastSeq
            let batch = await Task.detached(priority: .utility) {
                engine.getLogsSince(afterSeqId: after, limit: Self.batchSize)
            }.value
            guard let last = batch.last else { break }
            lastSeq = last.seqId
            entries.append(contentsOf: batch)
            if batch.count < Int(Self.batchSize) { break }
        }
        let local = appLog.entries(after: lastLocalSeq)
        if let last = local.last {
            lastLocalSeq = last.seqId
            entries.append(contentsOf: local)
            // Engine and app entries come from two counters: order them by time (stable for equal stamps).
            entries = entries.enumerated()
                .sorted { ($0.element.timestampMs, $0.offset) < ($1.element.timestampMs, $1.offset) }
                .map(\.element)
        }
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        pollCount += 1
    }

    func run() async {
        isPolling = true
        defer { isPolling = false }
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(for: pollInterval)
        }
    }

    func clear() {
        engine.clearLogs()
        appLog.clear()
        entries = []
    }

    func toggle(category: String) {
        if selectedCategories.contains(category) {
            selectedCategories.remove(category)
        } else {
            selectedCategories.insert(category)
        }
    }

    // MARK: Formatting

    nonisolated static func format(_ entry: NetworkLogEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let time = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(entry.timestampMs) / 1000))
        var parts = [time, "\(entry.level)".uppercased(), entry.category]
        if let method = entry.method { parts.append(method) }
        if let status = entry.statusCode { parts.append(String(status)) }
        if let duration = entry.durationMs { parts.append("\(duration)ms") }
        if let url = entry.urlRedacted { parts.append(url) }
        parts.append("— " + entry.message)
        return parts.joined(separator: " ")
    }

    var copyText: String { filtered.map(Self.format).joined(separator: "\n") }
}

/// Collapsible, resizable bottom panel showing the network log.
struct NetworkConsoleDrawer: View {
    let model: ConsoleModel

    @AppStorage("console.collapsed") private var collapsed = false
    @AppStorage("console.height") private var storedHeight = 220.0
    @State private var dragStartHeight: Double?

    static let heightRange: ClosedRange<Double> = 120...520

    var body: some View {
        VStack(spacing: 0) {
            handle
            header
            if !collapsed {
                Divider()
                ConsoleLogList(model: model)
                    .frame(height: min(max(storedHeight, Self.heightRange.lowerBound), Self.heightRange.upperBound))
                    .task { await model.run() }
            }
        }
        .background(.thinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var handle: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 8)
            .overlay { Capsule().fill(.secondary.opacity(0.4)).frame(width: 36, height: 3) }
            .contentShape(Rectangle())
            #if !os(tvOS)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard !collapsed else { return }
                        let start = dragStartHeight ?? storedHeight
                        dragStartHeight = start
                        storedHeight = min(max(start - value.translation.height, Self.heightRange.lowerBound), Self.heightRange.upperBound)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            #endif
            #if os(macOS)
            .onHover { inside in if inside && !collapsed { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            #endif
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { collapsed.toggle() } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Déplier la console" : "Replier la console")
            Label("Console réseau", systemImage: "terminal").font(.caption.weight(.semibold))
            Text("\(model.filtered.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if !collapsed {
                Menu {
                    Picker("Niveau", selection: Bindable(model).levelFilter) {
                        ForEach(LogLevelFilter.allCases) { Text($0.title).tag($0) }
                    }
                    Divider()
                    ForEach(model.categories, id: \.self) { category in
                        Toggle(category, isOn: Binding(
                            get: { model.selectedCategories.contains(category) },
                            set: { _ in model.toggle(category: category) }
                        ))
                    }
                    if !model.selectedCategories.isEmpty {
                        Button("Toutes les catégories") { model.selectedCategories = [] }
                    }
                } label: {
                    Label("Filtres", systemImage: model.selectedCategories.isEmpty && model.levelFilter == .all
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button { Clipboard.copy(model.copyText) } label: { Label("Copier", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless)
                Button { model.clear() } label: { Label("Vider", systemImage: "trash") }
                    .buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct ConsoleLogList: View {
    let model: ConsoleModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.filtered, id: \.seqId) { entry in
                        Text(ConsoleModel.format(entry))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: entry))
                            #if !os(tvOS)
                            .textSelection(.enabled)
                            #endif
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.seqId)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.filtered.last?.seqId) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private func color(for entry: NetworkLogEntry) -> Color {
        let style = LogStatusStyle.of(entry.statusCode)
        if style != .none { return style.color }
        switch entry.level {
        case .error: return .red
        case .warn: return .orange
        default: return .primary
        }
    }
}
