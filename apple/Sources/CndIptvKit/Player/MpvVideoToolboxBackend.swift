import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
// Not on macOS: linking libmpv statically there duplicates a Rust runtime symbol with the core
// (libdovi); the Mac finds libmpv through dlopen (Homebrew or the embedded framework) instead.
#if canImport(Libmpv) && !os(macOS)
import Libmpv
#endif

// MARK: - libmpv loaded at runtime

/// `libmpv` (LGPL build) resolved with `dlopen`/`dlsym`, so the app compiles and links on macOS and
/// iOS Simulator without the library. When it is missing, `MpvLibrary.shared` is `nil` and the
/// controller keeps using `AVPlayer`.
final class MpvLibrary: @unchecked Sendable {
    typealias Handle = OpaquePointer
    typealias CreateFn = @convention(c) () -> OpaquePointer?
    typealias InitFn = @convention(c) (OpaquePointer?) -> Int32
    typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
    typealias SetStringFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    typealias CommandFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    typealias GetStringFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    typealias FreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias WaitEventFn = @convention(c) (OpaquePointer?, Double) -> UnsafeMutableRawPointer?
    typealias ErrorStringFn = @convention(c) (Int32) -> UnsafePointer<CChar>?
    typealias RequestLogFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    /// `mpv_set_option` with a typed value (here `MPV_FORMAT_INT64` for `wid`).
    typealias SetOptionRawFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Int32
    typealias RenderCreateFn = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
    typealias RenderRenderFn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
    typealias RenderFreeFn = @convention(c) (OpaquePointer?) -> Void
    typealias RenderUpdateFn = @convention(c) (OpaquePointer?) -> UInt64
    typealias UpdateCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias RenderSetCallbackFn = @convention(c) (OpaquePointer?, UpdateCallback?, UnsafeMutableRawPointer?) -> Void

    let create: CreateFn
    let initialize: InitFn
    let terminateDestroy: DestroyFn
    let setOption: SetStringFn
    let setProperty: SetStringFn
    let command: CommandFn
    let getProperty: GetStringFn
    let free: FreeFn
    let waitEvent: WaitEventFn
    let errorString: ErrorStringFn?
    /// `mpv_request_log_messages`: mpv's own warnings and errors, shown in the app's console.
    let requestLog: RequestLogFn?
    let setOptionRaw: SetOptionRawFn?
    let renderCreate: RenderCreateFn
    let renderRender: RenderRenderFn
    let renderFree: RenderFreeFn
    let renderUpdate: RenderUpdateFn
    let renderSetCallback: RenderSetCallbackFn

    static let shared: MpvLibrary? = MpvLibrary()

    static var isAvailable: Bool { shared != nil }

