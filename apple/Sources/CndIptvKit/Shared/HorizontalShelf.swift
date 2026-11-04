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
                    LazyHStack(alignment: alignment, spacing: spacing) {
                        ForEach(items.indices, id: \.self) { position in
                            card(items[position]).id(position)
                        }
                    }
                }
                #if os(macOS)
                arrow("chevron.right", "Suivants") {
                    index = min(max(0, items.count - 1), index + Self.step)
                    withAnimation { proxy.scrollTo(index, anchor: .leading) }
                }
                #endif
            }
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
