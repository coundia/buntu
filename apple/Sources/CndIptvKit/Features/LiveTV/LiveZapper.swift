import Foundation
import CndCoreBridge

/// The channel list currently browsed in Live TV, so the next/previous channel can be reached from
/// anywhere (keyboard, media keys, lock screen) without the Live TV screen being visible.
@MainActor
final class LiveZapper {
    private(set) var channels: [IptvItemRecord] = []
    private var programTitle: (IptvItemRecord) -> String? = { _ in nil }

    func update(channels: [IptvItemRecord], programTitle: @escaping (IptvItemRecord) -> String?) {
        self.channels = channels
        self.programTitle = programTitle
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
}