    private static var candidatePaths: [String] {
        var paths: [String] = []
        if let frameworks = Bundle.main.privateFrameworksPath {
            paths.append(frameworks + "/Libmpv.framework/Libmpv")
            paths.append(frameworks + "/libmpv.2.dylib")
            paths.append(frameworks + "/libmpv.dylib")
        }
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            paths.append(executableDir + "/Frameworks/Libmpv.framework/Libmpv")
            paths.append(executableDir + "/libmpv.2.dylib")
        }
        paths.append("libmpv.2.dylib")
        paths.append("@rpath/Libmpv.framework/Libmpv")
        #if os(macOS)
        paths.append(contentsOf: [
            "/opt/homebrew/lib/libmpv.2.dylib",
            "/usr/local/lib/libmpv.2.dylib",
        ])
        #endif
        return paths
    }

    /// The entry points of libmpv, from whichever source provided them.
    private struct Symbols {
        let create: CreateFn
        let initialize: InitFn
        let destroy: DestroyFn
        let setOption: SetStringFn
        let setProperty: SetStringFn
        let command: CommandFn
        let getProperty: GetStringFn
        let free: FreeFn
        let waitEvent: WaitEventFn
        let errorString: ErrorStringFn?
        let requestLog: RequestLogFn?
        let setOptionRaw: SetOptionRawFn?
        let renderCreate: RenderCreateFn
        let renderRender: RenderRenderFn
        let renderFree: RenderFreeFn
        let renderUpdate: RenderUpdateFn
        let renderSetCallback: RenderSetCallbackFn
    }

    /// Reads the entry points from a loaded library (`dlsym`).
    private static func symbols(in lib: UnsafeMutableRawPointer) -> Symbols? {
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let raw = dlsym(lib, name) else { return nil }
            return unsafeBitCast(raw, to: type)
        }
        guard
            let create = symbol("mpv_create", as: CreateFn.self),
            let initialize = symbol("mpv_initialize", as: InitFn.self),
            let destroy = symbol("mpv_terminate_destroy", as: DestroyFn.self),
            let setOption = symbol("mpv_set_option_string", as: SetStringFn.self),
            let setProperty = symbol("mpv_set_property_string", as: SetStringFn.self),
            let command = symbol("mpv_command", as: CommandFn.self),
            let getProperty = symbol("mpv_get_property_string", as: GetStringFn.self),
            let free = symbol("mpv_free", as: FreeFn.self),
            let waitEvent = symbol("mpv_wait_event", as: WaitEventFn.self),
            let renderCreate = symbol("mpv_render_context_create", as: RenderCreateFn.self),
            let renderRender = symbol("mpv_render_context_render", as: RenderRenderFn.self),
            let renderFree = symbol("mpv_render_context_free", as: RenderFreeFn.self),
            let renderUpdate = symbol("mpv_render_context_update", as: RenderUpdateFn.self),
            let renderSetCallback = symbol("mpv_render_context_set_update_callback", as: RenderSetCallbackFn.self)
        else { return nil }
        return Symbols(
            create: create, initialize: initialize, destroy: destroy, setOption: setOption, setProperty: setProperty,
            command: command, getProperty: getProperty, free: free, waitEvent: waitEvent,
            errorString: symbol("mpv_error_string", as: ErrorStringFn.self),
            requestLog: symbol("mpv_request_log_messages", as: RequestLogFn.self),
            setOptionRaw: symbol("mpv_set_option", as: SetOptionRawFn.self),
            renderCreate: renderCreate, renderRender: renderRender, renderFree: renderFree,
            renderUpdate: renderUpdate, renderSetCallback: renderSetCallback
        )
    }

    #if canImport(Libmpv) && !os(macOS)
    /// libmpv linked into the app (MPVKit ships it as a static library on iOS, tvOS and visionOS).
    /// Naming the functions here is what keeps them in the executable: with `dlsym` alone the linker
    /// finds no reference, drops them, and the app reports "libmpv introuvable" on the iPhone.
    private static func linkedSymbols() -> Symbols {
        // Each function is first stored as a C function pointer of its exact imported type (8 bytes):
        // a bare `mpv_create` passed to `unsafeBitCast` is a Swift closure (16 bytes) and traps at run time.
        let create: CreateFn = mpv_create
        let initialize: InitFn = mpv_initialize
        let destroy: DestroyFn = mpv_terminate_destroy
        let setOption: SetStringFn = mpv_set_option_string
        let setProperty: SetStringFn = mpv_set_property_string
        let command: CommandFn = mpv_command
        let getProperty: GetStringFn = mpv_get_property_string
        let free: FreeFn = mpv_free
        let wait: @convention(c) (OpaquePointer?, Double) -> UnsafeMutablePointer<mpv_event>? = mpv_wait_event
        let errorString: ErrorStringFn = mpv_error_string
        let requestLog: RequestLogFn = mpv_request_log_messages
        let setOptionRaw: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32 = mpv_set_option
        let renderCreate: @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, OpaquePointer?, UnsafeMutablePointer<mpv_render_param>?) -> Int32 = mpv_render_context_create
        let renderRender: @convention(c) (OpaquePointer?, UnsafeMutablePointer<mpv_render_param>?) -> Int32 = mpv_render_context_render
        let renderFree: RenderFreeFn = mpv_render_context_free
        let renderUpdate: RenderUpdateFn = mpv_render_context_update
        let renderSetCallback: RenderSetCallbackFn = mpv_render_context_set_update_callback
        return Symbols(
            create: create, initialize: initialize, destroy: destroy, setOption: setOption, setProperty: setProperty,
            command: command, getProperty: getProperty, free: free,
            waitEvent: unsafeBitCast(wait, to: WaitEventFn.self),
            errorString: errorString, requestLog: requestLog,
            setOptionRaw: unsafeBitCast(setOptionRaw, to: SetOptionRawFn.self),
            renderCreate: unsafeBitCast(renderCreate, to: RenderCreateFn.self),
            renderRender: unsafeBitCast(renderRender, to: RenderRenderFn.self),
            renderFree: renderFree, renderUpdate: renderUpdate, renderSetCallback: renderSetCallback
        )
    }
    #endif

    private init?() {
        var found: Symbols?
        #if canImport(Libmpv) && !os(macOS)
        // Linked statically: no search needed.
        found = Self.linkedSymbols()
        #else
        // 1. If libmpv is already in the process (linked dynamically), 2. else search the usual places.
        if let processHandle = dlopen(nil, RTLD_NOW | RTLD_LOCAL), let table = Self.symbols(in: processHandle) {
            found = table
        } else {
            for path in Self.candidatePaths {
                if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                    if let table = Self.symbols(in: handle) {
                        found = table
                        break
                    }
                    dlclose(handle)
                }
            }
        }
        #endif
        guard let table = found else { return nil }
        self.create = table.create
        self.initialize = table.initialize
        self.terminateDestroy = table.destroy
        self.setOption = table.setOption
        self.setProperty = table.setProperty
        self.command = table.command
        self.getProperty = table.getProperty
        self.free = table.free
        self.waitEvent = table.waitEvent
        self.errorString = table.errorString
        self.requestLog = table.requestLog
        self.setOptionRaw = table.setOptionRaw
        self.renderCreate = table.renderCreate
        self.renderRender = table.renderRender
        self.renderFree = table.renderFree
        self.renderUpdate = table.renderUpdate
        self.renderSetCallback = table.renderSetCallback
    }
}

