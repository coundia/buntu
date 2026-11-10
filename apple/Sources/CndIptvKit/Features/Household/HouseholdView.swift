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
    #endif
    #if os(iOS)
    @State private var showingScanner = false
    #endif
    @State private var showingNearbyInvite = false
    @State private var showingNearbyJoin = false

    public init(localSync: LocalSyncService?) {
        self.localSync = localSync
    }

    public var body: some View {
        List {
            if store.isJoined {
                thisDeviceSection
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
        .navigationTitle("Appareils")
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
        .alert("Rejoindre un foyer", isPresented: $showingJoin) {
            TextField("Clé du foyer (64 caractères)", text: $joinKey)
            Button("Rejoindre") { join() }
            Button("Annuler", role: .cancel) { joinKey = "" }
        } message: {
            Text("Collez la clé affichée sur un autre appareil du foyer (écran Appareils, « Copier la clé »).")
        }
        .confirmationDialog("Quitter le foyer ?", isPresented: $showingLeaveConfirm, titleVisibility: .visible) {
            Button("Quitter le foyer", role: .destructive) {
                store.leaveHousehold()
                localSync?.stop()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cet appareil ne partagera plus ses favoris, reprises et comptes avec le foyer. Les autres appareils ne sont pas modifiés.")
        }
        .confirmationDialog(
            "Retirer \(deviceToRemove?.name ?? "cet appareil") du foyer ?",
            isPresented: Binding(get: { deviceToRemove != nil }, set: { if !$0 { deviceToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Retirer du foyer", role: .destructive) {
                if let target = deviceToRemove {
                    do { try localSync?.removeDevice(target.id) } catch { errorMessage = error.localizedDescription }
                }
                deviceToRemove = nil
            }
            Button("Annuler", role: .cancel) { deviceToRemove = nil }
        } message: {
            Text("La clé du foyer est changée : cet appareil ne pourra plus lire vos favoris ni vos comptes. Les autres appareils reçoivent la nouvelle clé automatiquement ; ceux qui sont éteints la reçoivent à leur prochain passage sur le Wi‑Fi (sous 30 jours).")
        }
    }

    // MARK: Sections

    private var welcomeSection: some View {
        Section {
            Text("Reliez vos appareils Buntu (iPhone, Mac, TV, Android) sur le Wi-Fi de la maison, sans serveur : favoris, reprises de lecture, comptes et « Lire sur… ».")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                do {
                    _ = try store.createHousehold()
                    errorMessage = nil
                    localSync?.start()
                } catch {
                    errorMessage = "Création du foyer impossible : \(error.localizedDescription)"
                }
            } label: {
                Label("Créer un foyer", systemImage: "house.fill")
            }
            Button {
                showingNearbyJoin = true
            } label: {
                Label("Rejoindre un foyer à proximité…", systemImage: "wave.3.forward.circle.fill")
            }
            #if os(iOS)
            Button {
                showingScanner = true
            } label: {
                Label("Scanner un QR code", systemImage: "qrcode.viewfinder")
            }
            #endif
            Button {
                showingJoin = true
            } label: {
                Label("Rejoindre avec la clé…", systemImage: "person.badge.key")
            }
        } header: {
            Text("Aucun foyer")
        }
    }

    private var thisDeviceSection: some View {
        Section("Cet appareil") {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.deviceName).font(.headline)
                    Text("Foyer \(store.householdId ?? "")")
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
                Text(healthy ? "Réseau local actif" : "Réseau local inactif")
                Text(sync.syncStatusMessage).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: healthy ? "wifi" : "wifi.exclamationmark")
                .foregroundStyle(healthy ? Color.green : Color.orange)
        }
        if let last = sync.lastSyncDate {
            LabeledContent("Dernière synchronisation", value: last.formatted(date: .omitted, time: .standard))
        }
        if !healthy {
            Button {
                sync.ensureRunning()
            } label: {
                Label("Relancer la recherche", systemImage: "arrow.clockwise")
            }
        }
    }

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
                    Text("Aucun autre appareil détecté.").font(.subheadline)
                    Text("Ouvrez Buntu sur l'autre appareil, sur le même Wi-Fi, puis rejoignez ce foyer avec la clé. Un Wi-Fi invité, ou une box qui isole les appareils entre eux, empêche la détection. Sur iPhone, l'autorisation « Réseau local » doit être activée pour Buntu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Appareils du foyer")
        }
    }

    /// What the household sync did, most recent first: devices found, data sent and received, accounts
    /// loaded, and why something failed. Names and counts only.
    @ViewBuilder
    private var syncLogSection: some View {
        if let localSync {
            Section {
                if localSync.syncLog.isEmpty {
                    Text("Rien pour l'instant. Appuyez sur « Synchroniser maintenant ».")
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
                        Button("Copier le journal") { copySyncLog(localSync.syncLog) }
                        Spacer()
                        Button("Effacer", role: .destructive) { localSync.clearLog() }
                    }
                    .font(.caption)
                    #endif
                }
            } header: {
                Text("Journal de synchronisation")
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
                    Label("Retirer du foyer…", systemImage: "person.badge.minus")
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
                Button {
                    localSync.syncNow(full: true)
                } label: {
                    Label("Synchroniser maintenant", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            #if !os(tvOS)
            Button {
                showingNearbyInvite = true
            } label: {
                Label("Ajouter un appareil à proximité…", systemImage: "person.badge.plus")
            }
            Button {
                showQRCode()
            } label: {
                Label("Afficher le QR code (pour ajouter un appareil)", systemImage: "qrcode")
            }
            Button {
                copyKey()
            } label: {
                Label(keyCopied ? "Clé copiée" : "Copier la clé du foyer (pour ajouter un appareil)", systemImage: keyCopied ? "checkmark" : "key")
            }
            #endif
            Button(role: .destructive) {
                showingLeaveConfirm = true
            } label: {
                Label("Quitter le foyer", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } footer: {
            Text("La clé du foyer donne accès à vos favoris et à vos comptes IPTV : ne la partagez qu'avec vos propres appareils. Retirer un appareil (menu « … » de sa ligne) change la clé du foyer.")
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
            errorMessage = "Clé de foyer invalide : \(error.localizedDescription)"
        }
    }

    #if !os(tvOS)
    private func showQRCode() {
        guard let key = store.currentHouseholdKeyHex() else {
            errorMessage = "La clé du foyer est introuvable sur cet appareil."
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

    static func statusText(for peer: DiscoveredPeer, online: Bool, lastSeen: Date) -> String {
        guard online else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Hors ligne · vu \(formatter.localizedString(for: lastSeen, relativeTo: Date()))"
        }
        if !peer.canPlay { return "Disponible · ne peut pas lire" }
        return peer.state == "playing" ? "En lecture" : "Disponible"
    }
}
