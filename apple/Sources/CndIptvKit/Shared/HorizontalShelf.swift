import SwiftUI

/// A horizontal row of cards. A mouse wheel cannot scroll sideways on a Mac, so macOS adds
/// arrows that step through the cards; the trackpad and touch screens scroll as usual.
struct HorizontalShelf<Item, Card: View>: View {
    let items: [Item]
    var spacing: CGFloat = 12
    var alignment: VerticalAlignment = .center
    @ViewBuilder var card: (Item) -> Card

    @Environment(\.uiMetrics) private var ui
    @State private var index = 0
    private static var step: Int { 3 }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 4) {
                #if os(macOS)
                arrow("chevron.left", "Précédents") {
                    index = max(0, index - Self.step)
                    withAnimation { proxy.scrollTo(index, anchor: .leading) }
                }
                #endif
                ScrollView(.horizontal, showsIndicators: false) {
                    row
                        .padding(.vertical, 2)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                #if os(macOS)
                arrow("chevron.right", "Suivants") {
                    index = min(max(0, items.count - 1), index + Self.step)
                    withAnimation { proxy.scrollTo(index, anchor: .leading) }
                }
                #endif
            }
        }
    }

    /// A shelf holds a few dozen cards: an eager row keeps every one of them alive. A lazy row inside
    /// two nested scroll views stops realising cards on a narrow screen, so some favourites vanish
    /// until they are scrolled to; only a very long shelf is left lazy.
    static var eagerLimit: Int { 120 }

    @ViewBuilder
    private var row: some View {
        if items.count <= Self.eagerLimit {
            HStack(alignment: alignment, spacing: spacing) { cards }
        } else {
            LazyHStack(alignment: alignment, spacing: spacing) { cards }
        }
    }

    @ViewBuilder
    private var cards: some View {
        ForEach(items.indices, id: \.self) { position in
            card(items[position]).id(position)
        }
    }

    #if os(macOS)
    private func arrow(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(ui.font(.body, weight: .semibold))
                .frame(width: ui.value(24), height: max(ui.value(40), ui.minHitTarget))
        }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .help(label)
    }
    #endif
}
