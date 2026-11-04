#if os(macOS)
import AppKit
import Observation

/// When the main window stays above the other apps' windows (PRD 29).
enum AlwaysOnTopMode: String, CaseIterable, Identifiable {
    case never
    case always
    case whilePlaying

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Jamais"
        case .always: return "Toujours"
        case .whilePlaying: return "Pendant la lecture"
        }
    }
}

/// The rule, free of any window so it is testable: full screen has its own space, where floating is moot.
enum AlwaysOnTopPolicy {
    static func shouldFloat(mode: AlwaysOnTopMode, hasMedia: Bool, isFullscreen: Bool) -> Bool {
        guard !isFullscreen else { return false }
        switch mode {
        case .never: return false
        case .always: return true
        case .whilePlaying: return hasMedia
        }
    }
}

/// Applies `AlwaysOnTopPolicy` to the main window. Switching the level never recreates the window,
/// so playback is not interrupted. The level is `.floating` at most: menus, the Dock and system
/// alerts stay above the app.
@Observable
@MainActor
final class WindowLevelController {
    static let shared = WindowLevelController()

    static let modeKey = "window.alwaysOnTop"
    static let allSpacesKey = "window.allSpaces"

    var mode: AlwaysOnTopMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.modeKey)
            apply()
        }
    }
    /// Follows the user across desktops (Mission Control spaces).
    var showsOnAllSpaces: Bool {
        didSet {
            guard showsOnAllSpaces != oldValue else { return }
            defaults.set(showsOnAllSpaces, forKey: Self.allSpacesKey)
            apply()
        }
    }
    /// Set by the shell: something is loaded in the player (a pause still counts, a stop does not).
    var hasMedia = false {
        didSet {
            guard hasMedia != oldValue else { return }
            leaveCompactIfNoMedia()
            apply()
        }
    }
    private(set) var isFullscreen = false
    /// The compact player (PRD 29, lot 29.2): the window shrinks to the 16:9 video, above the others.
    private(set) var isCompact = false

    static let compactFrameKey = "window.compactFrame"
    static var defaultCompactSize: NSSize { NSSize(width: 480, height: 270) }
    static var minimumCompactSize: NSSize { NSSize(width: 320, height: 180) }

    /// What the window looked like before the compact mode, to put it back.
    private struct SavedLayout {
        var frame: NSRect
        var styleMask: NSWindow.StyleMask
        var titleVisibility: NSWindow.TitleVisibility
        var titlebarTransparent: Bool
        var toolbarVisible: Bool?
        var movableByBackground: Bool
        var aspectRatio: NSSize
        var contentMinSize: NSSize
    }
    @ObservationIgnored private var savedLayout: SavedLayout?

    @ObservationIgnored private let defaults: UserDefaults
    /// Receives the level and the all-spaces flag; replaced in tests so no real window is needed.
    @ObservationIgnored var windowApplier: @MainActor (_ floating: Bool, _ allSpaces: Bool) -> Void
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, observesWindows: Bool = true) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey).flatMap(AlwaysOnTopMode.init(rawValue:)) ?? .never
        showsOnAllSpaces = defaults.bool(forKey: Self.allSpacesKey)
        windowApplier = Self.applyToMainWindow
        guard observesWindows else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setFullscreen(true) }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setFullscreen(false) }
            },
            // A window created after launch (or a new one) takes the current level.
            center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        ]
    }

    var isFloating: Bool {
        AlwaysOnTopPolicy.shouldFloat(mode: mode, hasMedia: hasMedia, isFullscreen: isFullscreen)
    }

    /// Menu, shortcut and pin button: floating on, or off whatever the mode was.
    func toggle() {
        mode = isFloating ? .never : .always
    }

    // MARK: Compact player

    /// Enters or leaves the compact player. Only meaningful while something is loaded.
    func toggleCompact() {
        isCompact ? exitCompact() : enterCompact()
    }

    func enterCompact() {
        guard !isCompact, hasMedia, !isFullscreen, let window = Self.mainWindow() else { return }
        savedLayout = SavedLayout(
            frame: window.frame, styleMask: window.styleMask, titleVisibility: window.titleVisibility,
            titlebarTransparent: window.titlebarAppearsTransparent, toolbarVisible: window.toolbar?.isVisible,
            movableByBackground: window.isMovableByWindowBackground,
            aspectRatio: window.contentAspectRatio, contentMinSize: window.contentMinSize
        )
        isCompact = true
        // The compact player only makes sense above the other windows; it stays on after leaving.
        if mode == .never || (mode == .whilePlaying && !hasMedia) { mode = .always }

        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar?.isVisible = false
        window.isMovableByWindowBackground = true
        window.contentMinSize = Self.minimumCompactSize
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.setFrame(compactFrame(for: window), display: true, animate: true)
    }

    func exitCompact() {
        guard isCompact, let window = Self.mainWindow(), let saved = savedLayout else {
            isCompact = false
            savedLayout = nil
            return
        }
        defaults.set(NSStringFromRect(window.frame), forKey: Self.compactFrameKey)
        window.contentAspectRatio = saved.aspectRatio == .zero ? NSSize(width: 1, height: 1) : saved.aspectRatio
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        window.contentMinSize = saved.contentMinSize
        window.styleMask = saved.styleMask
        window.titleVisibility = saved.titleVisibility
        window.titlebarAppearsTransparent = saved.titlebarTransparent
        if let visible = saved.toolbarVisible { window.toolbar?.isVisible = visible }
        window.isMovableByWindowBackground = saved.movableByBackground
        window.setFrame(saved.frame, display: true, animate: true)
        isCompact = false
        savedLayout = nil
    }

    /// The remembered compact frame (if still on a screen), else the default size in the bottom-right corner.
    private func compactFrame(for window: NSWindow) -> NSRect {
        if let text = defaults.string(forKey: Self.compactFrameKey) {
            let remembered = NSRectFromString(text)
            if remembered.width >= Self.minimumCompactSize.width,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(remembered) }) {
                return remembered
            }
        }
        let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.defaultCompactSize
        return NSRect(x: area.maxX - size.width - 24, y: area.minY + 24, width: size.width, height: size.height)
    }

    /// The media is gone: nothing to keep compact.
    private func leaveCompactIfNoMedia() {
        if !hasMedia && isCompact { exitCompact() }
    }

    func setFullscreen(_ value: Bool) {
        guard value != isFullscreen else { return }
        isFullscreen = value
        apply()
    }

    func apply() {
        windowApplier(isFloating, showsOnAllSpaces)
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
    }

    private static func applyToMainWindow(floating: Bool, allSpaces: Bool) {
        guard let window = mainWindow() else { return }
        apply(to: window, floating: floating, allSpaces: allSpaces)
    }

    static func apply(to window: NSWindow, floating: Bool, allSpaces: Bool) {
        window.level = floating ? .floating : .normal
        var behavior = window.collectionBehavior
        if floating && allSpaces { behavior.insert(.canJoinAllSpaces) } else { behavior.remove(.canJoinAllSpaces) }
        window.collectionBehavior = behavior
    }
}
#endif
