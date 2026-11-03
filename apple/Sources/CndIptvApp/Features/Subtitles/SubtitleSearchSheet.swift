import SwiftUI

struct SubtitleSearchSheet: View {
    @State var model: SubtitleSearchModel
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .idle, .searching:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Recherche de « \(model.cleanedTitle) »…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView("Sous-titres", systemImage: "captions.bubble", description: Text(message))
                case .results(let rows):
                    List(rows) { row in
                        Button {
                            Task { await model.download(row) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.release).lineLimit(2)
                                    Text("\(row.language.uppercased()) · \(row.downloads) téléchargements · note \(String(format: "%.1f", row.rating))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.downloadingId == row.fileId { ProgressView().controlSize(.small) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Sous-titres en ligne")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer", action: onClose) } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
        .task { await model.search() }
    }
}
