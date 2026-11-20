import AppKit
import AVFoundation
import CoreMedia
import CoreImage
import ImageIO
import Network
import Darwin

func log(_ text: String) {
    print(text)
    fflush(stdout)
}

func logError(_ text: String) {
    fputs("\(text)\n", stderr)
    fflush(stderr)
    log(text)
}

struct Mode: Equatable, Sendable {
    let width: Int32
    let height: Int32
    let fps: Double
    var fpsInt: Int { Int(fps.rounded()) }
    var id: String { "\(width)x\(height)@\(fpsInt)" }
    var shortName: String { "\(height)p\(fpsInt)" }
    var title: String { "\(width) × \(height) · \(fpsInt) fps" }
}

let presetModes = [
    Mode(width: 1280, height: 720, fps: 30),
    Mode(width: 1280, height: 720, fps: 60),
    Mode(width: 1280, height: 720, fps: 120),
    Mode(width: 1920, height: 1080, fps: 30),
    Mode(width: 1920, height: 1080, fps: 60),
    Mode(width: 1920, height: 1080, fps: 120),
    Mode(width: 1920, height: 1080, fps: 240),
    Mode(width: 2560, height: 1440, fps: 30),
    Mode(width: 2560, height: 1440, fps: 60),
    Mode(width: 2560, height: 1440, fps: 120),
    Mode(width: 2560, height: 1440, fps: 144),
    Mode(width: 3840, height: 2160, fps: 30),
    Mode(width: 3840, height: 2160, fps: 60),
    Mode(width: 3840, height: 2160, fps: 120),
]

let defaultMode = Mode(width: 1280, height: 720, fps: 60)

func parseMode(_ raw: String) -> Mode? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let match = presetModes.first(where: { $0.shortName.lowercased() == text || $0.id.lowercased() == text }) {
        return match
    }
    let aliases: [(String, Int32, Int32)] = [
        ("2k", 2560, 1440),
        ("4k", 3840, 2160),
        ("720p", 1280, 720),
        ("1080p", 1920, 1080),
        ("1440p", 2560, 1440),
        ("2160p", 3840, 2160),
    ]
    for (prefix, w, h) in aliases where text.hasPrefix(prefix) {
        if let fps = Double(text.dropFirst(prefix.count)), fps > 0 {
            return Mode(width: w, height: h, fps: fps)
        }
    }
    let parts = text.split(separator: "@", maxSplits: 1)
    if parts.count == 2, let fps = Double(parts[1]), fps > 0 {
        let dims = parts[0].split(separator: "x", maxSplits: 1)
        if dims.count == 2, let w = Int32(dims[0]), let h = Int32(dims[1]), w > 0, h > 0 {
            return Mode(width: w, height: h, fps: fps)
        }
    }
    return nil
}

let captureKeywords = [
    "hagibis", "usb video", "cam link", "elgato", "game capture",
    "avermedia", "live gamer", "shadowcast", "genki", "guermok",
    "ugreen", "hdmi", "capture", "uvc",
]

func isContinuityOrAppleCamera(_ device: AVCaptureDevice) -> Bool {
    let model = device.modelID.lowercased()
    let maker = device.manufacturer.lowercased()
    return model.hasPrefix("iphone") || model.hasPrefix("ipad") || maker == "apple inc."
}

func scoreCaptureDevice(_ device: AVCaptureDevice) -> Int {
    let name = device.localizedName.lowercased()
    let model = device.modelID.lowercased()
    let maker = device.manufacturer.lowercased()
    var score = 0
    if model.contains("uvc camera") { score += 40 }
    if maker.contains("macrosilicon") || maker.contains("elgato") || maker.contains("avermedia") { score += 30 }
    if captureKeywords.contains(where: { name.contains($0) }) { score += 30 }
    return score
}

func pickCaptureDevice(preferredName: String?) -> AVCaptureDevice? {
    let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
    if let query = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !query.isEmpty, query.lowercased() != "auto" {
        if let exact = devices.first(where: { $0.localizedName == query || $0.uniqueID == query }) {
            return exact
        }
        let lower = query.lowercased()
        return devices.first(where: {
            $0.localizedName.lowercased().contains(lower) ||
            $0.modelID.lowercased().contains(lower) ||
            $0.uniqueID.lowercased().contains(lower)
        })
    }
    let candidates = devices.filter { !isContinuityOrAppleCamera($0) }
    return candidates.max(by: { scoreCaptureDevice($0) < scoreCaptureDevice($1) })
}

func isBuiltinOrContinuityAudio(_ device: AVCaptureDevice) -> Bool {
    let model = device.modelID.lowercased()
    let uid = device.uniqueID.lowercased()
    if model.hasPrefix("iphone") || model.hasPrefix("ipad") { return true }
    if uid.contains("continuity") || uid.hasPrefix("applecamera") || uid.hasPrefix("builtinmicrophone") { return true }
    return false
}

func pickAudioDevice(preferredName: String?, videoCardName: String?) -> AVCaptureDevice? {
    let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external, .microphone],
        mediaType: .audio,
        position: .unspecified
    ).devices.filter { !isBuiltinOrContinuityAudio($0) }
    if let query = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !query.isEmpty, query.lowercased() != "auto" {
        if let exact = devices.first(where: { $0.localizedName == query || $0.uniqueID == query }) {
            return exact
        }
        let lower = query.lowercased()
        return devices.first(where: {
            $0.localizedName.lowercased().contains(lower) ||
            $0.uniqueID.lowercased().contains(lower)
        })
    }
    // Auto: only an external audio device whose localizedName exactly matches the selected video card.
    guard let card = videoCardName?.trimmingCharacters(in: .whitespacesAndNewlines), !card.isEmpty else { return nil }
    return devices.first { $0.localizedName == card }
}

func formatScore(_ format: AVCaptureDevice.Format) -> Int {
    let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
    let exts = CMFormatDescriptionGetExtensions(format.formatDescription) as? [String: Any]
    if exts?["com.apple.cmio.format_extension.decompressed_from_format_type"] != nil {
        // UVC MJPEG decoded by macOS UVCAssistant: higher latency and lossy; keep as fallback.
        return 15
    }
    switch subType {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return 50 // Native NV12 ('420v')
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return 48  // Native NV12 ('420f')
    case kCVPixelFormatType_422YpCbCr8: return 46                   // Native UYVY ('2vuy')
    case kCVPixelFormatType_422YpCbCr8_yuvs: return 45              // Native YUY2 ('yuvs')
    case kCMVideoCodecType_JPEG, kCMVideoCodecType_JPEG_OpenDML: return 10
    default: return 30
    }
}

func frameDuration(for range: AVFrameRateRange, targetFps: Double) -> (duration: CMTime, score: Int)? {
    let diff = abs(range.maxFrameRate - targetFps)
    if diff < 0.05 {
        return (range.minFrameDuration, 30)
    }
    if diff < 0.5 {
        // Covers broadcast NTSC fractional rates (59.94 / 29.97 / 119.88)
        return (range.minFrameDuration, 20)
    }
    if range.minFrameRate - 0.5 <= targetFps && targetFps <= range.maxFrameRate + 0.5 {
        let desired = CMTime(value: 1000, timescale: CMTimeScale((targetFps * 1000).rounded()))
        let clamped = CMTimeMaximum(range.minFrameDuration, CMTimeMinimum(range.maxFrameDuration, desired))
        return (clamped, 10)
    }
    return nil
}

func selectFormat(for device: AVCaptureDevice, mode: Mode) -> (format: AVCaptureDevice.Format, duration: CMTime)? {
    var best: (format: AVCaptureDevice.Format, duration: CMTime, score: Int)?
    for format in device.formats {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard size.width == mode.width, size.height == mode.height else { continue }
        let pixScore = formatScore(format)
        for range in format.videoSupportedFrameRateRanges {
            guard let candidate = frameDuration(for: range, targetFps: mode.fps) else { continue }
            let total = pixScore * 100 + candidate.score
            if best == nil || total > best!.score {
                best = (format, candidate.duration, total)
            }
        }
    }
    return best.map { ($0.format, $0.duration) }
}

func supportedModes(for device: AVCaptureDevice, including customMode: Mode?) -> [Mode] {
    var list = presetModes.filter { selectFormat(for: device, mode: $0) != nil }
    if let custom = customMode, !list.contains(custom), selectFormat(for: device, mode: custom) != nil {
        list.append(custom)
        list.sort { ($0.width, $0.height, $0.fps) < ($1.width, $1.height, $1.fps) }
    }
    return list
}

func env(_ name: String) -> String? {
    guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else { return nil }
    return value
}

func envBool(_ name: String) -> Bool {
    guard let raw = env(name)?.lowercased() else { return false }
    return raw == "1" || raw == "true" || raw == "yes"
}

func normalizeBaseURL(_ raw: String) -> String {
    var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
        trimmed = "http://\(trimmed)"
    }
    return trimmed
}

func printUsage() {
    let text = """
    Usage: switch2-capture [options]

    Options:
      --port <port>       HTTP listen/connect port (default: 18766, env: LUDENS_SWITCH2_CAPTURE_PORT)
      --device <query>    Preferred USB capture device name/ID (env: LUDENS_SWITCH2_CAPTURE_DEVICE)
      --audio-device <q>  Preferred USB audio device name/ID (env: LUDENS_SWITCH2_AUDIO_DEVICE)
      --mode <WxH@fps>    Capture mode, e.g. 1920x1080@60 or 1080p60 (env: LUDENS_SWITCH2_CAPTURE_MODE)
      --headless          Run as pure headless capture HTTP service (env: LUDENS_SWITCH2_CAPTURE_HEADLESS=1)
      --preview           Run as pure decoupled preview window client (env: LUDENS_SWITCH2_CAPTURE_PREVIEW=1)
      --url <http-url>    Capture service base URL for --preview (default: http://127.0.0.1:<port>, env: LUDENS_SWITCH2_CAPTURE_URL)
      --help, -h          Show this help message
    """
    print(text)
}

var arguments = CommandLine.arguments.dropFirst()
var httpPort: UInt16 = UInt16(env("LUDENS_SWITCH2_CAPTURE_PORT") ?? "") ?? 18766
var requestedDeviceName: String? = env("LUDENS_SWITCH2_CAPTURE_DEVICE")
var requestedAudioDeviceName: String? = env("LUDENS_SWITCH2_AUDIO_DEVICE")
var explicitModeRaw: String? = env("LUDENS_SWITCH2_CAPTURE_MODE")
var headless = envBool("LUDENS_SWITCH2_CAPTURE_HEADLESS")
var previewExplicit = envBool("LUDENS_SWITCH2_CAPTURE_PREVIEW")
var explicitBaseURL: String? = env("LUDENS_SWITCH2_CAPTURE_URL")

if headless && previewExplicit {
    // Headless daemon flag takes precedence over ambient preview env if both were present in env.
    previewExplicit = false
}

while let flag = arguments.popFirst() {
    switch flag {
    case "--port":
        if let raw = arguments.popFirst(), let parsed = UInt16(raw), parsed > 0 {
            httpPort = parsed
        } else {
            logError("ERROR Invalid or missing value for --port")
            exit(2)
        }
    case "--device":
        requestedDeviceName = arguments.popFirst() ?? requestedDeviceName
    case "--audio-device":
        requestedAudioDeviceName = arguments.popFirst() ?? requestedAudioDeviceName
    case "--mode":
        explicitModeRaw = arguments.popFirst() ?? explicitModeRaw
    case "--headless":
        headless = true
        previewExplicit = false
    case "--preview":
        previewExplicit = true
        headless = false
    case "--url":
        if let raw = arguments.popFirst(), !raw.isEmpty {
            explicitBaseURL = raw
        } else {
            logError("ERROR Invalid or missing value for --url")
            exit(2)
        }
    case "--help", "-h":
        printUsage()
        exit(0)
    default:
        break
    }
}

