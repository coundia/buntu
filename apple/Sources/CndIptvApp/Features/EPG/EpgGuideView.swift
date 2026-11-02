import SwiftUI
import CndCoreBridge

/// Horizontal scroll offset of the grid, read only by the sticky labels so scrolling does not
/// re-evaluate every row.
@Observable
@MainActor
private final class EpgScrollState {
    var x: CGFloat = 0
}

private struct EpgScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct EpgGuideView: View {
    @State private var model: EpgGuideModel
    @Binding var focus: IptvItemRecord?
    let revision: Int
    let playingURL: String?
    let onPlay: (IptvItemRecord) -> Void
    let onPlayCatchup: ((IptvItemRecord, EpgProgramRecord, String) -> Void)?
    let onScheduleRecording: ((IptvItemRecord, EpgProgramRecord) -> Void)?
    let onAddSeriesRule: ((IptvItemRecord, EpgProgramRecord) -> Void)?

    init(
        engine: CndEngine,
        focus: Binding<IptvItemRecord?>,
        revision: Int,
        playingURL: String?,
        onPlay: @escaping (IptvItemRecord) -> Void,
        onPlayCatchup: ((IptvItemRecord, EpgProgramRecord, String) -> Void)? = nil,
        onScheduleRecording: ((IptvItemRecord, EpgProgramRecord) -> Void)? = nil,
        onAddSeriesRule: ((IptvItemRecord, EpgProgramRecord) -> Void)? = nil
    ) {
        _model = State(initialValue: EpgGuideModel(engine: engine))
        _focus = focus
        self.revision = revision
        self.playingURL = playingURL
        self.onPlay = onPlay
        self.onPlayCatchup = onPlayCatchup
        self.onScheduleRecording = onScheduleRecording
        self.onAddSeriesRule = onAddSeriesRule
    }

    var body: some View {
        Group {
            if let channel = focus {
                ChannelScheduleView(
                    model: model,
                    channel: channel,
                    onPlay: onPlay,
                    onPlayCatchup: { program, replayUrl in
                        onPlayCatchup?(channel, program, replayUrl)
                    },
                    onScheduleRecording: { program in
                        onScheduleRecording?(channel, program)
                    },
                    onAddSeriesRule: { program in
                        onAddSeriesRule?(channel, program)
                    },
                    onBack: { focus = nil }
                )
            } else {
                EpgGridView(model: model, revision: revision, playingURL: playingURL, onPlay: onPlay) { channel in
                    focus = channel
                }
            }
        }
        .navigationTitle(focus.map { "Programme · \($0.name)" } ?? "Guide TV")
        .sheet(item: $model.selection) { selection in
            ProgramDetailSheet(
                selection: selection,
                model: model,
                onPlay: {
                    model.selection = nil
                    onPlay(selection.channel)
                },
                onPlayCatchup: { replayUrl in
                    let ch = selection.channel
                    let pr = selection.program
                    model.selection = nil
                    onPlayCatchup?(ch, pr, replayUrl)
                },
                onScheduleRecording: {
                    let ch = selection.channel
                    let pr = selection.program
                    model.selection = nil
                    onScheduleRecording?(ch, pr)
                },
                onAddSeriesRule: {
                    let ch = selection.channel
                    let pr = selection.program
                    model.selection = nil
                    onAddSeriesRule?(ch, pr)
                },
                onShowSchedule: {
                    model.selection = nil
                    focus = selection.channel
                },
                onClose: { model.selection = nil }
            )
        }
    }
}

// MARK: - Grid

private struct EpgGridView: View {
    @Bindable var model: EpgGuideModel
    let revision: Int
    let playingURL: String?
    let onPlay: (IptvItemRecord) -> Void
    let onShowSchedule: (IptvItemRecord) -> Void

    @State private var scroll = EpgScrollState()
    @State private var scrollToNow = 0

    static let labelWidth: CGFloat = 180
    static let rowHeight: CGFloat = 56
    static let headerHeight: CGFloat = 32

