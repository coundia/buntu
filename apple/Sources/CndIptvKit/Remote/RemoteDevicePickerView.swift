//
//  RemoteDevicePickerView.swift
//  CndIptvKit
//
//  Device selector for "Lire sur..." (PRD-42 § 2.1).
//

import SwiftUI
import CndCoreBridge

public struct RemoteDevicePickerView: View {
    public let item: IptvItemRecord
    public let positionMs: UInt64
    public let sourceKey: String?
    @Bindable public var localSync: LocalSyncService
    @Environment(\.dismiss) private var dismiss

    public init(item: IptvItemRecord, positionMs: UInt64, sourceKey: String?, localSync: LocalSyncService) {
        self.item = item
        self.positionMs = positionMs
        self.sourceKey = sourceKey
        self.localSync = localSync
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    if localSync.activePeers.isEmpty {
                        Text("Aucun autre appareil Buntu détecté sur le réseau local")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(localSync.activePeers) { peer in
                            Button {
                                RemotePlaybackCoordinator.shared.startRemotePlayback(
                                    targetPeer: peer,
                                    item: item,
                                    positionMs: positionMs,
                                    sourceKey: sourceKey
                                )
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: iconForDeviceType(peer.deviceType))
                                        .font(.title2)
                                        .foregroundStyle(Color.accentColor)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peer.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)

                                        Text(peer.state == "playing" ? "En cours de lecture" : "Disponible")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "arrow.up.right.video")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                } header: {
                    Text("Lire sur un appareil du foyer")
                } footer: {
                    Text("L'appareil cible ouvrira directement le flux vidéo avec son propre lecteur.")
                }
            }
            .navigationTitle("Lire sur…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    private func iconForDeviceType(_ type: String) -> String {
        switch type.lowercased() {
        case "tv": return "tv"
        case "desktop", "mac": return "laptopcomputer"
        default: return "iphone"
        }
    }
}