let explicitMode = explicitModeRaw.flatMap(parseMode)
let initialMode = explicitMode ?? defaultMode
let previewBaseURL = normalizeBaseURL(explicitBaseURL ?? "http://127.0.0.1:\(httpPort)")

struct RemoteStatusProbe: Sendable {
    let ok: Bool
    let isKnownHeadlessDaemon: Bool
    let device: String?
    let mode: String?
    let width: Int
    let height: Int
    let fps: Double
    let frameSequence: UInt64
}

final class ProbeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RemoteStatusProbe?
    func set(_ newValue: RemoteStatusProbe) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
    func get() -> RemoteStatusProbe? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func probeCaptureServiceStatus(baseURL: String, timeout: TimeInterval = 0.3) -> RemoteStatusProbe? {
    guard let url = URL(string: "\(baseURL)/status") else { return nil }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }

    let semaphore = DispatchSemaphore(value: 0)
    let box = ProbeResultBox()

    let task = session.dataTask(with: url) { data, response, error in
        defer { semaphore.signal() }
        guard error == nil,
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        let ok = (json["ok"] as? Bool) ?? false
        let isHeadlessDaemon = ((json["headless"] as? Bool) == true) && (json["frameSequence"] != nil)
        let device = json["device"] as? String
        let mode = json["mode"] as? String
        let width = (json["width"] as? NSNumber)?.intValue ?? 0
        let height = (json["height"] as? NSNumber)?.intValue ?? 0
        let fps = (json["fps"] as? NSNumber)?.doubleValue ?? 0
        let seq = (json["frameSequence"] as? NSNumber)?.uint64Value ?? 0
        box.set(RemoteStatusProbe(
            ok: ok,
            isKnownHeadlessDaemon: isHeadlessDaemon,
            device: device,
            mode: mode,
            width: width,
            height: height,
            fps: fps,
            frameSequence: seq
        ))
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + timeout + 0.05)
    return box.get()
}

private func canConnectLoopbackIPv4(_ port: UInt16) -> Bool {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return false }
    defer { close(sock) }
    let flags = fcntl(sock, F_GETFL, 0)
    if flags >= 0 { _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK) }

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if rc == 0 { return true }
    if errno == EINPROGRESS {
        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        if poll(&pfd, 1, 100) > 0 {
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(sock, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0, soErr == 0 {
                return true
            }
        }
    }
    return false
}

private func canConnectLoopbackIPv6(_ port: UInt16) -> Bool {
    let sock = socket(AF_INET6, SOCK_STREAM, 0)
    guard sock >= 0 else { return false }
    defer { close(sock) }
    let flags = fcntl(sock, F_GETFL, 0)
    if flags >= 0 { _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK) }

    var addr = sockaddr_in6()
    addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    addr.sin6_family = sa_family_t(AF_INET6)
    addr.sin6_port = port.bigEndian
    _ = withUnsafeMutablePointer(to: &addr.sin6_addr) {
        inet_pton(AF_INET6, "::1", $0)
    }

    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
    }
    if rc == 0 { return true }
    if errno == EINPROGRESS {
        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        if poll(&pfd, 1, 100) > 0 {
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(sock, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0, soErr == 0 {
                return true
            }
        }
    }
    return false
}

func isLoopbackPortOccupied(_ port: UInt16) -> Bool {
    return canConnectLoopbackIPv4(port) || canConnectLoopbackIPv6(port)
}

// Persistent process-level activity assertion so macOS App Nap / screen lock / occlusion never throttles capture or preview.
let globalActivityToken: NSObjectProtocol = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
    reason: "Live Switch 2 HDMI capture and preview"
)

var isPreviewClient = previewExplicit
if !headless && !isPreviewClient {
    if let probe = probeCaptureServiceStatus(baseURL: previewBaseURL, timeout: 0.3),
       probe.ok || probe.isKnownHeadlessDaemon {
        isPreviewClient = true
        log("AUTO-PREVIEW attached to existing capture service at \(previewBaseURL)")
    }
}

final class VideoView: NSView {
    let rootLayer = CALayer()
    let preview = AVCaptureVideoPreviewLayer()
    let remoteLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        rootLayer.backgroundColor = NSColor.black.cgColor
        self.layer = rootLayer
        self.wantsLayer = true

        preview.videoGravity = .resizeAspect
        remoteLayer.contentsGravity = .resizeAspect
        remoteLayer.backgroundColor = NSColor.black.cgColor
        remoteLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "hidden": NSNull(),
        ]
        remoteLayer.isHidden = true

        rootLayer.addSublayer(preview)
        rootLayer.addSublayer(remoteLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configureForRemotePreview() {
        preview.session = nil
        preview.isHidden = true
        remoteLayer.isHidden = false
        remoteLayer.frame = bounds
    }

    func displayRemoteImage(_ image: CGImage) {
        if remoteLayer.frame != bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            remoteLayer.frame = bounds
            CATransaction.commit()
        }
        remoteLayer.contents = image
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        rootLayer.contentsScale = scale
        remoteLayer.contentsScale = scale
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        remoteLayer.frame = bounds
        CATransaction.commit()
    }
}

struct StatusSnapshot: Sendable {
    let isConnected: Bool
    let deviceName: String?
    let modelID: String?
    let mode: Mode?
    let supportedModes: [Mode]
    let frameSequence: UInt64
    let capturedAtMs: Double
    let lastFrameUptime: TimeInterval
    let width: Int
    let height: Int
    let fps: Double
}

struct EncodedStreamFrame: Sendable {
    let sequence: UInt64
    let jpeg: Data
    let width: Int
    let height: Int
    let fps: Double
}

final class FrameStore: @unchecked Sendable {
    private var buffer: CVPixelBuffer?
    private let lock = NSLock()
    private var isConnected = false
    private var deviceName: String?
    private var modelID: String?
    private var activeMode: Mode?
    private var supportedModes: [Mode] = []
    private(set) var frameSequence: UInt64 = 0
    private(set) var capturedAtMs: Double = 0
    private var lastFrameUptime: TimeInterval = 0
    private(set) var width = 0
    private(set) var height = 0
    private var fpsStart = 0.0
    private var fpsCount = 0
    private(set) var fps: Double = 0
    private var cachedStreamFrame: EncodedStreamFrame?
    private var cachedStreamQualityKey: Int = -1
    private var activeStreamClients: Int = 0

    func adjustStreamClients(delta: Int) {
        lock.lock()
        defer { lock.unlock() }
        activeStreamClients = max(0, activeStreamClients + delta)
        if activeStreamClients == 0 {
            cachedStreamFrame = nil
            cachedStreamQualityKey = -1
        }
    }

    func streamClientCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeStreamClients
    }

    func setConnected(device: AVCaptureDevice, mode: Mode, supportedModes: [Mode]) {
        lock.lock()
        defer { lock.unlock() }
        isConnected = true
        deviceName = device.localizedName
        modelID = device.modelID
        activeMode = mode
        self.supportedModes = supportedModes
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
    }

    func setMode(_ mode: Mode) {
        lock.lock()
        defer { lock.unlock() }
        activeMode = mode
        fpsStart = 0
        fpsCount = 0
    }

    func setDisconnected() {
        lock.lock()
        defer { lock.unlock() }
        isConnected = false
        buffer = nil
        cachedStreamFrame = nil
        fps = 0
        fpsStart = 0
        fpsCount = 0
    }

    func snapshot() -> StatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return StatusSnapshot(
            isConnected: isConnected,
            deviceName: deviceName,
            modelID: modelID,
            mode: activeMode,
            supportedModes: supportedModes,
            frameSequence: frameSequence,
            capturedAtMs: capturedAtMs,
            lastFrameUptime: lastFrameUptime,
            width: width,
            height: height,
            fps: fps
        )
    }

    func store(_ pixel: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        buffer = pixel
        frameSequence += 1
        width = CVPixelBufferGetWidth(pixel)
        height = CVPixelBufferGetHeight(pixel)
        capturedAtMs = Date().timeIntervalSince1970 * 1000
        let now = ProcessInfo.processInfo.systemUptime
        lastFrameUptime = now
        if fpsStart == 0 { fpsStart = now; fpsCount = 0 }
        fpsCount += 1
        if now - fpsStart >= 1 {
            fps = Double(fpsCount) / (now - fpsStart)
            fpsStart = now
            fpsCount = 0
        }
    }

    func latest() -> (pixel: CVPixelBuffer, sequence: UInt64, fps: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard isConnected, let buffer, frameSequence > 0 else { return nil }
        return (buffer, frameSequence, fps)
    }

    func waitForFrame(timeout: TimeInterval) -> (pixel: CVPixelBuffer, sequence: UInt64)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = latest() { return (frame.pixel, frame.sequence) }
            Thread.sleep(forTimeInterval: 0.015)
        }
        return nil
    }

    func latestEncodedStreamFrame(after lastSequence: UInt64, quality: Double, context: CIContext, colorSpace: CGColorSpace) -> EncodedStreamFrame? {
        let qualityKey = Int((quality * 100).rounded())
        lock.lock()
        guard isConnected, let pixel = buffer, frameSequence > 0 else {
            lock.unlock()
            return nil
        }
        let seq = frameSequence
        if seq <= lastSequence {
            lock.unlock()
            return nil
        }
        if let cached = cachedStreamFrame, cached.sequence == seq, cachedStreamQualityKey == qualityKey {
            lock.unlock()
            return cached
        }
        let currentFps = fps
        let w = width
        let h = height
        lock.unlock()

        let encodedData: Data? = autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixel)
            return context.jpegRepresentation(
                of: image,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
            )
        }
        guard let jpeg = encodedData else { return nil }
        let frame = EncodedStreamFrame(sequence: seq, jpeg: jpeg, width: w, height: h, fps: currentFps)

        lock.lock()
        if cachedStreamFrame == nil || frame.sequence >= cachedStreamFrame!.sequence {
            cachedStreamFrame = frame
            cachedStreamQualityKey = qualityKey
        }
        lock.unlock()
        return frame
    }
}

let canonicalAudioSampleRate = 48000
let canonicalAudioChannels = 2
let canonicalAudioFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: Double(canonicalAudioSampleRate),
    channels: AVAudioChannelCount(canonicalAudioChannels),
    interleaved: true
)!
let audioBytesPerMillisecond = canonicalAudioSampleRate * canonicalAudioChannels * 2 / 1000 // 192 bytes/ms s16le stereo

func wavHeaderData(dataBytes: Int, sampleRate: Int, channels: Int, bitsPerSample: Int = 16) -> Data {
    var data = Data(capacity: 44)
    let blockAlign = channels * bitsPerSample / 8
    let byteRate = sampleRate * blockAlign

    func appendASCII(_ text: String) {
        data.append(contentsOf: text.utf8)
    }
    func appendLE16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func appendLE32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    appendASCII("RIFF")
    appendLE32(UInt32(36 + dataBytes))
    appendASCII("WAVE")
    appendASCII("fmt ")
    appendLE32(16) // PCM fmt chunk size
    appendLE16(1) // WAVE_FORMAT_PCM
    appendLE16(UInt16(channels))
    appendLE32(UInt32(sampleRate))
    appendLE32(UInt32(byteRate))
    appendLE16(UInt16(blockAlign))
    appendLE16(UInt16(bitsPerSample))
    appendASCII("data")
    appendLE32(UInt32(dataBytes))
    return data
}