    init(
        model: EpgGuideModel,
        revision: Int,
        playingURL: String?,
        onPlay: @escaping (IptvItemRecord) -> Void,
        onShowSchedule: @escaping (IptvItemRecord) -> Void
    ) {
        self.model = model
        self.revision = revision
        self.playingURL = playingURL
        self.onPlay = onPlay
        self.onShowSchedule = onShowSchedule
    }

    var body: some View {
        Group {
            if model.channels.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "Aucun guide disponible",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Aucune chaîne avec identifiant EPG. Synchronisez une source qui fournit un guide XMLTV.")
                )
            } else {
                grid
            }
        }
        .searchFilterToolbar(
            state: model.filter,
            sortOptions: [.channelNumber, .name, .group],
            prompt: "Rechercher une chaîne"
        )
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { model.shiftWindow(byHours: -6) } label: { Label("6 h plus tôt", systemImage: "chevron.left") }
                Button("Maintenant") {
                    model.jumpToNow()
                    scrollToNow += 1
                }
                Button { model.shiftWindow(byHours: 6) } label: { Label("6 h plus tard", systemImage: "chevron.right") }
            }
        }
        .task(id: "\(model.filter.signature)#\(revision)") { await model.reload() }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(model.channels, id: \.id) { channel in
                            row(for: channel)
                        }
                        if model.hasMore {
                            ProgressView()
                                .frame(width: Self.labelWidth)
                                .padding()
                                .onAppear { Task { await model.loadNextPage() } }
                        }
                    } header: {
                        timeHeader
                    }
                }
                .frame(width: Self.labelWidth + model.timeline.totalWidth, alignment: .leading)
                .overlay(alignment: .topLeading) { nowLine }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: EpgScrollOffsetKey.self,
                            value: -proxy.frame(in: .named("epg-scroll")).minX
                        )
                    }
                )
            }
            .coordinateSpace(name: "epg-scroll")
            .onPreferenceChange(EpgScrollOffsetKey.self) { scroll.x = max(0, $0) }
            .task(id: scrollToNow) {
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo("epg-now-marker", anchor: .leading)
            }
        }
    }

    private var nowX: CGFloat { model.timeline.x(for: Date()) }
    private var nowVisible: Bool { nowX >= 0 && nowX <= model.timeline.totalWidth }

    private var nowLine: some View {
        Group {
            if nowVisible {
                Rectangle()
                    .fill(.red.opacity(0.8))
                    .frame(width: 1.5)
                    .offset(x: Self.labelWidth + nowX)
                    .padding(.top, Self.headerHeight)
                    .allowsHitTesting(false)
            }
        }
    }

    private var timeHeader: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.timeline.ticks().enumerated()), id: \.offset) { index, tick in
                Text(tick.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .frame(height: Self.headerHeight, alignment: .leading)
                    .offset(x: Self.labelWidth + CGFloat(index * 30) * model.timeline.pointsPerMinute)
            }
            Color.clear.frame(width: 1, height: 1)
                .offset(x: max(0, Self.labelWidth + nowX - 80))
                .id("epg-now-marker")
            StickyLabel(scroll: scroll) {
                Text("Chaîne").font(.caption.weight(.semibold))
                    .frame(width: Self.labelWidth, height: Self.headerHeight, alignment: .leading)
                    .padding(.leading, 8)
                    .background(.thinMaterial)
            }
        }
        .frame(width: Self.labelWidth + model.timeline.totalWidth, height: Self.headerHeight, alignment: .topLeading)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(for channel: IptvItemRecord) -> some View {
        let programs = channel.tvgId.flatMap { model.programs[$0] } ?? []
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.labelWidth)
                programStrip(channel: channel, programs: programs)
            }
            StickyLabel(scroll: scroll) {
                channelLabel(channel)
            }
        }
        .frame(height: Self.rowHeight)
        .overlay(alignment: .bottom) { Divider() }
        .task(id: model.timeline.start) { await model.loadPrograms(for: channel) }
        .onAppear { model.loadMoreIfNeeded(current: channel) }
    }

    private func channelLabel(_ channel: IptvItemRecord) -> some View {
        HStack(spacing: 8) {
            ThumbnailImageView(urlString: channel.logoUrl, size: .tvLogo)
                .frame(width: 32, height: 32)
            Text(channel.name).font(.caption.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .leading)
        .background(.thinMaterial)
        .overlay(alignment: .trailing) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { onPlay(channel) }
        .contextMenu {
            Button("Lire", systemImage: "play.fill") { onPlay(channel) }
            Button("Voir le programme TV complet", systemImage: "calendar") { onShowSchedule(channel) }
        }
        .overlay(alignment: .topLeading) {
            if channel.streamUrl == playingURL {
                Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.tint).padding(4)
            }
        }
    }

    private func programStrip(channel: IptvItemRecord, programs: [EpgProgramRecord]) -> some View {
        ZStack(alignment: .leading) {
            ForEach(programs, id: \.id) { program in
                if let block = model.timeline.block(for: program) {
                    ProgramBlockView(
                        program: program,
                        isLive: isLive(program),
                        hasCatchup: model.isCatchupAvailable(for: channel, program: program)
                    )
                    .frame(width: max(block.width - 2, 1), height: Self.rowHeight - 8)
                    .offset(x: block.x)
                    .onTapGesture { model.selection = EpgSelection(channel: channel, program: program) }
                }
            }
        }
        .frame(width: model.timeline.totalWidth, height: Self.rowHeight, alignment: .leading)
    }

    private func isLive(_ program: EpgProgramRecord) -> Bool {
        let now = Int64(Date().timeIntervalSince1970)
        return program.startTs <= now && program.endTs > now
    }
}

