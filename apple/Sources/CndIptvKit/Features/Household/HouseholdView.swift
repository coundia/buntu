import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

/// Sidebar screen "Foyer": the devices of the household (PRD 41), their state, and the household actions
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

    public init(localSync: LocalSyncService?) {
        self.localSync = localSync
    }

    public var body: some View {
        List {
            if store.isJoined {
                thisDeviceSection
                devicesSection
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
        .navigationTitle("Foyer")
        .alert("Rejoindre un foyer", isPresented: $showingJoin) {
            TextField("Clé du foyer (64 caractères)", text: $joinKey)
            Button("Rejoindre") { join() }
            Button("Annuler", role: .cancel) { joinKey = "" }
        } message: {
            Text("Collez la clé affichée sur un autre appareil du foyer (écran Foyer, « Copier la clé »).")
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
                showingJoin = true
            } label: {
                Label("Rejoindre un foyer existant…", systemImage: "person.badge.key")
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

    private var devicesSection: some View {
        Section {
            if let localSync, !localSync.activePeers.isEmpty {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(spacing: 0) {
                        ForEach(localSync.activePeers) { peer in
                            peerRow(peer, now: context.date)
                            if peer.id != localSync.activePeers.last?.id { Divider() }
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
        } footer: {
            Text("La TV Samsung n'apparaît pas encore ici : son lien avec l'iPhone et le Mac (canal Samsung) n'est pas encore implémenté côté Apple.")
        }
    }

    private func peerRow(_ peer: DiscoveredPeer, now: Date) -> some View {
        let seconds = now.timeIntervalSince(peer.lastSeen)
        let online = seconds < 120
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
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var actionsSection: some View {
        Section {
            if let localSync {
                Button {
                    localSync.syncNow()
                } label: {
                    Label("Synchroniser maintenant", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            #if !os(tvOS)
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
            Text("La clé du foyer donne accès à vos favoris et à vos comptes IPTV : ne la partagez qu'avec vos propres appareils. Retirer un appareil à distance (avec changement de clé) n'est pas encore disponible.")
        }
    }

    // MARK: Actions

    private func join() {
        let key = joinKey
        joinKey = ""
        do {
            _ = try store.joinHousehold(keyHex: key)
            errorMessage = nil
            localSync?.start()
        } catch {
            errorMessage = "Clé de foyer invalide : \(error.localizedDescription)"
        }
    }

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