// MARK: - Software render target -> AVSampleBufferDisplayLayer

/// Renders mpv frames (render API, software target) into `CVPixelBuffer`s displayed by an
/// `AVSampleBufferDisplayLayer`. Runs on its own serial queue, never on the main thread.
final class MpvRenderer: @unchecked Sendable {
    private struct RenderParam {
        var type: Int32
        var data: UnsafeMutableRawPointer?
    }
    private static let paramInvalid: Int32 = 0
    private static let paramAPIType: Int32 = 1
    private static let paramSWSize: Int32 = 17
    private static let paramSWFormat: Int32 = 18
    private static let paramSWStride: Int32 = 19
    private static let paramSWPointer: Int32 = 20
    private static let updateFrameFlag: UInt64 = 1

    let layer = AVSampleBufferDisplayLayer()
    private let library: MpvLibrary
    private let queue = DispatchQueue(label: "cnd.mpv.render", qos: .userInteractive)
    private let lock = NSLock()
    private var context: OpaquePointer?
    private var videoSize = CGSize.zero
    private var stopped = false

    init(library: MpvLibrary) {
        self.library = library
        layer.videoGravity = .resizeAspect
    }

    /// Must be called after `mpv_initialize` with `vo=libmpv`.
    func attach(to mpv: OpaquePointer) -> Bool {
        var ctx: OpaquePointer?
        var apiType = Array("sw".utf8CString)
        let created: Int32 = apiType.withUnsafeMutableBytes { apiBytes in
            var params = [
                RenderParam(type: Self.paramAPIType, data: apiBytes.baseAddress),
                RenderParam(type: Self.paramInvalid, data: nil),
            ]
            return params.withUnsafeMutableBytes { paramBytes in
                library.renderCreate(&ctx, mpv, paramBytes.baseAddress)
            }
        }
        guard created >= 0, let ctx else { return false }
        lock.lock()
        context = ctx
        lock.unlock()
        library.renderSetCallback(ctx, { raw in
            guard let raw else { return }
            Unmanaged<MpvRenderer>.fromOpaque(raw).takeUnretainedValue().scheduleRender()
        }, Unmanaged.passUnretained(self).toOpaque())
        return true
    }