/// Keeps its content pinned to the visible left edge while the grid scrolls horizontally.
private struct StickyLabel<Content: View>: View {
    let scroll: EpgScrollState
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .offset(x: scroll.x)
            .zIndex(10)
    }
}

private struct ProgramBlockView: View {
    let program: EpgProgramRecord
    let isLive: Bool
    var hasCatchup: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(program.title).font(.caption.weight(.semibold)).lineLimit(1)
                if hasCatchup && !isLive {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tint)
                }
            }
            Text(EpgProgress.timeRange(program)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(isLive ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isLive ? Color.accentColor : .clear, lineWidth: 1))
        .clipped()
        .contentShape(Rectangle())
    }
}

// MARK: - Single channel schedule

private struct ChannelScheduleView: View {
    let model: EpgGuideModel
    let channel: IptvItemRecord
    let onPlay: (IptvItemRecord) -> Void
    let onPlayCatchup: (EpgProgramRecord, String) -> Void
    let onScheduleRecording: ((EpgProgramRecord) -> Void)?
    let onAddSeriesRule: ((EpgProgramRecord) -> Void)?
    let onBack: () -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    ThumbnailImageView(urlString: channel.logoUrl, size: .tvLogo).frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(channel.name).font(.headline)
                        if let group = channel.groupTitle { Text(group).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Lire", systemImage: "play.fill") { onPlay(channel) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if model.schedule.isEmpty && !model.isLoadingSchedule {
                Text("Aucun programme pour cette chaîne.").foregroundStyle(.secondary)
            }
            ForEach(EpgGuideModel.groupByDay(model.schedule), id: \.day) { group in
                Section(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                    ForEach(group.programs, id: \.id) { program in
                        scheduleRow(program)
                    }
                }
            }
        }
        .overlay { if model.isLoadingSchedule { ProgressView() } }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) { Label("Guide", systemImage: "chevron.left") }
            }
        }
        .task(id: channel.id) { await model.loadSchedule(for: channel) }
    }

    private func scheduleRow(_ program: EpgProgramRecord) -> some View {
        let now = Int64(Date().timeIntervalSince1970)
        let live = program.startTs <= now && program.endTs > now
        let catchup = !live && model.isCatchupAvailable(for: channel, program: program)
        let isPast = program.endTs <= now
        return HStack(alignment: .center, spacing: 12) {
            Text(Date(timeIntervalSince1970: TimeInterval(program.startTs)).formatted(date: .omitted, time: .shortened))
                .font(.callout.monospacedDigit())
                .foregroundStyle(live ? Color.accentColor : .secondary)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(program.title).font(.body.weight(live ? .bold : .regular))
                    if live {
                        Text("EN DIRECT").font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.red, in: Capsule()).foregroundStyle(.white)
                    } else if catchup {
                        Label("Replay", systemImage: "arrow.counterclockwise.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                if let subtitle = program.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                if live {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ProgressView(value: EpgProgress.ratio(start: program.startTs, end: program.endTs, now: context.date))
                    }
                }
            }
            Spacer()
            if catchup {
                Button {
                    if let replayUrl = model.buildCatchupUrl(for: channel, program: program) {
                        onPlayCatchup(program, replayUrl)
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Revoir cette émission (Replay)")
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !isPast {
                Button {
                    onScheduleRecording?(program)
                } label: {
                    Label("Enregistrer cette émission", systemImage: "recordingtape")
                }
                Button {
                    onAddSeriesRule?(program)
                } label: {
                    Label("Enregistrer toutes les diffusions (Series-Link)", systemImage: "repeat")
                }
            }
        }
        .onTapGesture { model.selection = EpgSelection(channel: channel, program: program) }
    }
}