struct AudioChunk {
    let sequence: UInt64
    let capturedAtMs: Double
    let data: Data
}

struct AudioStatusSnapshot: Sendable {
    let connected: Bool
    let deviceName: String?
    let sampleRate: Int
    let channels: Int
    let sequence: UInt64
    let capturedAtMs: Double
    let streamClients: Int
}

// Lock-protected bounded ring of canonical interleaved s16le stereo PCM chunks.
// Retains 10 seconds (1,920,000 bytes) max; sequence is monotonic for the process
// lifetime so stream clients can distinguish fresh data across reconnects.
final class AudioStore: @unchecked Sendable {
    static let maxBytes = 1_920_000
    private let lock = NSLock()
    private var chunks: [AudioChunk] = []
    private var totalBytes = 0
    private var connected = false
    private var deviceName: String?
    private var sampleRate = canonicalAudioSampleRate
    private var channels = canonicalAudioChannels
    private(set) var sequence: UInt64 = 0
    private(set) var capturedAtMs: Double = 0
    private var activeStreamClients = 0
    private var unavailableReason: String?

    func setConnected(device: AVCaptureDevice) {
        lock.lock()
        defer { lock.unlock() }
        connected = true
        deviceName = device.localizedName
        unavailableReason = nil
    }

    func setUnavailable(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        connected = false
        deviceName = nil
        unavailableReason = reason
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        chunks.removeAll(keepingCapacity: false)
        totalBytes = 0
        capturedAtMs = 0
    }

    func isAvailable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }

    func unavailableMessage() -> String {
        lock.lock()
        defer { lock.unlock() }
        return unavailableReason ?? "audio capture unavailable"
    }

    func latestSequence() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return sequence
    }

    func adjustStreamClients(delta: Int) {
        lock.lock()
        defer { lock.unlock() }
        activeStreamClients = max(0, activeStreamClients + delta)
    }

    func statusSnapshot() -> AudioStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AudioStatusSnapshot(
            connected: connected,
            deviceName: deviceName,
            sampleRate: sampleRate,
            channels: channels,
            sequence: sequence,
            capturedAtMs: capturedAtMs,
            streamClients: activeStreamClients
        )
    }

    func append(bytes: UnsafeRawPointer, byteCount: Int) {
        guard byteCount > 0 else { return }
        let chunkData = Data(bytes: bytes, count: byteCount)
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        capturedAtMs = Date().timeIntervalSince1970 * 1000
        chunks.append(AudioChunk(sequence: sequence, capturedAtMs: capturedAtMs, data: chunkData))
        totalBytes += byteCount
        while totalBytes > Self.maxBytes, let oldest = chunks.first {
            let excess = totalBytes - Self.maxBytes
            if oldest.data.count <= excess {
                totalBytes -= oldest.data.count
                chunks.removeFirst()
            } else {
                chunks[0] = AudioChunk(sequence: oldest.sequence, capturedAtMs: oldest.capturedAtMs,
                    data: oldest.data.dropFirst(excess))
                totalBytes = Self.maxBytes
            }
        }
    }

    /// Newest contiguous PCM after `afterSequence`, bounded by `maxBytes`.
    /// Falls back to the oldest retained bytes when a slow reader fell behind the
    /// trimmed ring, so latency never grows unbounded.
    func chunksAfter(_ afterSequence: UInt64, maxBytes: Int) -> (data: Data, lastSequence: UInt64)? {
        lock.lock()
        guard connected, let newest = chunks.last, newest.sequence > afterSequence else {
            lock.unlock()
            return nil
        }
        var parts: [Data] = []
        var budget = maxBytes
        for chunk in chunks.reversed() {
            if chunk.sequence <= afterSequence { break }
            if chunk.data.count >= budget {
                if budget > 0 {
                    parts.append(chunk.data.suffix(budget))
                    budget = 0
                }
                break
            }
            parts.append(chunk.data)
            budget -= chunk.data.count
        }
        lock.unlock()
        guard !parts.isEmpty else { return nil }
        var out = Data(capacity: maxBytes - max(budget, 0))
        for part in parts.reversed() {
            out.append(part)
        }
        return (out, newest.sequence)
    }

    /// Most recent exact `durationMs` of PCM, or nil when unavailable/insufficient.
    func latestCaptureBytes(durationMs: Int) -> (data: Data, sequence: UInt64, capturedAtMs: Double)? {
        let needed = durationMs * audioBytesPerMillisecond
        lock.lock()
        guard connected, totalBytes >= needed else {
            lock.unlock()
            return nil
        }
        var parts: [Data] = []
        var remaining = needed
        var newestAtMs: Double = 0
        for chunk in chunks.reversed() {
            if remaining == 0 { break }
            let take = min(chunk.data.count, remaining)
            if take == chunk.data.count {
                parts.append(chunk.data)
            } else {
                parts.append(chunk.data.suffix(take))
            }
            if newestAtMs == 0 { newestAtMs = chunk.capturedAtMs }
            remaining -= take
        }
        let newestSeq = sequence
        lock.unlock()
        guard remaining == 0, !parts.isEmpty else { return nil }
        var out = Data(capacity: needed)
        for part in parts.reversed() {
            out.append(part)
        }
        return (out, newestSeq, newestAtMs)
    }
}

func parseQueryParams(_ rawQuery: String?) -> [String: String] {
    guard let rawQuery, !rawQuery.isEmpty else { return [:] }
    var out: [String: String] = [:]
    for pair in rawQuery.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        if kv.count == 2 {
            out[String(kv[0]).lowercased()] = String(kv[1])
        } else if kv.count == 1 {
            out[String(kv[0]).lowercased()] = ""
        }
    }
    return out
}

final class MjpegStreamSession: @unchecked Sendable {
    private let connection: NWConnection
    private weak var server: HttpServer?
    private let maxFps: Double
    private let quality: Double
    private let lock = NSLock()
    private var closed = false
    private var lastSentSequence: UInt64 = 0
    private var lastFrameSentAt: TimeInterval = ProcessInfo.processInfo.systemUptime

    init(connection: NWConnection, server: HttpServer, maxFps: Double, quality: Double) {
        self.connection = connection
        self.server = server
        self.maxFps = maxFps
        self.quality = quality
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func start() {
        guard let server else {
            connection.cancel()
            return
        }
        server.store.adjustStreamClients(delta: 1)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        watchClientEOF()

        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-store, no-cache, must-revalidate\r\nPragma: no-cache\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] sendError in
            guard let self else { return }
            if sendError != nil {
                self.close()
                return
            }
            self.scheduleNextPump(after: 0)
        })
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        server?.store.adjustStreamClients(delta: -1)
        server?.unregisterStream(self)
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func watchClientEOF() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                self.close()
                return
            }
            if !self.isClosed {
                self.watchClientEOF()
            }
        }
    }

    private func scheduleNextPump(after delay: TimeInterval) {
        guard let server, !isClosed else {
            close()
            return
        }
        if delay <= 0 {
            server.streamQueue.async { [weak self] in
                self?.pumpNextFrame()
            }
        } else {
            server.streamQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pumpNextFrame()
            }
        }
    }

    private func pumpNextFrame() {
        guard let server, !isClosed else {
            close()
            return
        }
        let snap = server.store.snapshot()
        if !snap.isConnected {
            close()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let prevSeq = lastSentSequence
        let sinceLastSend = now - lastFrameSentAt
        lock.unlock()

        // Re-send latest buffered frame once per second as keepalive if HDMI holds a static frame.
        let requiredAfterSeq: UInt64 = (sinceLastSend >= 1.0) ? 0 : prevSeq
        guard let encoded = server.store.latestEncodedStreamFrame(
            after: requiredAfterSeq,
            quality: quality,
            context: server.context,
            colorSpace: server.rgbColorSpace
        ) else {
            if sinceLastSend > 3.0 {
                close()
                return
            }
            scheduleNextPump(after: 0.008)
            return
        }

        let sendStartedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        lastSentSequence = max(lastSentSequence, encoded.sequence)
        lastFrameSentAt = sendStartedAt
        lock.unlock()

        let partHeader = String(
            format: "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\nX-Frame-Sequence: %llu\r\nX-Frame-Width: %d\r\nX-Frame-Height: %d\r\nX-Capture-Fps: %.1f\r\n\r\n",
            encoded.jpeg.count,
            encoded.sequence,
            encoded.width,
            encoded.height,
            encoded.fps
        )
        var chunk = Data(partHeader.utf8)
        chunk.reserveCapacity(chunk.count + encoded.jpeg.count + 2)
        chunk.append(encoded.jpeg)
        chunk.append(Data("\r\n".utf8))

        let minInterval = 1.0 / maxFps
        connection.send(content: chunk, completion: .contentProcessed { [weak self] sendError in
            guard let self else { return }
            if sendError != nil || self.isClosed {
                self.close()
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - sendStartedAt
            let wait = max(0.001, minInterval - elapsed)
            self.scheduleNextPump(after: wait)
        })
    }
}

// One /audio/stream client: raw canonical PCM after a 200 header, no Content-Length.
final class AudioStreamSession: @unchecked Sendable {
    private let connection: NWConnection
    private weak var server: HttpServer?
    private let lock = NSLock()
    private var closed = false
    private var lastSentSequence: UInt64
    private var lastSendAt: TimeInterval
    private var sendWatchdog: DispatchSourceTimer?

    init(connection: NWConnection, server: HttpServer, startSequence: UInt64) {
        self.connection = connection
        self.server = server
        self.lastSentSequence = startSequence
        self.lastSendAt = ProcessInfo.processInfo.systemUptime
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func start() {
        guard let server else {
            connection.cancel()
            return
        }
        server.audioStore.adjustStreamClients(delta: 1)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        watchClientEOF()

        let watchdog = DispatchSource.makeTimerSource(queue: server.streamQueue)
        watchdog.schedule(deadline: .now() + 1.0, repeating: 1.0)
        watchdog.setEventHandler { [weak self] in
            guard let self, !self.isClosed else { return }
            self.lock.lock()
            let lastSendAt = self.lastSendAt
            self.lock.unlock()
            if ProcessInfo.processInfo.systemUptime - lastSendAt > 3.0 {
                self.close()
            }
        }
        watchdog.resume()
        sendWatchdog = watchdog

        let head = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: application/octet-stream\r\n" +
            "X-Audio-Sample-Rate: \(canonicalAudioSampleRate)\r\n" +
            "X-Audio-Channels: \(canonicalAudioChannels)\r\n" +
            "X-Audio-Format: s16le\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] sendError in
            guard let self else { return }
            if sendError != nil {
                self.close()
                return
            }
            self.schedulePump(after: 0)
        })
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        sendWatchdog?.cancel()
        sendWatchdog = nil
        server?.audioStore.adjustStreamClients(delta: -1)
        server?.unregisterAudioStream(self)
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func watchClientEOF() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                self.close()
                return
            }
            if !self.isClosed {
                self.watchClientEOF()
            }
        }
    }

    private func schedulePump(after delay: TimeInterval) {
        guard let server, !isClosed else {
            close()
            return
        }
        if delay <= 0 {
            server.streamQueue.async { [weak self] in
                self?.pump()
            }
        } else {
            server.streamQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pump()
            }
        }
    }

    private func pump() {
        guard let server, !isClosed else {
            close()
            return
        }
        let store = server.audioStore
        guard store.isAvailable() else {
            close()
            return
        }
        // At most 0.5 s of PCM in flight; the ring trims behind a slow reader,
        // so backpressure skips stale audio instead of growing latency.
        guard let next = store.chunksAfter(lastSentSequence, maxBytes: audioBytesPerMillisecond * 500) else {
            if ProcessInfo.processInfo.systemUptime - lastSendAt > 3.0 {
                close()
                return
            }
            schedulePump(after: 0.005)
            return
        }
        lock.lock()
        lastSentSequence = next.lastSequence
        lastSendAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        connection.send(content: next.data, completion: .contentProcessed { [weak self] sendError in
            guard let self else { return }
            if sendError != nil || self.isClosed {
                self.close()
                return
            }
            self.schedulePump(after: 0)
        })
    }
}