    func setVideoSize(width: Int, height: Int) {
        lock.lock()
        videoSize = CGSize(width: width, height: height)
        lock.unlock()
    }

    func scheduleRender() {
        queue.async { [weak self] in self?.renderPendingFrame() }
    }

    private func renderPendingFrame() {
        lock.lock()
        let ctx = stopped ? nil : context
        let size = videoSize
        lock.unlock()
        guard let ctx else { return }

        let flags = library.renderUpdate(ctx)
        guard flags & Self.updateFrameFlag != 0, size.width >= 2, size.height >= 2 else { return }

        let width = Int(size.width), height = Int(size.height)
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        var dims: [Int32] = [Int32(width), Int32(height)]
        var stride = CVPixelBufferGetBytesPerRow(buffer)
        var format = Array("bgr0".utf8CString)
        let base = CVPixelBufferGetBaseAddress(buffer)
        dims.withUnsafeMutableBytes { dimBytes in
            format.withUnsafeMutableBytes { formatBytes in
                withUnsafeMutablePointer(to: &stride) { stridePtr in
                    var params = [
                        RenderParam(type: Self.paramSWSize, data: dimBytes.baseAddress),
                        RenderParam(type: Self.paramSWFormat, data: formatBytes.baseAddress),
                        RenderParam(type: Self.paramSWStride, data: UnsafeMutableRawPointer(stridePtr)),
                        RenderParam(type: Self.paramSWPointer, data: base),
                        RenderParam(type: Self.paramInvalid, data: nil),
                    ]
                    params.withUnsafeMutableBytes { _ = library.renderRender(ctx, $0.baseAddress) }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        enqueue(buffer)
    }

    private func enqueue(_ buffer: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    /// Stops callbacks and frees the render context; must run before `mpv_terminate_destroy`.
    func stop() {
        lock.lock()
        stopped = true
        let ctx = context
        context = nil
        lock.unlock()
        guard let ctx else { return }
        library.renderSetCallback(ctx, nil, nil)
        queue.sync { library.renderFree(ctx) }
    }
}

// MARK: - Metal surface (iPhone, iPad, Apple TV, Vision Pro)

#if canImport(Libmpv) && !os(macOS)
/// The layer mpv's `gpu-next` output draws into (Vulkan over Metal through MoltenVK): the picture is
/// decoded and scaled by the GPU, which software rendering could not do for a 4K HEVC film.
final class MpvMetalLayer: CAMetalLayer {
    // MoltenVK sets the drawable to 1×1 to force a presentation: it flickers and can stay there
    // (mpv-player/mpv#13651). Keep the real size.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue }
        }
    }
}

/// The player's layer: the Metal surface over the software one (shown only if `gpu-next` cannot start).
final class MpvSurfaceLayer: CALayer {
    let metal = MpvMetalLayer()
    let fallback: CALayer

    init(fallback: CALayer) {
        self.fallback = fallback
        super.init()
        backgroundColor = CGColor(gray: 0, alpha: 1)
        metal.framebufferOnly = true
        metal.isOpaque = false
        metal.backgroundColor = nil
        addSublayer(fallback)
        addSublayer(metal)
    }

    override init(layer: Any) {
        fallback = (layer as? MpvSurfaceLayer)?.fallback ?? CALayer()
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = superlayer?.contentsScale ?? contentsScale
        metal.contentsScale = max(scale, 1)
        fallback.frame = bounds
        metal.frame = bounds
        CATransaction.commit()
    }

    /// `gpu-next` did not start: show the software picture underneath.
    func useFallback() {
        guard !metal.isHidden else { return }
        metal.isHidden = true
    }
}
#endif

// MARK: - Backend

/// Universal engine: decodes `.ts`, `.mkv`, `.avi`, HEVC, AC3/DTS, ASS/PGS subtitles via `libmpv`
/// with `VideoToolbox` hardware decoding.
@MainActor
public final class MpvVideoToolboxBackend: VideoBackend {
    public static var isLibraryAvailable: Bool { MpvLibrary.isAvailable }

    /// Address mpv reads instead of a film's or an episode's own (the engine's single-connection relay:
    /// a one-connection subscription refuses the second connection mpv opens on each seek). `nil`, or a
    /// `nil` answer, keeps the original address.
    public static var addressRewriter: ((PlayableMedia) -> URL?)?

    public let engineKind: PlayerEngineKind = .mpv
    public var displayLayer: CALayer { surface ?? renderer?.layer ?? placeholderLayer }
    public private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: ((PlaybackState) -> Void)?
    public var onTracksChange: (() -> Void)?
    public var timeshiftDuration: TimeshiftDuration = .oneHour

    private let library: MpvLibrary?
    private let renderer: MpvRenderer?
    private let placeholderLayer = CALayer()
    /// Metal surface (GPU rendering) when this platform and libmpv build have it, else `nil`.
    private let surface: CALayer?
    private var handle: OpaquePointer?
    private var pollTask: Task<Void, Never>?
    private var loaded = false
    private var cachedPositionMs: Int64 = 0
    private var cachedDurationMs: Int64 = 0
    private var isTornDown = false

    public init() {
        library = MpvLibrary.shared
        let renderer = library.map { MpvRenderer(library: $0) }
        self.renderer = renderer
        #if canImport(Libmpv) && !os(macOS)
        if let renderer, library?.setOptionRaw != nil {
            surface = MpvSurfaceLayer(fallback: renderer.layer)
        } else {
            surface = nil
        }
        #else
        surface = nil
        #endif
    }

    public var positionMs: Int64 { cachedPositionMs }
    public var durationMs: Int64 { cachedDurationMs }

    /// Value of `hwdec-current` (`videotoolbox`, `videotoolbox-copy` or `no`), for diagnostics.
    public var currentHardwareDecoder: String? { property("hwdec-current") }

    // MARK: mpv helpers

    private func option(_ name: String, _ value: String) {
        guard let library, let handle else { return }
        _ = library.setOption(handle, name, value)
    }

    private func setProperty(_ name: String, _ value: String) {
        guard let library, let handle else { return }
        _ = library.setProperty(handle, name, value)
    }

    /// `container-fps`, then `estimated-vf-fps` (measured: the reliable one for MPEG-TS), with the transfer
    /// function and primaries that tell SDR from HDR10 / HLG.
    public func currentVideoFormat() -> VideoFormatReading? {
        var fps = Double(property("container-fps") ?? "") ?? 0
        if fps <= 0 { fps = Double(property("estimated-vf-fps") ?? "") ?? 0 }
        guard fps > 0 else { return nil }
        return VideoFormatReading(
            fps: fps, gamma: property("video-params/gamma"), primaries: property("video-params/primaries"),
            width: property("video-params/w").flatMap(Int.init), height: property("video-params/h").flatMap(Int.init)
        )
    }

    public func networkReading() -> NetworkReading? {
        guard loaded else { return nil }
        let speed = Double(property("cache-speed") ?? "") ?? 0
        let size = Double(property("file-size") ?? "") ?? 0
        let duration = Double(property("duration") ?? "") ?? 0
        let bitrate: Double? = size > 0 && duration > 0 ? size * 8 / duration : nil
        // `demuxer-cache-idle` is "yes" once the cache is full: the speed then drops for no network reason.
        let downloading = property("demuxer-cache-idle") != "yes"
        return NetworkReading(downloadBytesPerSecond: speed, fileBitsPerSecond: bitrate, isDownloading: downloading)
    }

    private func property(_ name: String) -> String? {
        guard let library, let handle, let raw = library.getProperty(handle, name) else { return nil }
        defer { library.free(raw) }
        return String(cString: raw)
    }

    private func run(_ args: [String]) {
        guard let library, let handle else { return }
        let cStrings = args.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) } + [nil]
        pointers.withUnsafeMutableBufferPointer { _ = library.command(handle, $0.baseAddress) }
    }

