import SwiftUI
import CndCoreBridge

/// Compact bottom audio playback bar embedded above the tab bar / dock.
public struct AudioPlayerBar: View {
    @Bindable var model: LibraryModel
    @State private var showingExpandedNowPlaying = false

    public init(model: LibraryModel) {
        self.model = model
    }

    public var body: some View {
        if let current = model.nowPlayingAudio {
            VStack(spacing: 0) {
                // Progress line
                GeometryReader { geo in
                    let fraction = model.audioDuration > 0 ? (model.audioCurrentTime / model.audioDuration) : 0
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.1))
                            .frame(height: 2)
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(fraction), height: 2)
                    }
                }
                .frame(height: 2)

                HStack(spacing: 12) {
                    // Artwork
                    Group {
                        if let thumb = current.thumbnailPath,
                           let image = platformImage(path: thumb) {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 42, height: 42)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    // Title & Artist
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title ?? URL(fileURLWithPath: current.relPath).lastPathComponent)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Text(current.artist ?? current.album ?? "Musique")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Controls
                    HStack(spacing: 16) {
                        Button {
                            model.toggleAudioPlayPause()
                        } label: {
                            Image(systemName: model.isAudioPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20))
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.nextAudio()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.stopAudio()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .contentShape(Rectangle())
                .onTapGesture {
                    showingExpandedNowPlaying = true
                }
            }
            .sheet(isPresented: $showingExpandedNowPlaying) {
                NowPlayingAudioView(model: model)
            }
        }
    }

    private func platformImage(path: String) -> Image? {
        #if canImport(AppKit)
        if let nsImage = NSImage(contentsOfFile: path) {
            return Image(nsImage: nsImage)
        }
        #elseif canImport(UIKit)
        if let uiImage = UIImage(contentsOfFile: path) {
            return Image(uiImage: uiImage)
        }
        #endif
        return nil
    }
}

/// Expanded full now playing sheet for audio.
public struct NowPlayingAudioView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel

    public init(model: LibraryModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Artwork
                Group {
                    if let thumb = model.nowPlayingAudio?.thumbnailPath,
                       let image = platformImage(path: thumb) {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.secondary.opacity(0.15))
                            Image(systemName: "music.note")
                                .font(.system(size: 80))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: 320, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 10)

                // Info
                VStack(spacing: 6) {
                    Text(model.nowPlayingAudio?.title ?? "Piste audio")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    Text(model.nowPlayingAudio?.artist ?? "Artiste inconnu")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    if let album = model.nowPlayingAudio?.album {
                        Text(album)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 24)

                // Progress Slider
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { model.audioDuration > 0 ? model.audioCurrentTime / model.audioDuration : 0 },
                            set: { model.seekAudio(toFraction: $0) }
                        )
                    )
                    .tint(.accentColor)

                    HStack {
                        Text(formatDuration(seconds: model.audioCurrentTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatDuration(seconds: model.audioDuration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 32)

                // Playback Controls
                HStack(spacing: 36) {
                    Button {
                        model.isShuffleEnabled.toggle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.title3)
                            .foregroundStyle(model.isShuffleEnabled ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.previousAudio()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.toggleAudioPlayPause()
                    } label: {
                        Image(systemName: model.isAudioPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.nextAudio()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.isRepeatEnabled.toggle()
                    } label: {
                        Image(systemName: "repeat")
                            .font(.title3)
                            .foregroundStyle(model.isRepeatEnabled ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 8)

                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    private func formatDuration(seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func platformImage(path: String) -> Image? {
        #if canImport(AppKit)
        if let nsImage = NSImage(contentsOfFile: path) {
            return Image(nsImage: nsImage)
        }
        #elseif canImport(UIKit)
        if let uiImage = UIImage(contentsOfFile: path) {
            return Image(uiImage: uiImage)
        }
        #endif
        return nil
    }
}