final class StartupStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var result: Result<Void, Error>

    init(defaultError: Error) {
        self.result = .failure(defaultError)
    }

    func finishOnce(_ newResult: Result<Void, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resolved { return false }
        resolved = true
        result = newResult
        return true
    }

    func currentResult() -> Result<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

final class HttpServer: NSObject, @unchecked Sendable {
    let port: UInt16
    let listener: NWListener
    let store: FrameStore
    let audioStore: AudioStore
    let fallbackModeProvider: @Sendable () -> Mode
    let context = CIContext(options: [
        .cacheIntermediates: false,
    ])
    let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let listenerQueue = DispatchQueue(label: "switch2.http.listener")
    let streamQueue = DispatchQueue(label: "switch2.http.stream", qos: .userInteractive)
    private let activeStreamsLock = NSLock()
    private var activeStreams: [ObjectIdentifier: MjpegStreamSession] = [:]
    private let activeAudioStreamsLock = NSLock()
    private var activeAudioStreams: [ObjectIdentifier: AudioStreamSession] = [:]

    init(port: UInt16, store: FrameStore, audioStore: AudioStore, fallbackModeProvider: @escaping @Sendable () -> Mode) throws {
        self.port = port
        self.store = store
        self.audioStore = audioStore
        self.fallbackModeProvider = fallbackModeProvider
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "Switch2Capture", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid HTTP port \(port)"
            ])
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        listener = try NWListener(using: parameters)
        super.init()
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    func startAndWaitReady(timeout: TimeInterval = 2.0) -> Result<Void, Error> {
        if isLoopbackPortOccupied(port) {
            let err = NSError(domain: "Switch2Capture", code: Int(EADDRINUSE), userInfo: [
                NSLocalizedDescriptionKey: "Port \(port) is already in use on 127.0.0.1:\(port); refusing to start duplicate capture service"
            ])
            return .failure(err)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let stateBox = StartupStateBox(defaultError: NSError(
            domain: "Switch2Capture",
            code: Int(ETIMEDOUT),
            userInfo: [NSLocalizedDescriptionKey: "Timed out binding HTTP listener on 127.0.0.1:\(port)"]
        ))

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                log("HTTP-LISTENING 127.0.0.1:\(self.port)")
                if stateBox.finishOnce(.success(())) {
                    semaphore.signal()
                }
            case .waiting(let error):
                let msg = "HTTP listener cannot bind 127.0.0.1:\(self.port): \(error)"
                logError("HTTP-FAILED \(msg)")
                self.listener.cancel()
                if stateBox.finishOnce(.failure(NSError(domain: "Switch2Capture", code: Int(EADDRINUSE), userInfo: [
                    NSLocalizedDescriptionKey: msg
                ]))) {
                    semaphore.signal()
                }
            case .failed(let error):
                let msg = "HTTP listener failed on 127.0.0.1:\(self.port): \(error)"
                logError("HTTP-FAILED \(msg)")
                if stateBox.finishOnce(.failure(NSError(domain: "Switch2Capture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: msg
                ]))) {
                    semaphore.signal()
                } else if headless {
                    exit(1)
                }
            default:
                break
            }
        }

        listener.start(queue: listenerQueue)
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            listener.cancel()
            return .failure(NSError(
                domain: "Switch2Capture",
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for HTTP listener on 127.0.0.1:\(port)"]
            ))
        }
        return stateBox.currentResult()
    }

    func stop() {
        listener.cancel()
        activeStreamsLock.lock()
        let sessions = Array(activeStreams.values)
        activeStreams.removeAll()
        activeStreamsLock.unlock()
        for s in sessions {
            s.close()
        }
        activeAudioStreamsLock.lock()
        let audioSessions = Array(activeAudioStreams.values)
        activeAudioStreams.removeAll()
        activeAudioStreamsLock.unlock()
        for s in audioSessions {
            s.close()
        }
    }

    fileprivate func unregisterStream(_ session: MjpegStreamSession) {
        activeStreamsLock.lock()
        activeStreams.removeValue(forKey: ObjectIdentifier(session))
        activeStreamsLock.unlock()
    }

    fileprivate func unregisterAudioStream(_ session: AudioStreamSession) {
        activeAudioStreamsLock.lock()
        activeAudioStreams.removeValue(forKey: ObjectIdentifier(session))
        activeAudioStreamsLock.unlock()
    }

    private func accept(_ connection: NWConnection) {
        let connQueue = DispatchQueue(label: "switch2.http.conn")
        connection.start(queue: connQueue)
        receiveRequest(connection, accumulated: Data())
    }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if let lineEnd = buffer.range(of: Data("\r\n".utf8)) {
                let firstLineData = buffer[buffer.startIndex..<lineEnd.lowerBound]
                if let line = String(data: firstLineData, encoding: .utf8) {
                    let parts = line.split(separator: " ")
                    if parts.count >= 2 {
                        self.route(String(parts[0]), String(parts[1]), connection)
                        return
                    }
                }
                connection.cancel()
                return
            }
            if error != nil || isComplete || buffer.count > 16384 {
                connection.cancel()
                return
            }
            self.receiveRequest(connection, accumulated: buffer)
        }
    }

    private func respond(_ connection: NWConnection, status: String, contentType: String, headers: [(String, String)], body: Data, headOnly: Bool = false) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        if !headOnly {
            payload.append(body)
        }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func buildStatusPayload() -> Data {
        let state = store.snapshot()
        let resolvedMode = state.mode ?? fallbackModeProvider()
        var object: [String: Any] = [
            "ok": state.isConnected,
            "connected": state.isConnected,
            "headless": headless,
            "mode": resolvedMode.id,
            "device": state.deviceName ?? requestedDeviceName ?? "auto",
            "width": state.width,
            "height": state.height,
            "fps": (state.fps * 10).rounded() / 10,
            "frameSequence": state.frameSequence,
            "capturedAtMs": (state.capturedAtMs * 10).rounded() / 10,
            "streamClients": store.streamClientCount(),
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
        if let modelID = state.modelID { object["modelID"] = modelID }
        if !state.supportedModes.isEmpty { object["supportedModes"] = state.supportedModes.map(\.id) }
        let audio = audioStore.statusSnapshot()
        object["audio"] = [
            "connected": audio.connected,
            "device": audio.deviceName ?? NSNull(),
            "sampleRate": audio.sampleRate,
            "channels": audio.channels,
            "sequence": audio.sequence,
            "capturedAtMs": (audio.capturedAtMs * 10).rounded() / 10,
            "streamClients": audio.streamClients,
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private func route(_ method: String, _ target: String, _ connection: NWConnection) {
        let isHead = (method == "HEAD")
        guard method == "GET" || isHead else {
            respond(connection, status: "405 Method Not Allowed", contentType: "text/plain", headers: [], body: Data("method not allowed".utf8))
            return
        }
        let splitTarget = target.split(separator: "?", maxSplits: 1).map(String.init)
        let routePath = splitTarget[0]
        let query = parseQueryParams(splitTarget.count > 1 ? splitTarget[1] : nil)

        if routePath == "/status" || routePath == "/health" {
            let body = buildStatusPayload()
            respond(connection, status: "200 OK", contentType: "application/json", headers: [], body: body, headOnly: isHead)
            return
        }

        if routePath == "/capture" {
            let format = (query["format"]?.lowercased() == "png") ? "png" : "jpeg"
            let quality = min(1.0, max(0.2, Double(query["quality"] ?? "") ?? 0.90))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { connection.cancel(); return }
                guard let (pixel, sequence) = self.store.waitForFrame(timeout: 2.0) else {
                    self.respond(connection, status: "503 Service Unavailable", contentType: "text/plain", headers: [], body: Data("no frame available".utf8), headOnly: isHead)
                    return
                }
                let frameWidth = CVPixelBufferGetWidth(pixel)
                let frameHeight = CVPixelBufferGetHeight(pixel)
                let bytes: Data? = autoreleasepool {
                    let image = CIImage(cvPixelBuffer: pixel)
                    if format == "png" {
                        return self.context.pngRepresentation(of: image, format: .RGBA8, colorSpace: self.rgbColorSpace, options: [:])
                    } else {
                        return self.context.jpegRepresentation(
                            of: image,
                            colorSpace: self.rgbColorSpace,
                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
                        )
                    }
                }
                guard let bytes else {
                    self.respond(connection, status: "500 Internal Server Error", contentType: "text/plain", headers: [], body: Data("encode failed".utf8), headOnly: isHead)
                    return
                }
                let headers = [
                    ("X-Frame-Sequence", String(sequence)),
                    ("X-Frame-Width", String(frameWidth)),
                    ("X-Frame-Height", String(frameHeight)),
                ]
                self.respond(connection, status: "200 OK", contentType: format == "png" ? "image/png" : "image/jpeg", headers: headers, body: bytes, headOnly: isHead)
            }
            return
        }

        if routePath == "/stream" {
            if isHead {
                respond(connection, status: "200 OK", contentType: "multipart/x-mixed-replace; boundary=frame", headers: [], body: Data(), headOnly: true)
                return
            }
            let maxFps = min(60.0, max(1.0, Double(query["fps"] ?? "") ?? 60.0))
            let quality = min(0.95, max(0.30, Double(query["quality"] ?? "") ?? 0.82))
            startMjpegStream(connection, maxFps: maxFps, quality: quality)
            return
        }

        if routePath == "/audio/stream" {
            let audioHeaders = [
                ("X-Audio-Sample-Rate", String(canonicalAudioSampleRate)),
                ("X-Audio-Channels", String(canonicalAudioChannels)),
                ("X-Audio-Format", "s16le"),
            ]
            if isHead {
                respond(connection, status: "200 OK", contentType: "application/octet-stream", headers: audioHeaders, body: Data(), headOnly: true)
                return
            }
            startAudioStream(connection)
            return
        }

        if routePath == "/audio/capture" {
            if isHead {
                respond(connection, status: "200 OK", contentType: "audio/wav", headers: [], body: Data(), headOnly: true)
                return
            }
            var durationMs = 1000
            if let raw = query["durationms"], !raw.isEmpty {
                guard let parsed = Int(raw.trimmingCharacters(in: .whitespaces)),
                      (100...10000).contains(parsed) else {
                    respond(connection, status: "400 Bad Request", contentType: "text/plain", headers: [], body: Data("invalid durationMs: expected integer 100..10000".utf8), headOnly: false)
                    return
                }
                durationMs = parsed
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { connection.cancel(); return }
                guard let captured = self.audioStore.latestCaptureBytes(durationMs: durationMs) else {
                    let message = self.audioStore.isAvailable()
                        ? "insufficient audio captured for \(durationMs) ms"
                        : self.audioStore.unavailableMessage()
                    self.respond(connection, status: "503 Service Unavailable", contentType: "text/plain", headers: [], body: Data(message.utf8), headOnly: false)
                    return
                }
                var wav = wavHeaderData(dataBytes: captured.data.count, sampleRate: canonicalAudioSampleRate, channels: canonicalAudioChannels, bitsPerSample: 16)
                wav.append(captured.data)
                let headers = [
                    ("X-Audio-Sequence", String(captured.sequence)),
                    ("X-Audio-Sample-Rate", String(canonicalAudioSampleRate)),
                    ("X-Audio-Channels", String(canonicalAudioChannels)),
                    ("X-Audio-Duration-Ms", String(durationMs)),
                ]
                self.respond(connection, status: "200 OK", contentType: "audio/wav", headers: headers, body: wav, headOnly: false)
            }
            return
        }

        respond(connection, status: "404 Not Found", contentType: "text/plain", headers: [], body: Data("unknown route".utf8), headOnly: isHead)
    }

    private func startMjpegStream(_ connection: NWConnection, maxFps: Double, quality: Double) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { connection.cancel(); return }
            guard self.store.waitForFrame(timeout: 1.5) != nil else {
                self.respond(connection, status: "503 Service Unavailable", contentType: "text/plain", headers: [], body: Data("no frame available".utf8))
                return
            }
            let streamSession = MjpegStreamSession(connection: connection, server: self, maxFps: maxFps, quality: quality)
            self.activeStreamsLock.lock()
            self.activeStreams[ObjectIdentifier(streamSession)] = streamSession
            self.activeStreamsLock.unlock()
            streamSession.start()
        }
    }

    private func startAudioStream(_ connection: NWConnection) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { connection.cancel(); return }
            guard self.audioStore.isAvailable() else {
                self.respond(connection, status: "503 Service Unavailable", contentType: "text/plain", headers: [], body: Data(self.audioStore.unavailableMessage().utf8))
                return
            }
            // Only PCM appended after this point is streamed: never replay the ring history.
            let audioSession = AudioStreamSession(connection: connection, server: self, startSequence: self.audioStore.latestSequence())
            self.activeAudioStreamsLock.lock()
            self.activeAudioStreams[ObjectIdentifier(audioSession)] = audioSession
            self.activeAudioStreamsLock.unlock()
            audioSession.start()
        }
    }
}