// MARK: - Detail

private struct ProgramDetailSheet: View {
    let selection: EpgSelection
    let model: EpgGuideModel
    let onPlay: () -> Void
    let onPlayCatchup: (String) -> Void
    let onScheduleRecording: (() -> Void)?
    let onAddSeriesRule: (() -> Void)?
    let onShowSchedule: () -> Void
    let onClose: () -> Void

    var body: some View {
        let now = Int64(Date().timeIntervalSince1970)
        let isLive = selection.program.startTs <= now && selection.program.endTs > now
        let isPast = selection.program.endTs <= now
        let hasCatchup = model.isCatchupAvailable(for: selection.channel, program: selection.program)
        let replayUrl = hasCatchup ? model.buildCatchupUrl(for: selection.channel, program: selection.program) : nil

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(selection.program.title).font(.title2.bold())
                    if let subtitle = selection.program.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.headline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Label(selection.channel.name, systemImage: "tv")
                        Text("·")
                        Text(EpgProgress.timeRange(selection.program))
                        if let category = selection.program.category, !category.isEmpty {
                            Text("·")
                            Text(category)
                        }
                        if hasCatchup {
                            Text("·")
                            Label("Replay disponible", systemImage: "arrow.counterclockwise.circle")
                                .foregroundStyle(.tint)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    if let description = selection.program.description, !description.isEmpty {
                        Text(description).font(.body)
                    } else {
                        Text("Aucune description disponible.").foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Programme")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer", action: onClose) }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Voir tout le programme", action: onShowSchedule)
                    if !isPast {
                        Menu {
                            Button("Enregistrer cette émission", systemImage: "recordingtape") {
                                onScheduleRecording?()
                            }
                            Button("Series-Link (Toutes les diffusions)", systemImage: "repeat") {
                                onAddSeriesRule?()
                            }
                        } label: {
                            Label("Enregistrer", systemImage: "recordingtape")
                        }
                    }
                    if isPast && hasCatchup, let url = replayUrl {
                        Button("Revoir (Replay)", systemImage: "arrow.counterclockwise.circle.fill") {
                            onPlayCatchup(url)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if isLive {
                        if hasCatchup, let url = replayUrl {
                            Button("Reprendre depuis le début", systemImage: "arrow.counterclockwise") {
                                onPlayCatchup(url)
                            }
                        }
                        Button("Regarder le direct", systemImage: "play.fill", action: onPlay)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Regarder la chaîne", systemImage: "play.fill", action: onPlay)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 340)
        #endif
        .presentationDetents([.medium, .large])
    }
}
