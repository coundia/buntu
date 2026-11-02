import SwiftUI
import Observation

struct Toast: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
    var actionTitle: String?
    var action: (() -> Void)?
}

/// One transient message at a time, shown by the shell above every screen.
@Observable
@MainActor
final class ToastCenter {
    private(set) var current: Toast?

    @ObservationIgnored private let duration: Duration

    init(duration: Duration = .seconds(5)) {
        self.duration = duration
    }

    func show(_ text: String, isError: Bool = false, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let toast = Toast(text: text, isError: isError, actionTitle: actionTitle, action: action)
        current = toast
        let delay = duration
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            if self?.current?.id == toast.id { self?.current = nil }
        }
    }

    func dismiss() { current = nil }
}

struct ToastView: View {
    let toast: Toast
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? .yellow : .green)
            Text(toast.text).font(.callout).lineLimit(3)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    action()
                    onDismiss()
                }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
            }
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Fermer")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
        .padding(.bottom, 16)
    }
}