    /// mpv list syntax: `%<byte length>%<value>` keeps commas inside a header value intact.
    nonisolated static func encodeHeaderFields(_ headers: [(name: String, value: String)]) -> String {
        headers
            .filter { $0.name.lowercased() != "user-agent" && $0.name.lowercased() != "referer" }
            .map { "\($0.name): \($0.value)" }
            .map { "%\($0.utf8.count)%\($0)" }
            .joined(separator: ",")
    }

    // MARK: VideoBackend

    public func load(_ media: PlayableMedia, startPositionMs: Int64) {
        guard !isTornDown else { return }
        guard let library, let renderer else {
            state = .failed("libmpv is not available on this device")
            return
        }
        if handle == nil {
            guard let created = library.create() else {
                state = .failed("mpv_create failed")
                return
            }
            handle = created
            configure(for: media)
            guard library.initialize(created) >= 0 else {
                library.terminateDestroy(created)
                handle = nil
                state = .failed("mpv_initialize failed")
                return
            }
            // mpv's warnings and errors go to the app's console (PLAYER > MPV): the only way to know
            // why a file does not play on a device.
            _ = library.requestLog?(created, "warn")
            // The software render context is the output itself without Metal, and the fallback with it.
            if !renderer.attach(to: created), surface == nil {
                library.terminateDestroy(created)
                handle = nil
                state = .failed("mpv render context unavailable")
                return
            }
            startPolling()
        }

        loaded = false
        cachedPositionMs = max(0, startPositionMs)
        cachedDurationMs = 0
        state = .loading
        setProperty("start", startPositionMs > 0 ? String(format: "%.3f", Double(startPositionMs) / 1000) : "none")
        var address = media.url
        if media.kind != .live, let relayed = Self.addressRewriter?(media), relayed != media.url {
            address = relayed
            AppLog.shared.info("PLAYER", "Lecture par le relais local : une seule connexion au serveur à la fois")
        }
        run(["loadfile", address.absoluteString, "replace"])
    }

