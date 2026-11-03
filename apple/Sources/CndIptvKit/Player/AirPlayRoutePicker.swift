import AVKit
import SwiftUI

/// System AirPlay route button (Apple TV, AirPlay 2 speakers and TVs).
#if os(macOS)
struct AirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
#elseif os(visionOS)
/// Vision Pro has no AirPlay route button: the system picks the output.
struct AirPlayRoutePicker: View {
    var body: some View { EmptyView() }
}
#else
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
