import SwiftUI
import CndCoreBridge

/// Adaptive category picker around a screen's content: a permanent column with counters from
/// 900 pt of width (macOS, iPad landscape), horizontal chips plus a searchable sheet below.
struct CategoryNavigation<Content: View>: View {
    let groups: [FacetCount]
    let totalCount: Int
    var allTitle = "Toutes les catégories"
    @Binding var selection: String?
    @ViewBuilder var content: () -> Content

    @State private var isWide = false
    @State private var showingSheet = false
    @State private var query = ""

    static var wideLayoutThreshold: CGFloat { 900 }
    private static var chipLimit: Int { 40 }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= Self.wideLayoutThreshold
            HStack(spacing: 0) {
                if wide {
                    VStack(spacing: 0) {
                        filterField
                        list
                    }
                    .frame(width: 250)
                    Divider()
                }
                VStack(spacing: 0) {
                    if !wide { chips }
                    content()
                }
            }
            .onChange(of: wide, initial: true) { _, newValue in isWide = newValue }
        }
        .toolbar {
            if !isWide {
                ToolbarItem(placement: .automatic) {
                    Button { showingSheet = true } label: { Label("Catégories", systemImage: "folder") }
                }
            }
        }
        .sheet(isPresented: $showingSheet) { sheet }
    }

    private var filteredGroups: [FacetCount] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return groups }
        return groups.filter { $0.value.localizedCaseInsensitiveContains(needle) }
    }

    private var filterField: some View {
        TextField("Filtrer les catégories", text: $query)
            .textFieldStyle(.roundedBorder)
            .padding(8)
    }

    private var list: some View {
        List(selection: $selection) {
            Label(allTitle, systemImage: "square.grid.2x2")
                .badge(totalCount)
                .tag(String?.none)
            ForEach(filteredGroups, id: \.value) { group in
                Text(group.value)
                    .lineLimit(1)
                    .badge(Int(group.count))
                    .tag(String?.some(group.value))
            }
        }
        .listStyle(.sidebar)
    }

    private var sheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterField
                list.onChange(of: selection) { _, _ in showingSheet = false }
            }
            .navigationTitle("Catégories")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { showingSheet = false } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 420)
        #endif
        .presentationDetents([.medium, .large])
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Toutes", selected: selection == nil) { selection = nil }
                ForEach(groups.prefix(Self.chipLimit), id: \.value) { group in
                    chip("\(group.value) \(group.count)", selected: selection == group.value) {
                        selection = group.value
                    }
                }
                if groups.count > Self.chipLimit {
                    chip("Plus…", selected: false) { showingSheet = true }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.18), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
