import Foundation
import CndCoreBridge

/// The channel list currently browsed in Live TV, so the next/previous channel can be reached from
/// anywhere (keyboard, media keys, lock screen) without the Live TV screen being visible.
@MainActor
final class LiveZapper {
    private(set) var channels: [IptvItemRecord] = []
    private var programTitle: (IptvItemRecord) -> String? = { _ in nil }
    private(set) var currentChannel: IptvItemRecord?
    private(set) var previousChannel: IptvItemRecord?

    var canRecall: Bool {
        guard let previousChannel else { return false }
        return previousChannel.streamUrl != currentChannel?.streamUrl
    }

    func update(channels: [IptvItemRecord], programTitle: @escaping (IptvItemRecord) -> String?) {
        self.channels = channels
        self.programTitle = programTitle
    }

    func recordChannelOpened(_ channel: IptvItemRecord) {
        if let currentChannel, currentChannel.streamUrl != channel.streamUrl {
            previousChannel = currentChannel
        }
        currentChannel = channel
    }

    func recallChannel() -> IptvItemRecord? {
        guard canRecall else { return nil }
        return previousChannel
    }

    func channel(byNumber number: Int) -> IptvItemRecord? {
        guard number > 0 else { return nil }
        let target = UInt32(number)
        if let exact = channels.first(where: { $0.chno == target }) {
            return exact
        }
        if channels.allSatisfy({ $0.chno == nil }), channels.indices.contains(number - 1) {
            return channels[number - 1]
        }
        return nil
    }

    /// The channel `offset` steps away, wrapping around. When the current stream is not in the list
    /// (filtered out, or not a channel) forward goes to the first one and backward to the last.
    func neighbor(of streamUrl: String?, offset: Int) -> IptvItemRecord? {
        guard !channels.isEmpty, offset != 0 else { return nil }
        guard let streamUrl, let index = channels.firstIndex(where: { $0.streamUrl == streamUrl }) else {
            return offset > 0 ? channels.first : channels.last
        }
        let count = channels.count
        return channels[((index + offset) % count + count) % count]
    }

    func nowTitle(forStreamUrl streamUrl: String) -> String? {
        channels.first { $0.streamUrl == streamUrl }.flatMap(programTitle)
    }

    func currentProgramTitle(for channel: IptvItemRecord) -> String? {
        programTitle(channel)
    }
}
