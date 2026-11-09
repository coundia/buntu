//
//  PlayOnAnotherDeviceMenu.swift
//  CndIptvKit
//
//  "Lire sur un autre appareil" entry for the context menus of films, episodes and channels
//  (PRD-42): sends the item to a device of the household without opening the player here first.
//

import SwiftUI
import CndCoreBridge

struct PlayOnAnotherDeviceMenu: View {
    let item: IptvItemRecord
    /// Where the other device starts; ignored for a live channel.
    var positionMs: UInt64 = 0

    /// Films, episodes and live channels of the catalog: local files and recordings do not exist elsewhere.
    static func isSupported(_ item: IptvItemRecord) -> Bool {
        ["live", "movie", "episode"].contains(item.kind)
    }

    var body: some View {
        let coordinator = RemotePlaybackCoordinator.shared
        if coordinator.isHouseholdActive, Self.isSupported(item) {
            let peers = coordinator.availablePeers
            Menu("Lire sur un autre appareil", systemImage: "rectangle.on.rectangle") {
                if peers.isEmpty {
                    Text("Aucun autre appareil du foyer détecté")
                } else {
                    ForEach(peers) { peer in
                        Button(peer.name, systemImage: Self.icon(for: peer.deviceType)) {
                            coordinator.startRemotePlayback(
                                targetPeer: peer,
                                item: item,
                                positionMs: item.kind == "live" ? 0 : positionMs,
                                sourceKey: nil
                            )
                        }
                    }
                }
            }
        }
    }

    private static func icon(for type: String) -> String {
        switch type.lowercased() {
        case "tv": return "tv"
        case "desktop", "mac": return "laptopcomputer"
        default: return "iphone"
        }
    }
}
