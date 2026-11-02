import SwiftUI
import CndCoreBridge

@Observable
@MainActor
public final class SubtitleOverlayModel {
    public var cues: [SubtitleCue] = []
    public var currentText: String = ""
    public var delaySeconds: Double = 0.0
    public var isLoaded: Bool { !cues.isEmpty }

    public init() {}

    public func load(cues: [SubtitleCue]) {
        self.cues = cues.sorted(by: { $0.startMs < $1.startMs })
        self.currentText = ""
    }

    public func clear() {
        self.cues = []
        self.currentText = ""
        self.delaySeconds = 0.0
    }

    public func update(positionMs: Int64) {
        guard !cues.isEmpty else {
            if !currentText.isEmpty { currentText = "" }
            return
        }

        // Apply delay: positive delay means subtitle appears later (so effective position is less)
        let effectiveMs = positionMs - Int64(delaySeconds * 1000)
        if effectiveMs < 0 {
            if !currentText.isEmpty { currentText = "" }
            return
        }

        // Binary search
        var low = 0
        var high = cues.count - 1
        var activeCue: SubtitleCue? = nil

        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if cue.startMs <= effectiveMs && effectiveMs <= cue.endMs {
                activeCue = cue
                break
            } else if cue.startMs > effectiveMs {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        let newText = activeCue?.text ?? ""
        if currentText != newText {
            currentText = newText
        }
    }
}

public struct SubtitleOverlayView: View {
    @Bindable var model: SubtitleOverlayModel

    public init(model: SubtitleOverlayModel) {
        self.model = model
    }

    public var body: some View {
        if !model.currentText.isEmpty {
            VStack {
                Spacer()
                Text(model.currentText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.8), radius: 2, x: 1, y: 1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.bottom, 60)
            }
            .padding(.horizontal, 40)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: model.currentText)
        }
    }
}

