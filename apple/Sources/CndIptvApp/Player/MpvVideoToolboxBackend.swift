import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

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
            paths.append(frameworks + "/libmpv.2.dylib")
            paths.append(frameworks + "/libmpv.dylib")
        }
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            paths.append(executableDir + "/libmpv.2.dylib")
        }
        paths.append("libmpv.2.dylib")
        #if os(macOS)
        paths.append(contentsOf: [
            "/opt/homebrew/lib/libmpv.2.dylib",
            "/usr/local/lib/libmpv.2.dylib",
        ])
        #endif
        return paths
    }

    private init?() {
        var opened: UnsafeMutableRawPointer?
        for path in Self.candidatePaths {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                opened = handle
                break
            }
        }
        guard let lib = opened else { return nil }

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
        else {
            dlclose(lib)
            return nil
        }
        self.create = create
        self.initialize = initialize
        self.terminateDestroy = destroy
        self.setOption = setOption
        self.setProperty = setProperty
        self.command = command
        self.getProperty = getProperty
        self.free = free
        self.waitEvent = waitEvent
        self.errorString = symbol("mpv_error_string", as: ErrorStringFn.self)
        self.renderCreate = renderCreate
        self.renderRender = renderRender
        self.renderFree = renderFree
        self.renderUpdate = renderUpdate
        self.renderSetCallback = renderSetCallback
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

// MARK: - Backend

/// Universal engine: decodes `.ts`, `.mkv`, `.avi`, HEVC, AC3/DTS, ASS/PGS subtitles via `libmpv`
/// with `VideoToolbox` hardware decoding.
@MainActor
public final class MpvVideoToolboxBackend: VideoBackend {
    public static var isLibraryAvailable: Bool { MpvLibrary.isAvailable }

    public let engineKind: PlayerEngineKind = .mpv
    public var displayLayer: CALayer { renderer?.layer ?? placeholderLayer }
    public private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: ((PlaybackState) -> Void)?
    public var onTracksChange: (() -> Void)?
    public var timeshiftDuration: TimeshiftDuration = .oneHour

    private let library: MpvLibrary?
    private let renderer: MpvRenderer?
    private let placeholderLayer = CALayer()
    private var handle: OpaquePointer?
    private var pollTask: Task<Void, Never>?
    private var loaded = false
    private var cachedPositionMs: Int64 = 0
    private var cachedDurationMs: Int64 = 0
    private var isTornDown = false

    public init() {
        library = MpvLibrary.shared
        renderer = library.map { MpvRenderer(library: $0) }
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
            guard renderer.attach(to: created) else {
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
        run(["loadfile", media.url.absoluteString, "replace"])
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
        // The software render target cannot import zero-copy `videotoolbox` frames, so mpv falls
        // through to `videotoolbox-copy` (still GPU/media-engine decoding, one copy to RAM).
        option("hwdec", "videotoolbox,videotoolbox-copy")
        option("cache", "yes")
        option("demuxer-max-bytes", "64MiB")
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
            case 1: // MPV_EVENT_SHUTDOWN
                return
            default:
                break
            }
        }

        guard loaded else { return }
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
                isSelected: property("track-list/\(index)/selected") == "yes"
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