final class RemotePreviewClient: @unchecked Sendable {
    let baseURL: String
    let onFrame: @Sendable (CGImage, String, String?) -> Void
    let onReconnecting: @Sendable (String) -> Void

    private let streamQueue = DispatchQueue(label: "switch2.preview.stream", qos: .userInteractive)
    private var connection: NWConnection?
    private var statusTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var stopped = false
    private var reconnectPending = false
    private var streamActive = false
    private var httpHeaderParsed = false
    private var buffer = Data()
    private var boundary = "frame"
    private var lastFrameAt: TimeInterval = 0
    private var connectStartedAt: TimeInterval = 0

    private var remoteDeviceName: String?
    private var remoteMode: String?
    private var remoteServerFps: Double = 0
    private var measuredFpsStart: TimeInterval = 0
    private var measuredFpsCount: Int = 0
    private var measuredFps: Double = 0
    private var renderedFrames: UInt64 = 0

    private let headerEndMarker = Data("\r\n\r\n".utf8)
    private let crlfMarker = Data("\r\n".utf8)

    init(
        baseURL: String,
        onFrame: @escaping @Sendable (CGImage, String, String?) -> Void,
        onReconnecting: @escaping @Sendable (String) -> Void
    ) {
        self.baseURL = baseURL
        self.onFrame = onFrame
        self.onReconnecting = onReconnecting
    }

    func start() {
        streamQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.startTimers()
            self.connectStreamNow()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.pollRemoteStatus()
            }
        }
    }

    func stop() {
        streamQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.statusTimer?.cancel()
            self.statusTimer = nil
            self.watchdogTimer?.cancel()
            self.watchdogTimer = nil
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
            self.buffer.removeAll(keepingCapacity: false)
        }
    }

    private func startTimers() {
        let statusTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        statusTimer.schedule(deadline: .now() + 1.0, repeating: 1.5)
        statusTimer.setEventHandler { [weak self] in
            self?.pollRemoteStatus()
        }
        statusTimer.resume()
        self.statusTimer = statusTimer

        let watchdog = DispatchSource.makeTimerSource(queue: streamQueue)
        watchdog.schedule(deadline: .now() + 1.0, repeating: 0.5)
        watchdog.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.streamActive && self.lastFrameAt > 0 && (now - self.lastFrameAt) > 2.5 {
                self.handleDisconnect()
            } else if !self.streamActive && self.connection != nil && self.connectStartedAt > 0 && (now - self.connectStartedAt) > 3.0 {
                self.handleDisconnect()
            }
        }
        watchdog.resume()
        self.watchdogTimer = watchdog
    }

    private func pollRemoteStatus() {
        if let status = probeCaptureServiceStatus(baseURL: baseURL, timeout: 0.4) {
            streamQueue.async { [weak self] in
                guard let self, !self.stopped else { return }
                if let dev = status.device, !dev.isEmpty {
                    self.remoteDeviceName = dev
                }
                if let mode = status.mode, !mode.isEmpty {
                    self.remoteMode = mode
                }
                if status.fps > 0 {
                    self.remoteServerFps = status.fps
                }
                if !status.ok && self.streamActive {
                    self.handleDisconnect()
                }
            }
        }
    }

    private func connectStreamNow() {
        guard !stopped else { return }
        reconnectPending = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        httpHeaderParsed = false
        buffer.removeAll(keepingCapacity: true)
        boundary = "frame"

        guard let parsed = URL(string: baseURL),
              let host = parsed.host, !host.isEmpty else {
            onReconnecting("Invalid capture service URL: \(baseURL)")
            return
        }
        let portNum = UInt16(clamping: parsed.port ?? (parsed.scheme == "https" ? 443 : 80))
        guard let nwPort = NWEndpoint.Port(rawValue: portNum) else {
            onReconnecting("Invalid capture service port: \(baseURL)")
            return
        }

        connectStartedAt = ProcessInfo.processInfo.systemUptime
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.connection, !self.stopped else { return }
            switch state {
            case .ready:
                let req = "GET /stream?fps=60 HTTP/1.1\r\nHost: \(host):\(portNum)\r\nAccept: multipart/x-mixed-replace\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(req.utf8), completion: .contentProcessed { [weak self, weak conn] err in
                    guard let self, let conn, conn === self.connection, !self.stopped else { return }
                    if err != nil {
                        self.handleDisconnect()
                        return
                    }
                    self.receiveNextChunk(from: conn)
                })
            case .failed, .cancelled:
                self.handleDisconnect()
            default:
                break
            }
        }
        conn.start(queue: streamQueue)
    }

    private func receiveNextChunk(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.connection, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.processIncomingBytes(data)
                if conn !== self.connection { return }
            }
            if error != nil || isComplete {
                self.handleDisconnect()
                return
            }
            self.receiveNextChunk(from: conn)
        }
    }

    private func handleDisconnect() {
        guard !stopped else { return }
        streamActive = false
        httpHeaderParsed = false
        measuredFpsStart = 0
        measuredFpsCount = 0
        measuredFps = 0
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: true)
        onReconnecting("Reconnecting to capture service… (\(baseURL))")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped, !reconnectPending else { return }
        reconnectPending = true
        streamQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.stopped else { return }
            self.reconnectPending = false
            if self.connection == nil {
                self.connectStreamNow()
            }
        }
    }

    private func processIncomingBytes(_ data: Data) {
        buffer.append(data)
        if buffer.count > 32 * 1024 * 1024 {
            handleDisconnect()
            return
        }

        if !httpHeaderParsed {
            let limit = buffer.index(buffer.startIndex, offsetBy: min(buffer.count, 8192))
            guard let headerEnd = buffer.range(of: headerEndMarker, in: buffer.startIndex..<limit) else {
                if buffer.count >= 8192 {
                    handleDisconnect()
                }
                return
            }
            let rawHead = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let lines = rawHead.components(separatedBy: "\r\n")
            guard let statusLine = lines.first, statusLine.contains(" 200 ") else {
                handleDisconnect()
                return
            }
            for line in lines.dropFirst() {
                let kv = line.split(separator: ":", maxSplits: 1)
                guard kv.count == 2 else { continue }
                if kv[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-type",
                   let parsedBoundary = extractBoundary(from: String(kv[1])) {
                    boundary = parsedBoundary
                }
            }
            buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
            httpHeaderParsed = true
            lastFrameAt = ProcessInfo.processInfo.systemUptime
        }

        var latestPart: (jpeg: Data, seq: UInt64?, width: Int?, height: Int?, fps: Double?)?
        while let part = popNextMultipartFrame() {
            latestPart = part
        }

        guard let frame = latestPart else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastFrameAt = now
        streamActive = true

        if measuredFpsStart == 0 {
            measuredFpsStart = now
            measuredFpsCount = 0
        }
        measuredFpsCount += 1
        if now - measuredFpsStart >= 1.0 {
            measuredFps = Double(measuredFpsCount) / (now - measuredFpsStart)
            measuredFpsStart = now
            measuredFpsCount = 0
        }
        if let partFps = frame.fps, partFps > 0 {
            remoteServerFps = partFps
        }

        let decoded: CGImage? = autoreleasepool {
            guard let src = CGImageSourceCreateWithData(frame.jpeg as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(
                src,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            )
        }
        guard let cgImage = decoded else { return }

        renderedFrames += 1
        let seq = frame.seq ?? renderedFrames
        let w = frame.width ?? cgImage.width
        let h = frame.height ?? cgImage.height
        if renderedFrames == 1 {
            log("PREVIEW-CLIENT first-frame seq=\(seq) size=\(w)x\(h) url=\(baseURL)")
        }
        let effectiveFps = remoteServerFps > 0 ? remoteServerFps : measuredFps
        let devLabel = remoteDeviceName ?? "Remote Capture"
        let statusText = String(
            format: "Preview · %@ · %.1f fps · %d × %d · frame #%llu · %@",
            devLabel,
            effectiveFps,
            w,
            h,
            seq,
            baseURL
        )
        onFrame(cgImage, statusText, remoteDeviceName)
    }

    private func extractBoundary(from contentType: String) -> String? {
        for segment in contentType.split(separator: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var raw = String(trimmed.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                while raw.hasPrefix("-") {
                    raw.removeFirst()
                }
                if !raw.isEmpty {
                    return raw
                }
            }
        }
        return nil
    }

    private func popNextMultipartFrame() -> (jpeg: Data, seq: UInt64?, width: Int?, height: Int?, fps: Double?)? {
        let marker = Data("--\(boundary)".utf8)
        guard let markerRange = buffer.range(of: marker) else {
            if buffer.count > 512 {
                let keepStart = buffer.index(buffer.endIndex, offsetBy: -min(buffer.count, marker.count + 4))
                buffer.removeSubrange(buffer.startIndex..<keepStart)
            }
            return nil
        }

        if markerRange.lowerBound > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<markerRange.lowerBound)
        }

        // Need headers ending with \r\n\r\n within the first 4KB after boundary.
        let searchLimit = buffer.index(buffer.startIndex, offsetBy: min(buffer.count, 4096))
        guard let headerEnd = buffer.range(of: headerEndMarker, in: buffer.startIndex..<searchLimit) else {
            if buffer.count >= 4096 {
                let dropEnd = buffer.index(buffer.startIndex, offsetBy: marker.count)
                buffer.removeSubrange(buffer.startIndex..<dropEnd)
            }
            return nil
        }

        let headerStart = buffer.index(buffer.startIndex, offsetBy: marker.count)
        let headerString = String(data: buffer[headerStart..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        var contentLength: Int?
        var seq: UInt64?
        var width: Int?
        var height: Int?
        var fps: Double?

        for rawLine in headerString.split(separator: "\r\n") {
            let kv = rawLine.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "content-length": contentLength = Int(val)
            case "x-frame-sequence": seq = UInt64(val)
            case "x-frame-width": width = Int(val)
            case "x-frame-height": height = Int(val)
            case "x-capture-fps": fps = Double(val)
            default: break
            }
        }

        let payloadStart = headerEnd.upperBound
        if let contentLength, contentLength >= 0 {
            let available = buffer.distance(from: payloadStart, to: buffer.endIndex)
            guard available >= contentLength else { return nil }
            let payloadEnd = buffer.index(payloadStart, offsetBy: contentLength)
            let jpeg = Data(buffer[payloadStart..<payloadEnd])
            var consumeEnd = payloadEnd
            if buffer.distance(from: consumeEnd, to: buffer.endIndex) >= 2 {
                let afterCrlf = buffer.index(consumeEnd, offsetBy: 2)
                if buffer[consumeEnd..<afterCrlf] == crlfMarker {
                    consumeEnd = afterCrlf
                }
            }
            buffer.removeSubrange(buffer.startIndex..<consumeEnd)
            return (jpeg, seq, width, height, fps)
        }

        // Fallback when Content-Length is omitted: scan for the next --boundary marker.
        guard let nextMarker = buffer.range(of: marker, in: payloadStart..<buffer.endIndex) else {
            return nil
        }
        var payloadEnd = nextMarker.lowerBound
        if buffer.distance(from: payloadStart, to: payloadEnd) >= 2 {
            let beforeCrlf = buffer.index(payloadEnd, offsetBy: -2)
            if buffer[beforeCrlf..<payloadEnd] == crlfMarker {
                payloadEnd = beforeCrlf
            }
        }
        let jpeg = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeSubrange(buffer.startIndex..<nextMarker.lowerBound)
        return (jpeg, seq, width, height, fps)
    }
}

