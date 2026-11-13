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
    options: [.userInitiated, .latencyCritical],
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
    let preview = AVCaptureVideoPreviewLayer()
    let remoteLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

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

        layer?.addSublayer(preview)
        layer?.addSublayer(remoteLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configureForRemotePreview() {
        preview.session = nil
        preview.isHidden = true
        remoteLayer.isHidden = false
    }

    func displayRemoteImage(_ image: CGImage) {
        remoteLayer.contents = image
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
    let fallbackModeProvider: @Sendable () -> Mode
    let context = CIContext(options: [
        .cacheIntermediates: false,
    ])
    let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let listenerQueue = DispatchQueue(label: "switch2.http.listener")
    let streamQueue = DispatchQueue(label: "switch2.http.stream", qos: .userInteractive)
    private let activeStreamsLock = NSLock()
    private var activeStreams: [ObjectIdentifier: MjpegStreamSession] = [:]

    init(port: UInt16, store: FrameStore, fallbackModeProvider: @escaping @Sendable () -> Mode) throws {
        self.port = port
        self.store = store
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
    }

    fileprivate func unregisterStream(_ session: MjpegStreamSession) {
        activeStreamsLock.lock()
        activeStreams.removeValue(forKey: ObjectIdentifier(session))
        activeStreamsLock.unlock()
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
}

final class RemotePreviewClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let baseURL: String
    let onFrame: @Sendable (CGImage, String, String?) -> Void
    let onReconnecting: @Sendable (String) -> Void

    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "switch2.preview.stream"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private var urlSession: URLSession?
    private var streamTask: URLSessionDataTask?
    private var statusTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var stopped = false
    private var reconnectPending = false
    private var streamActive = false
    private var buffer = Data()
    private var boundary = "frame"
    private var lastFrameAt: TimeInterval = 0

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
        super.init()
    }

    func start() {
        delegateQueue.addOperation { [weak self] in
            guard let self, !self.stopped else { return }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 2.5
            config.timeoutIntervalForResource = 604800
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: self.delegateQueue)

            self.startTimers()
            self.connectStreamNow()
            self.pollRemoteStatus()
        }
    }

    func stop() {
        delegateQueue.addOperation { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.statusTimer?.cancel()
            self.statusTimer = nil
            self.watchdogTimer?.cancel()
            self.watchdogTimer = nil
            self.streamTask?.cancel()
            self.streamTask = nil
            self.urlSession?.invalidateAndCancel()
            self.urlSession = nil
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

        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        watchdog.schedule(deadline: .now() + 1.0, repeating: 0.5)
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            self.delegateQueue.addOperation { [weak self] in
                guard let self, !self.stopped else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.streamActive && self.lastFrameAt > 0 && (now - self.lastFrameAt) > 2.2 {
                    self.handleDisconnect()
                }
            }
        }
        watchdog.resume()
        self.watchdogTimer = watchdog
    }

    private func pollRemoteStatus() {
        if let status = probeCaptureServiceStatus(baseURL: baseURL, timeout: 0.4) {
            delegateQueue.addOperation { [weak self] in
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
        guard !stopped, let urlSession else { return }
        reconnectPending = false
        streamTask?.cancel()
        buffer.removeAll(keepingCapacity: true)
        boundary = "frame"

        guard let streamURL = URL(string: "\(baseURL)/stream?fps=60") else {
            onReconnecting("Invalid capture service URL: \(baseURL)")
            return
        }
        var req = URLRequest(url: streamURL)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 2.5
        let task = urlSession.dataTask(with: req)
        self.streamTask = task
        task.resume()
    }

    private func handleDisconnect() {
        guard !stopped else { return }
        streamActive = false
        measuredFpsStart = 0
        measuredFpsCount = 0
        measuredFps = 0
        streamTask?.cancel()
        streamTask = nil
        buffer.removeAll(keepingCapacity: true)
        onReconnecting("Reconnecting to capture service… (\(baseURL))")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped, !reconnectPending else { return }
        reconnectPending = true
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.delegateQueue.addOperation { [weak self] in
                guard let self, !self.stopped else { return }
                self.reconnectPending = false
                if self.streamTask == nil {
                    self.connectStreamNow()
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard dataTask === streamTask, !stopped else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            completionHandler(.cancel)
            handleDisconnect()
            return
        }
        if let contentType = http.value(forHTTPHeaderField: "Content-Type"),
           let parsedBoundary = extractBoundary(from: contentType) {
            boundary = parsedBoundary
        }
        buffer.removeAll(keepingCapacity: true)
        lastFrameAt = ProcessInfo.processInfo.systemUptime
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === streamTask, !stopped, !data.isEmpty else { return }
        buffer.append(data)
        if buffer.count > 32 * 1024 * 1024 {
            handleDisconnect()
            return
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

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === streamTask, !stopped else { return }
        handleDisconnect()
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

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let activityToken: NSObjectProtocol = globalActivityToken
    let session = AVCaptureSession()
    let captureQueue = DispatchQueue(label: "switch2.capture.session")
    let sampleQueue = DispatchQueue(label: "switch2.capture.frames", qos: .userInteractive)
    let output = AVCaptureVideoDataOutput()
    let store: FrameStore
    let modeBox: ModeBox
    var server: HttpServer?
    var previewClient: RemotePreviewClient?
    var recoveryTimer: DispatchSourceTimer?
    var window: NSWindow?
    var videoView: VideoView?
    var selector: NSPopUpButton?
    var availableModes: [Mode] = presetModes
    var device: AVCaptureDevice?
    var currentInput: AVCaptureDeviceInput?
    var holdsDeviceLock = false
    var mode: Mode {
        get { modeBox.get() }
        set { modeBox.set(newValue) }
    }
    var statusLabel: NSTextField?
    private var lastPreviewLabelAt: TimeInterval = 0
    private var lastWindowTitleDevice: String?

    init(store: FrameStore, modeBox: ModeBox, prestartedServer: HttpServer?) {
        self.store = store
        self.modeBox = modeBox
        self.server = prestartedServer
        super.init()
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
            barViews = [status]
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
        store.setDisconnected()
    }

    @objc func deviceWasDisconnected(_ notification: Notification) {
        guard let gone = notification.object as? AVCaptureDevice else { return }
        captureQueue.async {
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
            guard self.device == nil else { return }
            self.openCaptureDevice()
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
            DispatchQueue.main.async { self.statusLabel?.stringValue = "Capturing (\(found.localizedName) · \(targetMode.title))" }
        } catch {
            tearDownCurrentSession()
            showError(error.localizedDescription)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !headless
    }

    func applicationWillTerminate(_ notification: Notification) {
        recoveryTimer?.cancel()
        recoveryTimer = nil
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
let sharedModeBox = ModeBox(initialMode)
var prestartedHttpServer: HttpServer?

// Bind HTTP listener BEFORE initializing NSApplication or touching UVC hardware in capture mode.
if !isPreviewClient {
    do {
        let srv = try HttpServer(port: httpPort, store: sharedStore, fallbackModeProvider: {
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
let delegate = App(store: sharedStore, modeBox: sharedModeBox, prestartedServer: prestartedHttpServer)
app.setActivationPolicy((headless && !isPreviewClient) ? .prohibited : .regular)
app.delegate = delegate
app.run()
