import SwiftUI
import CndCoreBridge

/// Floating overlay card presented at the end of a movie or episode ("Film suivant" / "Épisode suivant").
public struct NextUpCard: View {
    @Bindable var model: UpNextModel

    public init(model: UpNextModel) {
        self.model = model
    }

    public var body: some View {
        if model.isNextUpCardPresented, let next = model.nextUp {
            cardContent(next: next)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.isNextUpCardPresented)
        }
    }

    @ViewBuilder
    private func cardContent(next: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isPromptingStillWatching {
                stillWatchingPrompt
            } else {
                standardNextUpView(next: next)
            }
        }
        .padding(14)
        .frame(width: 330)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
    }

    @ViewBuilder
    private func standardNextUpView(next: Recommendation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Poster thumbnail
            if let logoUrl = next.item.logoUrl, let url = URL(string: logoUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        placeholderPoster
                    }
                }
                .frame(width: 64, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                placeholderPoster
                    .frame(width: 64, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                // Reason badge & countdown
                HStack(spacing: 6) {
                    Text(next.reasonText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if model.countdownSecondsRemaining < model.countdownDuration {
                        Text("\(model.countdownSecondsRemaining)s")
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }

                Text(next.item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let year = next.item.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }

        // Action buttons
        HStack(spacing: 8) {
            Button {
                model.playNextUp()
            } label: {
                Label("Lire maintenant", systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Button {
                model.dismissForCredits()
            } label: {
                Text("Générique")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var stillWatchingPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Êtes-vous toujours là ?", systemImage: "pause.circle.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("La lecture a été suspendue après 3 enchaînements automatiques.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    model.confirmStillWatchingAndPlay()
                } label: {
                    Text("Continuer")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.cancelAutoPlay()
                } label: {
                    Text("Arrêter")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
    }

    private var placeholderPoster: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "film")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