// Playback engine for preview audio: canonical s16le 48k stereo scheduled into an
// AVAudioPlayerNode. Queued playback is capped so a slow source can never build
// runaway playback latency; stale audio is flushed on reconnect.
final class PreviewAudioPlayer: @unchecked Sendable {
    static let maxQueuedSeconds = 0.5
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var queuedFrames: Int64 = 0
    private var playbackGeneration: UInt64 = 0
    private var engineRunning = false
    private var muted = false

    func setup() -> Bool {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: canonicalAudioFormat)
        do {
            try engine.start()
            engineRunning = true
        } catch {
            logError("AUDIO-PREVIEW engine failed to start: \(error.localizedDescription)")
            return false
        }
        player.volume = muted ? 0 : 1
        player.play()
        return true
    }

    func enqueue(_ data: Data) {
        guard engineRunning else { return }
        let frameBytes = canonicalAudioChannels * 2
        let incomingFrames = data.count / frameBytes
        guard incomingFrames > 0 else { return }
        lock.lock()
        let availableFrames = max(0, Int(Self.maxQueuedSeconds * Double(canonicalAudioSampleRate)) - Int(queuedFrames))
        let frames = min(incomingFrames, availableFrames)
        guard frames > 0 else {
            lock.unlock()
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: canonicalAudioFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            lock.unlock()
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let byteCount = frames * frameBytes
        if let dst = buffer.int16ChannelData {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                // Keep the newest samples when a receive exceeds available headroom.
                memcpy(dst[0], base.advanced(by: data.count - byteCount), byteCount)
            }
        }
        queuedFrames += Int64(frames)
        let generation = playbackGeneration
        lock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.playbackGeneration == generation {
                self.queuedFrames = max(0, self.queuedFrames - Int64(frames))
            }
            self.lock.unlock()
        }
    }

    func resetQueue() {
        lock.lock()
        playbackGeneration &+= 1
        queuedFrames = 0
        lock.unlock()
        player.stop() // flushes scheduled buffers
        player.play()
    }

    func setMuted(_ newMuted: Bool) {
        lock.lock()
        muted = newMuted
        let volume: Float = newMuted ? 0 : 1
        lock.unlock()
        player.volume = volume
    }

    func shutdown() {
        lock.lock()
        engineRunning = false
        lock.unlock()
        player.stop()
        engine.stop()
    }
}

// Independent reconnecting /audio/stream client for the preview window.
// Runs beside RemotePreviewClient and never touches video state.
final class RemoteAudioClient: @unchecked Sendable {
    let baseURL: String
    let player: PreviewAudioPlayer

    private let audioQueue = DispatchQueue(label: "switch2.preview.audio", qos: .userInteractive)
    private var connection: NWConnection?
    private var watchdog: DispatchSourceTimer?
    private var stopped = false
    private var reconnectPending = false
    private var headerParsed = false
    private var pending = Data()
    private var lastDataAt: TimeInterval = 0
    private var connectStartedAt: TimeInterval = 0
    private var loggedFirstByte = false

    private let headerEndMarker = Data("\r\n\r\n".utf8)

    init(baseURL: String, player: PreviewAudioPlayer) {
        self.baseURL = baseURL
        self.player = player
    }

    func start() {
        audioQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.startWatchdog()
            self.connectStreamNow()
        }
    }

    func stop() {
        audioQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.watchdog?.cancel()
            self.watchdog = nil
            self.teardownConnection()
            self.player.shutdown()
        }
    }

    private func teardownConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        headerParsed = false
        pending.removeAll(keepingCapacity: false)
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard self.connection != nil, self.connectStartedAt > 0 else { return }
            if self.headerParsed && self.lastDataAt > 0 && (now - self.lastDataAt) > 3.0 {
                self.handleDisconnect()
            } else if !self.headerParsed && (now - self.connectStartedAt) > 3.0 {
                self.handleDisconnect()
            }
        }
        timer.resume()
        self.watchdog = timer
    }

    private func connectStreamNow() {
        guard !stopped else { return }
        reconnectPending = false
        // Flush stale audio from any previous connection before new PCM arrives.
        player.resetQueue()
        teardownConnection()

        guard let parsed = URL(string: baseURL),
              let host = parsed.host, !host.isEmpty else {
            scheduleReconnect()
            return
        }
        let portNum = UInt16(clamping: parsed.port ?? (parsed.scheme == "https" ? 443 : 80))
        guard let nwPort = NWEndpoint.Port(rawValue: portNum) else {
            scheduleReconnect()
            return
        }

        connectStartedAt = ProcessInfo.processInfo.systemUptime
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.connection, !self.stopped else { return }
            switch state {
            case .ready:
                let req = "GET /audio/stream HTTP/1.1\r\nHost: \(host):\(portNum)\r\nAccept: application/octet-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(req.utf8), completion: .contentProcessed { [weak self, weak conn] err in
                    guard let self, let conn, conn === self.connection, !self.stopped else { return }
                    if err != nil {
                        self.handleDisconnect()
                        return
                    }
                    self.receiveNextChunk(from: conn)
                })
            case .failed, .cancelled:
                self.handleDisconnect()
            default:
                break
            }
        }
        conn.start(queue: audioQueue)
    }

    private func receiveNextChunk(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.connection, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.processAudioBytes(data)
                if conn !== self.connection { return }
            }
            if error != nil || isComplete {
                self.handleDisconnect()
                return
            }
            self.receiveNextChunk(from: conn)
        }
    }

    private func processAudioBytes(_ data: Data) {
        lastDataAt = ProcessInfo.processInfo.systemUptime
        if !headerParsed {
            pending.append(data)
            guard let headerEnd = pending.range(of: headerEndMarker) else {
                if pending.count > 16384 {
                    handleDisconnect()
                }
                return
            }
            let head = String(data: pending.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) ?? ""
            guard head.contains(" 200 ") else {
                log("AUDIO-PREVIEW stream rejected: \(head.components(separatedBy: "\r\n").first ?? "unknown response")")
                handleDisconnect()
                return
            }
            pending = pending.subdata(in: headerEnd.upperBound..<pending.count)
            headerParsed = true
        } else {
            pending.append(data)
        }
        if !loggedFirstByte {
            loggedFirstByte = true
            log("AUDIO-PREVIEW streaming s16le audio from \(baseURL)/audio/stream")
        }

        let frameBytes = canonicalAudioChannels * 2
        let usable = pending.count - (pending.count % frameBytes)
        guard usable > 0 else { return }
        let chunk = pending.subdata(in: 0..<usable)
        pending.removeSubrange(0..<usable)
        player.enqueue(chunk)
    }

    private func handleDisconnect() {
        guard !stopped else { return }
        player.resetQueue()
        teardownConnection()
        lastDataAt = 0
        connectStartedAt = 0
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped, !reconnectPending else { return }
        reconnectPending = true
        audioQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.stopped else { return }
            self.reconnectPending = false
            if self.connection == nil {
                self.connectStreamNow()
            }
        }
    }
}

