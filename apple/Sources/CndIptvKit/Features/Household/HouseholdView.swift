import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

/// Sidebar screen "Appareils": the devices of the household (PRD 41), their state, and the household actions
/// (create, join, copy the key, leave). The same actions exist in Settings; this screen is the place to
/// see which devices are around and why one is missing.
public struct HouseholdView: View {
    var localSync: LocalSyncService?
    @State private var store = HouseholdStore.shared
    @State private var showingJoin = false
    @State private var joinKey = ""
    @State private var showingLeaveConfirm = false
    @State private var errorMessage: String?
    @State private var keyCopied = false
    @State private var deviceToRemove: (id: String, name: String)?
    #if !os(tvOS)
    @State private var showingQR = false
    /// The key behind the QR code: read when the sheet opens, dropped when it closes.
    @State private var qrKey: String?
    @State private var remoteCommandText = ""
    @State private var remoteCommandSent = false
    #endif
    #if os(iOS)
    @State private var showingScanner = false
    #endif
    @State private var showingNearbyInvite = false
    @State private var showingNearbyJoin = false
    @State private var showingAddTV = false
    @State private var languageStore = AppLanguageStore.shared

    private func t(_ key: String) -> String { languageStore.t(key) }
    private func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: languageStore.t(key), arguments: args)
    }

    public init(localSync: LocalSyncService?) {
        self.localSync = localSync
    }

    public var body: some View {
        List {
            if store.isJoined {
                thisDeviceSection
                #if !os(tvOS)
                if let localSync {
                    remoteCommandSection(localSync)
                }
                #endif
                devicesSection
                syncLogSection
                actionsSection
            } else {
                welcomeSection
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(t("household.title"))
        #if !os(tvOS)
        .sheet(isPresented: $showingQR, onDismiss: { qrKey = nil }) {
            HouseholdQRSheet(keyHex: qrKey ?? "") { showingQR = false }
        }
        #endif
        #if os(iOS)
        .sheet(isPresented: $showingScanner) {
            HouseholdScanSheet { key in
                showingScanner = false
                join(key: key)
            } onClose: {
                showingScanner = false
            }
        }
        #endif
        #if !os(tvOS)
        .sheet(isPresented: $showingAddTV) {
            HouseholdAddTVSheet { showingAddTV = false }
        }
        #endif
        .sheet(isPresented: $showingNearbyInvite) {
            HouseholdNearbyInviteSheet {
                showingNearbyInvite = false
            }
        }
        .sheet(isPresented: $showingNearbyJoin) {
            HouseholdNearbyJoinSheet {
                showingNearbyJoin = false
                localSync?.start()
            } onClose: {
                showingNearbyJoin = false
            }
        }
        .alert(t("household.joinAlertTitle"), isPresented: $showingJoin) {
            TextField(t("household.joinKeyPlaceholder"), text: $joinKey)
            Button(t("household.joinButton")) { join() }
            Button(t("common.cancel"), role: .cancel) { joinKey = "" }
        } message: {
            Text(t("household.joinAlertMessage"))
        }
        .confirmationDialog(t("household.leaveConfirmTitle"), isPresented: $showingLeaveConfirm, titleVisibility: .visible) {
            Button(t("household.leaveConfirmButton"), role: .destructive) {
                store.leaveHousehold()
                localSync?.stop()
            }
            Button(t("common.cancel"), role: .cancel) {}
        } message: {
            Text(t("household.leaveConfirmMessage"))
        }
        .confirmationDialog(
            t("household.removeConfirmTitle", deviceToRemove?.name ?? t("household.removeThisDevice")),
            isPresented: Binding(get: { deviceToRemove != nil }, set: { if !$0 { deviceToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button(t("household.removeConfirmButton"), role: .destructive) {
                if let target = deviceToRemove {
                    do { try localSync?.removeDevice(target.id) } catch { errorMessage = error.localizedDescription }
                }
                deviceToRemove = nil
            }
            Button(t("common.cancel"), role: .cancel) { deviceToRemove = nil }
        } message: {
            Text(t("household.removeConfirmMessage"))
        }
    }

    // MARK: Sections

    private var welcomeSection: some View {
        Section {
            Text(t("household.welcome.description"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                do {
                    _ = try store.createHousehold()
                    errorMessage = nil
                    localSync?.start()
                } catch {
                    errorMessage = t("household.welcome.createError", error.localizedDescription)
                }
            } label: {
                Label(t("household.welcome.create"), systemImage: "house.fill")
            }
            Button {
                showingNearbyJoin = true
            } label: {
                Label(t("household.welcome.joinNearby"), systemImage: "wave.3.forward.circle.fill")
            }
            #if os(iOS)
            Button {
                showingScanner = true
            } label: {
                Label(t("household.welcome.scanQR"), systemImage: "qrcode.viewfinder")
            }
            #endif
            Button {
                showingJoin = true
            } label: {
                Label(t("household.welcome.joinWithKey"), systemImage: "person.badge.key")
            }
        } header: {
            Text(t("household.welcome.header"))
        }
    }

    private var thisDeviceSection: some View {
        Section(t("household.thisDevice.header")) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.deviceName).font(.headline)
                    Text(t("household.thisDevice.householdPrefix", store.householdId ?? ""))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        #if !os(tvOS)
                        .textSelection(.enabled)
                        #endif
                }
            } icon: {
                Image(systemName: Self.icon(for: store.deviceType)).foregroundStyle(.tint)
            }
            if let localSync {
                networkStatus(localSync)
            }
        }
    }

    @ViewBuilder
    private func networkStatus(_ sync: LocalSyncService) -> some View {
        let healthy = sync.isListening && sync.isBrowsing
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(healthy ? t("household.network.active") : t("household.network.inactive"))
                Text(sync.syncStatusMessage).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: healthy ? "wifi" : "wifi.exclamationmark")
                .foregroundStyle(healthy ? Color.green : Color.orange)
        }
        if let last = sync.lastSyncDate {
            LabeledContent(t("household.network.lastSync"), value: last.formatted(date: .omitted, time: .standard))
        }
        if !healthy {
            Button {
                sync.ensureRunning()
            } label: {
                Label(t("household.network.restart"), systemImage: "arrow.clockwise")
            }
        }
    }

    #if !os(tvOS)
    private func remoteCommandSection(_ sync: LocalSyncService) -> some View {
        let isEmpty = remoteCommandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Section {
            TextField(t("household.remote.placeholder"), text: $remoteCommandText)
                .submitLabel(.send)
                .onSubmit {
                    sendRemoteCommand(sync)
                }
            Button {
                sendRemoteCommand(sync)
            } label: {
                Label(t("household.remote.sendToTV"), systemImage: "paperplane.fill")
            }
            .disabled(isEmpty)
            if remoteCommandSent {
                Label(t("household.remote.sent"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        } header: {
            Text(t("household.remote.header"))
        } footer: {
            Text(t("household.remote.footer"))
        }
    }

    private func sendRemoteCommand(_ sync: LocalSyncService) {
        let trimmed = remoteCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sync.sendRemoteText(remoteCommandText)
        remoteCommandText = ""
        remoteCommandSent = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            remoteCommandSent = false
        }
    }
    #endif

    /// Devices heard on the network right now, then the household devices that are known but not
    /// currently reachable (shown offline), so the host sees every device of the household.
    private var householdPeers: [(peer: DiscoveredPeer, reachable: Bool)] {
        let active = localSync?.activePeers ?? []
        let activeIds = Set(active.map(\.id))
        let offline = store.knownDevices
            .filter { !activeIds.contains($0.id) }
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { DiscoveredPeer(id: $0.id, name: $0.name, deviceType: $0.deviceType, lastSeen: $0.lastSeen) }
        return active.map { ($0, true) } + offline.map { ($0, false) }
    }

    private var devicesSection: some View {
        let peers = householdPeers
        return Section {
            if !peers.isEmpty {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(spacing: 0) {
                        ForEach(peers, id: \.peer.id) { entry in
                            peerRow(entry.peer, now: context.date, reachable: entry.reachable)
                            if entry.peer.id != peers.last?.peer.id { Divider() }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("household.devices.none")).font(.subheadline)
                    Text(t("household.devices.noneHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text(t("household.devices.header"))
                Spacer()
                if let localSync, store.isJoined {
                    Button {
                        localSync.refreshPeers()
                    } label: {
                        Label(t("common.refresh"), systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(t("household.devices.refreshA11y"))
                }
            }
        }
    }

    /// What the household sync did, most recent first: devices found, data sent and received, accounts
    /// loaded, and why something failed. Names and counts only.
    @ViewBuilder
    private var syncLogSection: some View {
        if let localSync {
            Section {
                if localSync.syncLog.isEmpty {
                    Text(t("household.syncLog.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(localSync.syncLog.reversed().prefix(40)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.text)
                                .font(.caption)
                                .foregroundStyle(entry.isWarning ? Color.orange : Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    #if !os(tvOS)
                    HStack {
                        Button(t("household.syncLog.copy")) { copySyncLog(localSync.syncLog) }
                        Spacer()
                        Button(t("common.clear"), role: .destructive) { localSync.clearLog() }
                    }
                    .font(.caption)
                    #endif
                }
            } header: {
                Text(t("household.syncLog.header"))
            }
        }
    }

    #if !os(tvOS)
    private func copySyncLog(_ entries: [SyncLogEntry]) {
        let text = entries.map { "\($0.date.formatted(date: .omitted, time: .standard)) \($0.isWarning ? "⚠︎ " : "")\($0.text)" }
            .joined(separator: "\n")
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
    #endif

    private func peerRow(_ peer: DiscoveredPeer, now: Date, reachable: Bool) -> some View {
        let seconds = now.timeIntervalSince(peer.lastSeen)
        let online = reachable && seconds < 120
        return HStack(spacing: 12) {
            Image(systemName: Self.icon(for: peer.deviceType))
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(online ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).font(.body)
                Text(Self.statusText(for: peer, online: online, lastSeen: peer.lastSeen))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(online ? Color.green : Color.gray)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            #if !os(tvOS)
            Menu {
                Button(role: .destructive) {
                    deviceToRemove = (peer.id, peer.name)
                } label: {
                    Label(t("household.devices.removeMenu"), systemImage: "person.badge.minus")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            #endif
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var actionsSection: some View {
        Section {
            if let localSync {
                // Two additive buttons instead of "Synchroniser": nothing is ever deleted on another device,
                // and an account is never added twice (merged by identity in Rust).
                Button {
                    localSync.sendNow()
                } label: {
                    Label(t("household.actions.send"), systemImage: "square.and.arrow.up")
                }
                Button {
                    localSync.receiveNow()
                } label: {
                    Label(t("household.actions.receive"), systemImage: "square.and.arrow.down")
                }
            }
            #if !os(tvOS)
            Button {
                showingAddTV = true
            } label: {
                Label(t("household.actions.addSamsungTV"), systemImage: "tv.badge.wifi")
            }
            Button {
                showingNearbyInvite = true
            } label: {
                Label(t("household.actions.addNearby"), systemImage: "person.badge.plus")
            }
            Button {
                showQRCode()
            } label: {
                Label(t("household.actions.showQR"), systemImage: "qrcode")
            }
            Button {
                copyKey()
            } label: {
                Label(keyCopied ? t("household.actions.keyCopied") : t("household.actions.copyKey"), systemImage: keyCopied ? "checkmark" : "key")
            }
            #endif
            Button(role: .destructive) {
                showingLeaveConfirm = true
            } label: {
                Label(t("household.actions.leave"), systemImage: "rectangle.portrait.and.arrow.right")
            }
        } footer: {
            Text(t("household.actions.footer"))
        }
    }

    // MARK: Actions

    private func join() {
        let key = joinKey
        joinKey = ""
        join(key: key)
    }

    private func join(key: String) {
        do {
            _ = try store.joinHousehold(keyHex: key)
            errorMessage = nil
            localSync?.start()
        } catch {
            errorMessage = t("household.error.invalidKey", error.localizedDescription)
        }
    }

    #if !os(tvOS)
    private func showQRCode() {
        guard let key = store.currentHouseholdKeyHex() else {
            errorMessage = t("household.error.keyNotFound")
            return
        }
        errorMessage = nil
        qrKey = key
        showingQR = true
    }
    #endif

    private func copyKey() {
        guard let key = store.currentHouseholdKeyHex() else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        #elseif os(iOS) || os(visionOS)
        UIPasteboard.general.string = key
        #endif
        keyCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            keyCopied = false
        }
    }

    // MARK: Formatting

    static func icon(for deviceType: String) -> String {
        switch deviceType.lowercased() {
        case "tv": return "tv"
        case "desktop", "mac": return "laptopcomputer"
        case "tablet": return "ipad"
        default: return "iphone"
        }
    }

    @MainActor
    static func statusText(for peer: DiscoveredPeer, online: Bool, lastSeen: Date) -> String {
        let lang = AppLanguageStore.shared
        guard online else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return lang.t("household.status.offlineSeen", formatter.localizedString(for: lastSeen, relativeTo: Date()))
        }
        if !peer.canPlay { return lang.t("household.status.availableNoPlay") }
        return peer.state == "playing" ? lang.t("household.status.playing") : lang.t("household.status.available")
    }
}

public enum RemoteCommandTargetResolver {
    public static let allTargetId = "__all__"

    public static func connectedPeers(from peers: [DiscoveredPeer], now: Date = Date()) -> [DiscoveredPeer] {
        peers.filter { now.timeIntervalSince($0.lastSeen) < 120 }
    }

    public static func defaultSelection(connectedPeers: [DiscoveredPeer], current: String?) -> String? {
        if connectedPeers.isEmpty { return nil }
        if connectedPeers.count == 1 { return connectedPeers[0].id }
        if let current, current == allTargetId || connectedPeers.contains(where: { $0.id == current }) {
            return current
        }
        return allTargetId
    }
}

#if !os(tvOS)
/// Dedicated accessible screen "Commande TV" for sending voice-dictated or typed commands
/// to one connected household device (auto-selected when unique) or all connected devices.
public struct RemoteCommandView: View {
    var localSync: LocalSyncService?
    @State private var store = HouseholdStore.shared
    @State private var commandText = ""
    @State private var commandSent = false
    @State private var selectedTargetId: String?
    @State private var languageStore = AppLanguageStore.shared

    private func t(_ key: String) -> String { languageStore.t(key) }
    private func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: languageStore.t(key), arguments: args)
    }

    private var quickCommands: [String] {
        [t("remoteCommand.quick.1"), t("remoteCommand.quick.2"), t("remoteCommand.quick.3")]
    }

    public init(localSync: LocalSyncService?) {
        self.localSync = localSync
    }

    private var connectedPeers: [DiscoveredPeer] {
        RemoteCommandTargetResolver.connectedPeers(from: localSync?.activePeers ?? [])
    }

    public var body: some View {
        List {
            if !store.isJoined || localSync == nil {
                notJoinedSection
            } else if let localSync {
                targetDevicesSection
                commandInputSection(localSync)
            }
        }
        .navigationTitle(t("remoteCommand.title"))
        .onAppear { syncSelection() }
        .onChange(of: connectedPeers.map(\.id)) { _, _ in syncSelection() }
    }

    private var notJoinedSection: some View {
        Section(t("remoteCommand.notJoined.header")) {
            Label(t("remoteCommand.notJoined.title"), systemImage: "house.slash")
                .accessibilityLabel(t("remoteCommand.notJoined.title"))
            Text(t("remoteCommand.notJoined.body"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHint(t("remoteCommand.notJoined.hint"))
        }
    }

    private var targetDevicesSection: some View {
        Section {
            if connectedPeers.isEmpty {
                Label(t("remoteCommand.devices.noneTitle"), systemImage: "tv.slash")
                    .accessibilityLabel(t("remoteCommand.devices.noneTitle"))
                Text(t("remoteCommand.devices.noneBody"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if connectedPeers.count == 1, let peer = connectedPeers.first {
                HStack(spacing: 12) {
                    Image(systemName: HouseholdView.icon(for: peer.deviceType))
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(peer.name)
                            .font(.body)
                        Text(t("remoteCommand.devices.autoSelected"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(t("remoteCommand.devices.targetA11y", peer.name))
                .accessibilityValue(t("remoteCommand.devices.autoSelected"))
            } else {
                Picker(t("remoteCommand.devices.targetPicker"), selection: $selectedTargetId) {
                    Text(t("remoteCommand.devices.allConnected"))
                        .tag(Optional(RemoteCommandTargetResolver.allTargetId))
                    ForEach(connectedPeers) { peer in
                        Label(peer.name, systemImage: HouseholdView.icon(for: peer.deviceType))
                            .tag(Optional(peer.id))
                    }
                }
                .accessibilityLabel(t("remoteCommand.devices.targetPicker"))
                .accessibilityHint(t("remoteCommand.devices.targetHint"))
                .accessibilityValue(selectedTargetLabel)
            }
        } header: {
            HStack {
                Text(t("remoteCommand.devices.header"))
                Spacer()
                if let localSync {
                    Button {
                        localSync.refreshPeers()
                    } label: {
                        Label(t("common.refresh"), systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(t("remoteCommand.devices.refreshA11y"))
                }
            }
        }
    }

    private func commandInputSection(_ sync: LocalSyncService) -> some View {
        let isEmpty = commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Section {
            TextField(t("remoteCommand.input.placeholder"), text: $commandText)
                .submitLabel(.send)
                .onSubmit { sendCommand(sync) }
                .accessibilityLabel(t("remoteCommand.input.a11yLabel"))
                .accessibilityHint(t("remoteCommand.input.a11yHint"))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickCommands, id: \.self) { chip in
                        Button(chip) {
                            commandText = chip
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(t("remoteCommand.input.suggestionA11y", chip))
                        .accessibilityHint(t("remoteCommand.input.suggestionHint", chip))
                    }
                }
                .padding(.vertical, 2)
            }

            Button {
                sendCommand(sync)
            } label: {
                Label(t("common.send"), systemImage: "paperplane.fill")
            }
            .disabled(isEmpty || connectedPeers.isEmpty)
            .accessibilityLabel(t("remoteCommand.input.sendA11y"))
            .accessibilityHint(t("remoteCommand.input.sendHint"))

            if commandSent {
                Label(t("remoteCommand.input.sent"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityLabel(t("remoteCommand.input.sent"))
            }
        } header: {
            Text(t("remoteCommand.input.header"))
        } footer: {
            Text(t("remoteCommand.input.footer"))
        }
    }

    private var selectedTargetLabel: String {
        guard let selectedTargetId, selectedTargetId != RemoteCommandTargetResolver.allTargetId else {
            return t("remoteCommand.devices.allConnected")
        }
        return connectedPeers.first(where: { $0.id == selectedTargetId })?.name ?? t("remoteCommand.devices.allConnected")
    }

    private func syncSelection() {
        selectedTargetId = RemoteCommandTargetResolver.defaultSelection(
            connectedPeers: connectedPeers,
            current: selectedTargetId
        )
    }

    private func sendCommand(_ sync: LocalSyncService) {
        let trimmed = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let targetId = selectedTargetId ?? RemoteCommandTargetResolver.defaultSelection(
            connectedPeers: connectedPeers,
            current: nil
        )
        let targetPeerId = (targetId == nil || targetId == RemoteCommandTargetResolver.allTargetId) ? nil : targetId
        sync.sendRemoteText(trimmed, targetPeerId: targetPeerId)
        commandText = ""
        commandSent = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            commandSent = false
        }
    }
}
#endif
