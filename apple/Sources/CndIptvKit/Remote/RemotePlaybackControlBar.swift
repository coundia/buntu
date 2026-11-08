//
//  RemotePlaybackControlBar.swift
//  CndIptvKit
//
//  Bottom mini control bar when playing remotely on another device (PRD-42 § 2.2).
//

import SwiftUI

public struct RemotePlaybackControlBar: View {
    @Bindable public var coordinator: RemotePlaybackCoordinator

    public init(coordinator: RemotePlaybackCoordinator = .shared) {
        self.coordinator = coordinator
    }

    public var body: some View {
        if let session = coordinator.activeRemoteSession {
            HStack(spacing: 12) {
                Image(systemName: "tv.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text("Lecture sur \(session.targetPeerName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    coordinator.sendPlaybackControl(action: "seek_by", value: -10000)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.body)
                }
                .buttonStyle(.plain)

                Button {
                    let nextAction = session.state == "playing" ? "pause" : "resume"
                    coordinator.sendPlaybackControl(action: nextAction)
                } label: {
                    Image(systemName: session.state == "playing" ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Button {
                    coordinator.sendPlaybackControl(action: "seek_by", value: 30000)
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.body)
                }
                .buttonStyle(.plain)

                Button {
                    coordinator.pullPlaybackHere()
                } label: {
                    Text("Reprendre ici")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }
}