final class ModeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Mode
    init(_ mode: Mode) { self.current = mode }
    func get() -> Mode {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    func set(_ mode: Mode) {
        lock.lock()
        current = mode
        lock.unlock()
    }
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let activityToken: NSObjectProtocol = globalActivityToken
    let session = AVCaptureSession()
    let audioSession = AVCaptureSession()
    let captureQueue = DispatchQueue(label: "switch2.capture.session")
    let sampleQueue = DispatchQueue(label: "switch2.capture.frames", qos: .userInteractive)
    let audioQueue = DispatchQueue(label: "switch2.capture.audio", qos: .userInitiated)
    let output = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    let store: FrameStore
    let audioStore: AudioStore
    let modeBox: ModeBox
    var server: HttpServer?
    var previewClient: RemotePreviewClient?
    var audioPlayer: PreviewAudioPlayer?
    var audioClient: RemoteAudioClient?
    var audioMuted = false
    var audioMuteButton: NSButton?
    var recoveryTimer: DispatchSourceTimer?
    var window: NSWindow?
    var videoView: VideoView?
    var selector: NSPopUpButton?
    var availableModes: [Mode] = presetModes
    var device: AVCaptureDevice?
    var audioDevice: AVCaptureDevice?
    var currentInput: AVCaptureDeviceInput?
    var currentAudioInput: AVCaptureDeviceInput?
    private var audioConverter: AVAudioConverter?
    private var audioConverterInputKey = ""
    private var audioCallbackCount = 0
    private var audioPermissionRequestInFlight = false
    var holdsDeviceLock = false
    var mode: Mode {
        get { modeBox.get() }
        set { modeBox.set(newValue) }
    }
    var statusLabel: NSTextField?
    private var lastPreviewLabelAt: TimeInterval = 0
    private var lastWindowTitleDevice: String?

    init(store: FrameStore, audioStore: AudioStore, modeBox: ModeBox, prestartedServer: HttpServer?) {
        self.store = store
        self.audioStore = audioStore
        self.modeBox = modeBox
        self.server = prestartedServer
        super.init()
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = activityToken
        if isPreviewClient {
            launchPreviewClientUI()
            return
        }

        registerCaptureNotifications()
        startCaptureRecoveryWatchdog()

        if headless {
            NSApp.setActivationPolicy(.prohibited)
            begin()
            return
        }

        buildDesktopWindow(isRemotePreview: false)
        begin()
    }

    private func registerCaptureNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(deviceWasDisconnected(_:)), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        nc.addObserver(self, selector: #selector(deviceWasConnected(_:)), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        nc.addObserver(self, selector: #selector(sessionRuntimeError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
        nc.addObserver(self, selector: #selector(sessionWasInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        nc.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)), name: AVCaptureSession.interruptionEndedNotification, object: session)
    }

    private func startCaptureRecoveryWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + 2.5, repeating: 2.5)
        timer.setEventHandler { [weak self] in
            guard let self, !isPreviewClient else { return }
            if self.device == nil {
                self.openCaptureDevice(quietIfMissing: true)
                return
            }
            if !self.session.isRunning {
                log("RECOVERING capture session stopped; restarting…")
                self.session.startRunning()
                if !self.session.isRunning {
                    self.openCaptureDevice(quietIfMissing: true)
                }
                return
            }
            if self.currentAudioInput != nil && self.audioStore.isAvailable() {
                let audio = self.audioStore.statusSnapshot()
                let staleAudio = audio.capturedAtMs <= 0 || Date().timeIntervalSince1970 * 1000 - audio.capturedAtMs > 5_000
                if !self.audioSession.isRunning || staleAudio {
                    log("RECOVERING audio capture stalled; reopening audio session…")
                    self.detachAudioInput(reason: "audio frame stream stalled")
                    if let videoCard = self.device {
                        self.attachAudioInput(videoCard: videoCard)
                    }
                }
            }
            let snap = self.store.snapshot()
            let now = ProcessInfo.processInfo.systemUptime
            if snap.isConnected && snap.lastFrameUptime > 0 && (now - snap.lastFrameUptime) > 5.0 {
                log("RECOVERING capture frame stream stalled (>5s); reopening capture session…")
                self.openCaptureDevice(quietIfMissing: true)
            }
        }
        timer.resume()
        self.recoveryTimer = timer
    }

    private func buildMainMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = appMenu
        menu.addItem(item)
        NSApp.mainMenu = menu
    }

    private func buildDesktopWindow(isRemotePreview: Bool) {
        buildMainMenu()
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 130, width: 1200, height: 725),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = isRemotePreview ? "Switch 2 · Live Preview" : "Switch 2 · Live Capture"
        window.minSize = NSSize(width: 700, height: 440)
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]

        let root = window.contentView!
        let video = VideoView(frame: .zero)
        let initialStatus = isRemotePreview
            ? "Connecting to capture service at \(previewBaseURL)…"
            : "Connecting capture card…"
        let status = NSTextField(labelWithString: initialStatus)
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        var barViews: [NSView] = []
        if isRemotePreview {
            video.configureForRemotePreview()
            let muteButton = NSButton(title: audioMuted ? "Unmute" : "Mute", target: self, action: #selector(toggleAudioMute(_:)))
            muteButton.bezelStyle = .rounded
            self.audioMuteButton = muteButton
            barViews = [status, muteButton]
        } else {
            video.preview.session = session
            let selector = NSPopUpButton(frame: .zero, pullsDown: false)
            selector.addItems(withTitles: availableModes.map(\.title))
            selector.selectItem(at: availableModes.firstIndex(of: mode) ?? 0)
            selector.target = self
            selector.action = #selector(changeMode)
            self.selector = selector
            barViews = [selector, status]
        }

        let controls = NSStackView(views: barViews)
        controls.orientation = .horizontal
        controls.spacing = 18
        controls.alignment = .centerY

        root.addSubview(video)
        root.addSubview(controls)
        video.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            video.topAnchor.constraint(equalTo: root.topAnchor),
            video.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            video.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -10),
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            controls.heightAnchor.constraint(equalToConstant: 26),
        ])

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        self.window = window
        self.videoView = video
        self.statusLabel = status
    }

    private func launchPreviewClientUI() {
        buildDesktopWindow(isRemotePreview: true)
        log("PREVIEW-CLIENT connecting url=\(previewBaseURL)")

        let client = RemotePreviewClient(
            baseURL: previewBaseURL,
            onFrame: { [weak self] cgImage, statusText, remoteDevice in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.videoView?.displayRemoteImage(cgImage)
                    let now = ProcessInfo.processInfo.systemUptime
                    if self.lastPreviewLabelAt == 0 || (now - self.lastPreviewLabelAt) >= 0.25 {
                        self.lastPreviewLabelAt = now
                        self.statusLabel?.stringValue = statusText
                    }
                    if let dev = remoteDevice, dev != self.lastWindowTitleDevice {
                        self.lastWindowTitleDevice = dev
                        self.window?.title = "Switch 2 · Live Preview — \(dev)"
                    }
                }
            },
            onReconnecting: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.lastPreviewLabelAt = 0
                    self.statusLabel?.stringValue = message
                }
            }
        )
        let audioPlayer = PreviewAudioPlayer()
        self.audioPlayer = audioPlayer
        if audioPlayer.setup() {
            let audioClient = RemoteAudioClient(baseURL: previewBaseURL, player: audioPlayer)
            self.audioClient = audioClient
            audioClient.start()
        } else {
            logError("AUDIO-PREVIEW unavailable; video preview continues")
        }
        self.previewClient = client
        client.start()
    }

    func showError(_ text: String) {
        log("ERROR \(text)")
        DispatchQueue.main.async { self.statusLabel?.stringValue = text }
    }

    private func syncSelector(modes: [Mode], selected: Mode, deviceName: String?) {
        DispatchQueue.main.async {
            self.availableModes = modes
            if let selector = self.selector {
                selector.removeAllItems()
                selector.addItems(withTitles: modes.map(\.title))
                if let idx = modes.firstIndex(of: selected) {
                    selector.selectItem(at: idx)
                }
            }
            if let name = deviceName {
                self.window?.title = "Switch 2 · Live Capture — \(name)"
            } else {
                self.window?.title = "Switch 2 · Live Capture"
            }
        }
    }

    private func tearDownCurrentSession() {
        if session.isRunning { session.stopRunning() }
        if holdsDeviceLock {
            device?.unlockForConfiguration()
            holdsDeviceLock = false
        }
        session.beginConfiguration()
        if let input = currentInput {
            session.removeInput(input)
            currentInput = nil
        }
        session.commitConfiguration()
        device = nil
        detachAudioInput(reason: "capture session torn down")
        store.setDisconnected()
    }

    private func detachAudioInput(reason: String) {
        // Audio-only teardown: the video pipeline keeps running untouched.
        if audioSession.isRunning { audioSession.stopRunning() }
        audioSession.beginConfiguration()
        if let input = currentAudioInput {
            audioSession.removeInput(input)
            currentAudioInput = nil
        }
        if audioSession.outputs.contains(audioOutput) {
            audioSession.removeOutput(audioOutput)
        }
        audioSession.commitConfiguration()
        audioDevice = nil
        audioConverter = nil
        audioConverterInputKey = ""
        audioStore.clear()
        audioStore.setUnavailable(reason: reason)
    }

    @objc func deviceWasDisconnected(_ notification: Notification) {
        guard let gone = notification.object as? AVCaptureDevice else { return }
        captureQueue.async {
            if self.audioDevice?.uniqueID == gone.uniqueID {
                log("AUDIO-DISCONNECTED \(gone.localizedName)")
                self.detachAudioInput(reason: "audio device disconnected")
                return
            }
            guard self.device?.uniqueID == gone.uniqueID else { return }
            log("DISCONNECTED \(gone.localizedName)")
            self.tearDownCurrentSession()
            self.syncSelector(modes: presetModes, selected: self.mode, deviceName: nil)
            DispatchQueue.main.async {
                self.statusLabel?.stringValue = "Capture card disconnected; waiting for USB capture card…"
            }
        }
    }

    @objc func deviceWasConnected(_ notification: Notification) {
        captureQueue.async {
            if self.device == nil {
                self.openCaptureDevice()
                return
            }
            if self.currentAudioInput == nil, let videoCard = self.device {
                self.attachAudioInput(videoCard: videoCard)
            }
        }
    }

    @objc func sessionRuntimeError(_ notification: Notification) {
        let errDesc = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown error"
        log("SESSION-RUNTIME-ERROR \(errDesc)")
        DispatchQueue.main.async {
            self.statusLabel?.stringValue = "Capture session error (\(errDesc)); recovering…"
        }
        captureQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !isPreviewClient else { return }
            if self.device != nil {
                self.session.startRunning()
                if self.session.isRunning {
                    log("SESSION-RECOVERED restarted running session")
                    return
                }
            }
            self.openCaptureDevice()
        }
    }

    @objc func sessionWasInterrupted(_ notification: Notification) {
        log("SESSION-INTERRUPTED")
        DispatchQueue.main.async {
            self.statusLabel?.stringValue = "Capture session interrupted; recovering…"
        }
        captureQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !isPreviewClient else { return }
            if self.device != nil && !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    @objc func sessionInterruptionEnded(_ notification: Notification) {
        log("SESSION-INTERRUPTION-ENDED")
        captureQueue.async { [weak self] in
            guard let self, !isPreviewClient else { return }
            if self.device != nil && !self.session.isRunning {
                self.session.startRunning()
            } else if self.device == nil {
                self.openCaptureDevice()
            }
        }
    }

    func begin() {
        captureQueue.async {
            self.openCaptureDevice()
        }
    }

    private func openCaptureDevice(quietIfMissing: Bool = false) {
        do {
            tearDownCurrentSession()
            guard let found = pickCaptureDevice(preferredName: requestedDeviceName) else {
                if !quietIfMissing {
                    if let name = requestedDeviceName, !name.isEmpty, name.lowercased() != "auto" {
                        showError("Capture device \"\(name)\" not found; check the USB connection")
                    } else {
                        showError("No external USB capture card found; check the USB connection")
                    }
                }
                return
            }
            let cardModes = supportedModes(for: found, including: explicitMode)
            var targetMode = self.mode
            if selectFormat(for: found, mode: targetMode) == nil, explicitMode == nil {
                targetMode = cardModes.first(where: { $0 == defaultMode })
                    ?? cardModes.first(where: { $0.width == 1920 && $0.height == 1080 && $0.fpsInt == 60 })
                    ?? cardModes.first
                    ?? defaultMode
            }
            let input = try AVCaptureDeviceInput(device: found)
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                showError("Cannot open capture device \(found.localizedName)")
                return
            }
            session.addInput(input)
            currentInput = input
            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else {
                    session.removeInput(input)
                    currentInput = nil
                    session.commitConfiguration()
                    showError("Cannot attach video output")
                    return
                }
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                output.setSampleBufferDelegate(self, queue: sampleQueue)
                session.addOutput(output)
            }
            session.commitConfiguration()
            self.device = found
            try apply(targetMode)
            session.startRunning()
            try apply(targetMode)
            let menuModes = cardModes.isEmpty ? presetModes : cardModes
            store.setConnected(device: found, mode: targetMode, supportedModes: menuModes)
            syncSelector(modes: menuModes, selected: targetMode, deviceName: found.localizedName)
            log("RUNNING device=\"\(found.localizedName)\" model=\"\(found.modelID)\" mode=\(targetMode.id) supported=[\(menuModes.map(\.id).joined(separator: ","))]")
            attachAudioInput(videoCard: found)
            DispatchQueue.main.async { self.statusLabel?.stringValue = "Capturing (\(found.localizedName) · \(targetMode.title))" }
        } catch {
            tearDownCurrentSession()
            showError(error.localizedDescription)
        }
    }

    private func attachAudioInput(videoCard: AVCaptureDevice) {
        guard currentAudioInput == nil else { return }
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        if authorization == .notDetermined {
            guard !audioPermissionRequestInFlight else { return }
            audioPermissionRequestInFlight = true
            audioStore.setUnavailable(reason: "waiting for audio capture permission")
            log("AUDIO-PERMISSION requesting access")
            DispatchQueue.main.async {
                if headless { NSApp.setActivationPolicy(.regular) }
                NSApp.activate()
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    DispatchQueue.main.async {
                        if headless { NSApp.setActivationPolicy(.prohibited) }
                    }
                    guard let self else { return }
                    self.captureQueue.async {
                        self.audioPermissionRequestInFlight = false
                        guard self.device?.uniqueID == videoCard.uniqueID else { return }
                        if granted {
                            self.attachAudioInput(videoCard: videoCard)
                        } else {
                            self.audioStore.setUnavailable(reason: "audio capture permission denied")
                            log("AUDIO-UNAVAILABLE audio capture permission denied")
                        }
                    }
                }
            }
            return
        }
        guard authorization == .authorized else {
            let reason = "audio capture permission denied; enable microphone access for switch2-capture"
            audioStore.setUnavailable(reason: reason)
            log("AUDIO-UNAVAILABLE \(reason)")
            return
        }
        guard let foundAudio = pickAudioDevice(preferredName: requestedAudioDeviceName, videoCardName: videoCard.localizedName) else {
            let query = requestedAudioDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reason: String
            if !query.isEmpty, query.lowercased() != "auto" {
                reason = "no external audio device matching \"\(query)\""
            } else {
                reason = "no external audio device named \"\(videoCard.localizedName)\""
            }
            audioStore.setUnavailable(reason: reason)
            log("AUDIO-UNAVAILABLE \(reason)")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: foundAudio)
            audioSession.beginConfiguration()
            guard audioSession.canAddInput(input) else {
                audioSession.commitConfiguration()
                throw NSError(domain: "Switch2Capture", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot attach audio input \(foundAudio.localizedName)"
                ])
            }
            audioSession.addInput(input)
            guard audioSession.canAddOutput(audioOutput) else {
                audioSession.removeInput(input)
                audioSession.commitConfiguration()
                throw NSError(domain: "Switch2Capture", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot attach audio output"
                ])
            }
            audioSession.addOutput(audioOutput)
            audioSession.commitConfiguration()
            currentAudioInput = input
            audioDevice = foundAudio
            audioSession.startRunning()
            audioStore.setConnected(device: foundAudio)
            log("AUDIO-RUNNING device=\"\(foundAudio.localizedName)\" id=\"\(foundAudio.uniqueID)\"")
        } catch {
            audioStore.setUnavailable(reason: error.localizedDescription)
            log("AUDIO-UNAVAILABLE \(error.localizedDescription)")
        }
    }

    func apply(_ mode: Mode) throws {
        guard let device = device else { return }
        guard let (format, duration) = selectFormat(for: device, mode: mode) else {
            let available = supportedModes(for: device, including: nil).map(\.shortName).joined(separator: ", ")
            let hint = available.isEmpty ? "" : " (supported: \(available))"
            throw NSError(domain: "Switch2Capture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Capture card \"\(device.localizedName)\" does not support \(mode.title)\(hint)"
            ])
        }
        if !holdsDeviceLock {
            try device.lockForConfiguration()
            holdsDeviceLock = true
        }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        for connection in [output.connection(with: .video)] {
            if let connection, connection.isVideoMinFrameDurationSupported { connection.videoMinFrameDuration = duration }
            if let connection, connection.isVideoMaxFrameDurationSupported { connection.videoMaxFrameDuration = duration }
        }
        self.mode = mode
        store.setMode(mode)
        log("SELECTED \(format) duration=\(CMTimeGetSeconds(duration))")
    }

    @objc func changeMode(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        captureQueue.async {
            let modes = self.store.snapshot().supportedModes
            let list = modes.isEmpty ? presetModes : modes
            guard let selected = list[safe: index] else { return }
            do { try self.apply(selected) }
            catch { self.showError(error.localizedDescription) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            handleAudioSample(sampleBuffer)
            return
        }
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let prevSeq = store.frameSequence
        store.store(pixel)
        if !headless && (prevSeq == 0 || store.frameSequence % 30 == 0) {
            let snap = store.snapshot()
            let dev = snap.deviceName ?? "USB"
            let label = String(
                format: "%@ · %.1f fps · %d × %d · frame #%llu · http://127.0.0.1:%d",
                dev, snap.fps, snap.width, snap.height, snap.frameSequence, httpPort
            )
            DispatchQueue.main.async { self.statusLabel?.stringValue = label }
        }
    }

    @objc func toggleAudioMute(_ sender: NSButton) {
        audioMuted.toggle()
        sender.title = audioMuted ? "Unmute" : "Mute"
        audioPlayer?.setMuted(audioMuted)
    }

    private func audioConverterFor(_ format: AVAudioFormat) -> AVAudioConverter? {
        let asbd = format.streamDescription.pointee
        let key = "\(asbd.mSampleRate)|\(asbd.mFormatID)|\(asbd.mFormatFlags)|\(asbd.mBytesPerPacket)|\(asbd.mFramesPerPacket)|\(asbd.mBytesPerFrame)|\(asbd.mChannelsPerFrame)|\(asbd.mBitsPerChannel)"
        if let converter = audioConverter, audioConverterInputKey == key {
            return converter
        }
        guard let converter = AVAudioConverter(from: format, to: canonicalAudioFormat) else {
            return nil
        }
        audioConverter = converter
        audioConverterInputKey = key
        return converter
    }

    // Runs on the dedicated audioQueue only: bounded per-callback work (one copy in,
    // one conversion out) so the realtime audio callback never blocks the video path.
    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        audioCallbackCount += 1
        let firstCallback = audioCallbackCount == 1
        autoreleasepool {
            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                if firstCallback { log("AUDIO-DROP missing format description") }
                return
            }
            let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
            if firstCallback {
                log("AUDIO-CALLBACK frames=\(CMSampleBufferGetNumSamples(sampleBuffer)) rate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount) format=\(inputFormat.commonFormat.rawValue) interleaved=\(inputFormat.isInterleaved)")
            }
            guard let converter = audioConverterFor(inputFormat) else {
                if firstCallback { log("AUDIO-DROP converter creation failed") }
                audioStore.setUnavailable(reason: "unsupported capture-card audio format; PCM conversion is unavailable")
                return
            }
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0,
                  let source = pcmBuffer(fromSampleBuffer: sampleBuffer, format: inputFormat) else {
                if firstCallback { log("AUDIO-DROP PCM input copy failed") }
                audioStore.setUnavailable(reason: "unsupported or invalid capture-card PCM format; expected interleaved or planar integer/float PCM")
                return
            }
            let ratio = Double(canonicalAudioSampleRate) / max(1, inputFormat.sampleRate)
            let dstCapacity = AVAudioFrameCount((Double(numSamples) * ratio).rounded(.up)) + 16
            guard let destination = AVAudioPCMBuffer(pcmFormat: canonicalAudioFormat, frameCapacity: dstCapacity) else {
                return
            }
            var conversionError: NSError?
            var fed = false
            let status = converter.convert(to: destination, error: &conversionError, withInputFrom: { _, inputStatus in
                if fed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return source
            })
            guard (status == .haveData || status == .inputRanDry), destination.frameLength > 0, let channels = destination.int16ChannelData else {
                if firstCallback { log("AUDIO-DROP conversion status=\(status.rawValue) frames=\(destination.frameLength) error=\(conversionError?.localizedDescription ?? "none")") }
                return
            }
            audioStore.append(
                bytes: UnsafeRawPointer(channels[0]),
                byteCount: Int(destination.frameLength) * canonicalAudioChannels * 2
            )
            if firstCallback { log("AUDIO-PCM frames=\(destination.frameLength) rate=48000 channels=2") }
        }
    }

    private func pcmBuffer(fromSampleBuffer sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }
        var listSize = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard listSize >= MemoryLayout<AudioBufferList>.size else { return nil }
        let listPtr = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPtr.deallocate() }
        let bufferList = listPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        if audioCallbackCount == 1 {
            log("AUDIO-ABLIST status=\(status) blockBytes=\(blockBuffer.map { CMBlockBufferGetDataLength($0) } ?? -1)")
        }
        guard status == noErr, let blockBuffer, CMBlockBufferGetDataLength(blockBuffer) > 0 else {
            return nil
        }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(numSamples)
        let list = UnsafeMutableAudioBufferListPointer(bufferList)
        if audioCallbackCount == 1 {
            log("AUDIO-BUFFERS count=\(list.count) bytes=\(list.map { Int($0.mDataByteSize) }) dataPresent=\(list.map { $0.mData != nil })")
        }
        let channelCount = Int(format.channelCount)
        let copied: Bool
        switch format.commonFormat {
        case .pcmFormatFloat32:
            copied = copyAudioChannels(pcm.floatChannelData, from: list, frames: Int(numSamples), channels: channelCount)
        case .pcmFormatInt16:
            copied = copyAudioChannels(pcm.int16ChannelData, from: list, frames: Int(numSamples), channels: channelCount)
        case .pcmFormatInt32:
            copied = copyAudioChannels(pcm.int32ChannelData, from: list, frames: Int(numSamples), channels: channelCount)
        default:
            copied = false
        }
        return copied ? pcm : nil
    }

    private func copyAudioChannels<T>(_ destination: UnsafePointer<UnsafeMutablePointer<T>>?, from list: UnsafeMutableAudioBufferListPointer, frames: Int, channels: Int) -> Bool {
        guard let destination, frames > 0, channels > 0, list.count >= 1 else { return false }
        let sampleSize = MemoryLayout<T>.size
        if list.count == 1 {
            guard let src = list[0].mData else { return false }
            let needed = frames * channels * sampleSize
            guard list[0].mDataByteSize >= needed else { return false }
            memcpy(destination[0], src, needed)
            return true
        }
        guard list.count >= channels else { return false }
        for channel in 0..<channels {
            guard let src = list[channel].mData else { return false }
            let needed = frames * sampleSize
            guard list[channel].mDataByteSize >= needed else { return false }
            memcpy(destination[channel], src, needed)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !headless
    }

    func applicationWillTerminate(_ notification: Notification) {
        recoveryTimer?.cancel()
        recoveryTimer = nil
        audioClient?.stop()
        audioClient = nil
        audioPlayer?.shutdown()
        audioPlayer = nil
        previewClient?.stop()
        previewClient = nil
        server?.stop()
        server = nil
        if !isPreviewClient {
            captureQueue.sync {
                tearDownCurrentSession()
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

let sharedStore = FrameStore()
let sharedAudioStore = AudioStore()
let sharedModeBox = ModeBox(initialMode)
var prestartedHttpServer: HttpServer?

// Bind HTTP listener BEFORE initializing NSApplication or touching UVC hardware in capture mode.
if !isPreviewClient {
    do {
        let srv = try HttpServer(port: httpPort, store: sharedStore, audioStore: sharedAudioStore, fallbackModeProvider: {
            sharedModeBox.get()
        })
        switch srv.startAndWaitReady(timeout: 2.0) {
        case .success:
            prestartedHttpServer = srv
        case .failure(let error):
            logError("ERROR \(error.localizedDescription)")
            exit(1)
        }
    } catch {
        logError("ERROR Failed to initialize HTTP server on 127.0.0.1:\(httpPort): \(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = App(store: sharedStore, audioStore: sharedAudioStore, modeBox: sharedModeBox, prestartedServer: prestartedHttpServer)
app.setActivationPolicy((headless && !isPreviewClient) ? .prohibited : .regular)
app.delegate = delegate
app.run()