    /// Mandatory options: hardware decoding, large demuxer cache, live low-latency profile and
    /// exact propagation of `user-agent`, `referrer` and `http-header-fields`.
    private func configure(for media: PlayableMedia) {
        option("config", "no")
        option("terminal", "no")
        option("idle", "yes")
        option("input-default-bindings", "no")
        option("ytdl", "no")
        option("vo", "libmpv")
        // AVFoundation output follows the system's output device when it changes (headphones, AirPods, HDMI);
        // CoreAudio stays as the fallback if this libmpv build lacks it.
        #if os(macOS)
        option("ao", "avfoundation,coreaudio")
        #else
        // iOS, tvOS, visionOS: `audiounit` is mpv's output there; `avfoundation` when this build has it.
        option("ao", "audiounit,avfoundation")
        #endif
        // The software render target cannot import zero-copy `videotoolbox` frames, so mpv falls
        // through to `videotoolbox-copy` (still GPU/media-engine decoding, one copy to RAM).
        option("hwdec", "videotoolbox,videotoolbox-copy")
        #if canImport(Libmpv) && !os(macOS)
        if let metalSurface = surface as? MpvSurfaceLayer, let library, let handle, let setRaw = library.setOptionRaw {
            // GPU output into the Metal layer; `libmpv` (software) only if Vulkan cannot start.
            var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(metalSurface.metal).toOpaque()))
            let format: Int32 = 4 // MPV_FORMAT_INT64
            _ = withUnsafeMutablePointer(to: &wid) { setRaw(handle, "wid", format, UnsafeMutableRawPointer($0)) }
            option("vo", "gpu-next,libmpv")
            option("gpu-api", "vulkan")
            option("gpu-context", "moltenvk")
            option("hwdec", "videotoolbox,videotoolbox-copy")
            #if os(iOS)
            // Lighter scalers: a 4K film on a phone keeps its frame rate.
            option("profile", "fast")
            #endif
        }
        #endif
        option("cache", "yes")
        option("demuxer-max-bytes", "64MiB")
        if media.kind != .live {
            // A film on a slow single connection: read far ahead, and once the cache runs dry, resume
            // only with several seconds in hand instead of stopping every second.
            #if os(macOS)
            option("demuxer-max-bytes", "512MiB")
            #else
            option("demuxer-max-bytes", "200MiB")
            #endif
            option("demuxer-max-back-bytes", "32MiB")
            option("demuxer-readahead-secs", "120")
            option("cache-secs", "120")
            option("cache-pause-wait", "6")
            option("cache-pause-initial", "yes")
            // A dropped connection resumes where it stopped (through the relay: same provider session).
            option("stream-lavf-o", "reconnect=1,reconnect_on_network_error=1,reconnect_delay_max=4")
        }
        if media.kind == .live {
            option("cache-secs", "3")
            option("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=2")
            if timeshiftDuration.isEnabled {
                let cacheDir = TimeshiftCacheManager.ensureCacheDirectory()
                option("demuxer-seekable-cache", "yes")
                option("demuxer-max-bytes", timeshiftDuration.maxBytes)
                option("demuxer-max-back-bytes", timeshiftDuration.maxBackBytes)
                option("demuxer-cache-dir", cacheDir)
            }
        }
        if let ua = media.userAgent { option("user-agent", ua) }
        if let referer = media.referer { option("referrer", referer) }
        let fields = Self.encodeHeaderFields(media.orderedHeaders)
        if !fields.isEmpty { option("http-header-fields", fields) }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollOnce()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func pollOnce() {
        guard let library, let handle, !isTornDown else { return }
        while let event = library.waitEvent(handle, 0) {
            let id = event.load(as: Int32.self)
            if id == 0 { break }
            switch id {
            case 8: // MPV_EVENT_FILE_LOADED
                loaded = true
                onTracksChange?()
            case 7: // MPV_EVENT_END_FILE
                if let data = event.load(fromByteOffset: 16, as: UnsafeMutableRawPointer?.self) {
                    let reason = data.load(as: Int32.self)
                    let error = data.load(fromByteOffset: 4, as: Int32.self)
                    if reason == 4 {
                        let text = library.errorString?(error).map { String(cString: $0) } ?? "error \(error)"
                        state = .failed("mpv: \(text)")
                    } else if reason == 0 {
                        state = .ended
                    }
                }
            case 2: // MPV_EVENT_LOG_MESSAGE: { prefix, level, text, log_level }
                if let data = event.load(fromByteOffset: 16, as: UnsafeMutableRawPointer?.self) {
                    let prefix = data.load(as: UnsafePointer<CChar>?.self).map { String(cString: $0) } ?? "mpv"
                    let level = data.load(fromByteOffset: 8, as: UnsafePointer<CChar>?.self).map { String(cString: $0) } ?? ""
                    let text = data.load(fromByteOffset: 16, as: UnsafePointer<CChar>?.self).map { String(cString: $0) } ?? ""
                    let line = "[\(prefix)] \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
                    if level == "error" || level == "fatal" {
                        AppLog.shared.error("MPV", line)
                    } else {
                        AppLog.shared.warn("MPV", line)
                    }
                }
            case 1: // MPV_EVENT_SHUTDOWN
                return
            default:
                break
            }
        }

        guard loaded else { return }
        #if canImport(Libmpv) && !os(macOS)
        if let metalSurface = surface as? MpvSurfaceLayer, !metalSurface.metal.isHidden, property("current-vo") == "libmpv" {
            metalSurface.useFallback()
            AppLog.shared.warn("PLAYER", "Rendu GPU (Metal) indisponible : rendu logiciel, plus lent")
        }
        #endif
        if let seconds = property("time-pos").flatMap(Double.init) {
            cachedPositionMs = Int64(max(0, seconds) * 1000)
        }
        if let seconds = property("duration").flatMap(Double.init), seconds > 0 {
            cachedDurationMs = Int64(seconds * 1000)
        }
        if let w = property("dwidth").flatMap(Int.init), let h = property("dheight").flatMap(Int.init) {
            renderer?.setVideoSize(width: w, height: h)
        }
        guard state != .ended, !isFailed else { return }
        let paused = property("pause") == "yes"
        let buffering = property("paused-for-cache") == "yes" || property("core-idle") == "yes"
        state = paused ? .paused : (buffering ? .buffering : .playing)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    public func play() { setProperty("pause", "no") }
    public func pause() { setProperty("pause", "yes") }

    public func seek(toMs positionMs: Int64) {
        run(["seek", String(format: "%.3f", Double(max(0, positionMs)) / 1000), "absolute"])
    }

    public func setRate(_ rate: Float) { setProperty("speed", String(rate)) }
    public func setVolume(_ volume: Float) { setProperty("volume", String(Int(min(max(volume, 0), 1) * 100))) }
    public func setMuted(_ muted: Bool) { setProperty("mute", muted ? "yes" : "no") }

    public func audioTracks() -> [MediaTrack] { tracks(ofType: "audio") }
    public func subtitleTracks() -> [MediaTrack] { tracks(ofType: "sub") }

    private func tracks(ofType type: String) -> [MediaTrack] {
        guard loaded, let count = property("track-list/count").flatMap(Int.init) else { return [] }
        var result: [MediaTrack] = []
        for index in 0..<count where property("track-list/\(index)/type") == type {
            guard let id = property("track-list/\(index)/id") else { continue }
            let language = property("track-list/\(index)/lang")
            let title = property("track-list/\(index)/title") ?? language ?? "\(type.capitalized) \(id)"
            result.append(MediaTrack(
                id: id,
                title: title,
                language: language,
                isSelected: property("track-list/\(index)/selected") == "yes",
                isHearingImpaired: property("track-list/\(index)/hearing-impaired") == "yes",
                isAudioDescription: property("track-list/\(index)/visual-impaired") == "yes"
            ))
        }
        return result
    }

    public func selectAudioTrack(id: String) {
        setProperty("aid", id)
        onTracksChange?()
    }

    public func selectSubtitleTrack(id: String?) {
        setProperty("sid", id ?? "no")
        onTracksChange?()
    }

    public func setAudioEnhancement(_ config: AudioEnhancementConfig) {
        setProperty("af", config.mpvFilterString)
    }

    public func setSubtitleDelay(seconds: Double) {
        setProperty("sub-delay", "\(seconds)")
    }

    public func addExternalSubtitle(fileUrl: URL) -> Bool {
        guard let library, let handle else { return false }
        let path = fileUrl.path
        return path.withCString { cPath in
            "sub-add".withCString { cSubAdd in
                "select".withCString { cSelect in
                    var args: [UnsafePointer<CChar>?] = [cSubAdd, cPath, cSelect, nil]
                    return args.withUnsafeMutableBufferPointer { buf in
                        library.command(handle, buf.baseAddress) == 0
                    }
                }
            }
        }
    }

    public func seekLiveRelative(seconds: Double) {
        run(["seek", String(format: "%.3f", seconds), "relative"])
    }

    public func returnToLive() {
        run(["seek", "0", "relative+exact"])
    }

    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        pollTask?.cancel()
        pollTask = nil
        onStateChange = nil
        onTracksChange = nil
        renderer?.stop()
        if let library, let handle {
            library.terminateDestroy(handle)
        }
        handle = nil
    }
}
