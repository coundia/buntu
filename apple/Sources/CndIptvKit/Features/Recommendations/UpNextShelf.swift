import SwiftUI
import CndCoreBridge

public enum ShelfOrientation {
    case vertical
    case horizontal
}

/// Responsive shelf presenting "À suivre" recommendations under the player or in overlay.
public struct UpNextShelf: View {
    @Bindable var model: UpNextModel
    public let orientation: ShelfOrientation
    public let onSelect: (PlayableMedia) -> Void

    public init(
        model: UpNextModel,
        orientation: ShelfOrientation = .vertical,
        onSelect: @escaping (PlayableMedia) -> Void
    ) {
        self.model = model
        self.orientation = orientation
        self.onSelect = onSelect
    }

    public var body: some View {
        if model.isUpNextShelfEnabled && !model.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                headerView

                switch orientation {
                case .vertical:
                    verticalList
                case .horizontal:
                    horizontalShelf
                }
            }
        }
    }

    @ViewBuilder
    private var headerView: some View {
        HStack {
            let title = if let saga = model.sagaInfo {
                "À suivre · Saga \(saga.name)"
            } else {
                "À suivre"
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            if let saga = model.sagaInfo, !saga.missingTitles.isEmpty {
                Text("\(saga.missingTitles.count) titre(s) manquant(s)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var verticalList: some View {
        LazyVStack(spacing: 8) {
            ForEach(model.recommendations, id: \.item.stableHash) { rec in
                cardItem(rec: rec, isHorizontal: false)
            }
        }
    }

    @ViewBuilder
    private var horizontalShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(model.recommendations, id: \.item.stableHash) { rec in
                    cardItem(rec: rec, isHorizontal: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func cardItem(rec: Recommendation, isHorizontal: Bool) -> some View {
        Button {
            if let media = PlayableMedia(item: rec.item) {
                onSelect(media)
            }
        } label: {
            if isHorizontal {
                horizontalCard(rec: rec)
            } else {
                verticalRow(rec: rec)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                if let media = PlayableMedia(item: rec.item) {
                    onSelect(media)
                }
            } label: {
                Label("Lire", systemImage: "play.fill")
            }

            Button(role: .destructive) {
                model.dismissItem(stableHash: rec.item.stableHash)
            } label: {
                Label("Pas intéressé", systemImage: "hand.thumbsdown")
            }
        }
    }

    @ViewBuilder
    private func verticalRow(rec: Recommendation) -> some View {
        HStack(spacing: 10) {
            posterImage(url: rec.item.logoUrl, width: 50, height: 75)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rec.reasonText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(reasonColor(rec.reasonKind))
                        .lineLimit(1)

                    if rec.alreadyWatched {
                        Text("Déjà vu")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }

                Text(rec.item.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let year = rec.item.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func horizontalCard(rec: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                posterImage(url: rec.item.logoUrl, width: 130, height: 190)

                if rec.alreadyWatched {
                    Text("Déjà vu")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(6)
                }
            }

            Text(rec.reasonText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(reasonColor(rec.reasonKind))
                .lineLimit(1)

            Text(rec.item.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: 130, alignment: .leading)
        }
        .frame(width: 130)
    }

    @ViewBuilder
    private func posterImage(url: String?, width: CGFloat, height: CGFloat) -> some View {
        if let urlStr = url, let u = URL(string: urlStr) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let img):
                    img
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    posterPlaceholder(width: width, height: height)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            posterPlaceholder(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func posterPlaceholder(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: "film")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(width: width, height: height)
    }

    private func reasonColor(_ kind: RecommendationReasonKind) -> Color {
        switch kind {
        case .sagaNext, .nextEpisode:
            return .accentColor
        case .resume:
            return .orange
        case .sagaMember:
            return .purple
        case .sameDirector, .sameActor:
            return .blue
        case .similarGenre, .liveNow:
            return .secondary
        }
    }
}

