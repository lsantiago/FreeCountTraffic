import CoreImage
import CoreMedia
import CryptoKit
import Foundation
import VideoToolbox

/// RTSP stream (IP camera) -> frames, without third-party libraries: RTSP with RTP interleaved over TCP (like the
/// Android app, which forces TCP), H.264 / H.265 depacketizing and the hardware decoder (VideoToolbox).
/// Supports Basic and Digest authentication (`rtsp://user:pass@host:554/path`). Once the stream has played, a dropped
/// connection is retried every few seconds until `stop()`.
final class RtspSource: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    func start(url: String, onFrame: @escaping @Sendable (CGImage, Int64) -> Void, onStatus: @escaping @Sendable (String?) -> Void) {
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()
        let alive: @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.generation == gen
        }
        let thread = Thread {
            RtspWorker(url: url, alive: alive, onFrame: onFrame, onStatus: onStatus).run()
        }
        thread.name = "freecount.rtsp"
        thread.start()
    }

    func stop() {
        lock.lock()
        generation += 1
        lock.unlock()
    }
}

struct RtspError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

// MARK: - session

private final class RtspWorker {
    private let url: String
    private let alive: @Sendable () -> Bool
    private let onStatus: @Sendable (String?) -> Void
    private let frames: LatestFrame
    private var played = false
    private var reportedLive = false
    // continuous timeline in RTP clock ticks across packets and reconnects (wall clock when the RTP clock jumps)
    private var ticks: Int64 = 0
    private var prevTs: UInt32?
    private var prevWallMs: Int64 = 0

    init(url: String, alive: @escaping @Sendable () -> Bool, onFrame: @escaping @Sendable (CGImage, Int64) -> Void, onStatus: @escaping @Sendable (String?) -> Void) {
        self.url = url
        self.alive = alive
        self.onStatus = onStatus
        frames = LatestFrame(alive: alive, onFrame: onFrame)
    }

    func run() {
        while alive() {
            do {
                try session()
            } catch {
                guard alive() else { return }
                reportedLive = false
                let text = error.localizedDescription
                if !played { onStatus("RTSP: \(text)"); return }
                onStatus("RTSP connection lost (\(text)). Reconnecting…")
                for _ in 0..<30 where alive() { Thread.sleep(forTimeInterval: 0.1) }
            }
        }
    }

    private func session() throws {
        guard var comps = URLComponents(string: url), comps.scheme?.lowercased() == "rtsp", let host = comps.host, !host.isEmpty else {
            throw RtspError("invalid URL. Use rtsp://user:pass@host:554/path")
        }
        let auth = RtspAuth(user: comps.user ?? "", password: comps.password ?? "")
        comps.user = nil
        comps.password = nil
        let requestUrl = comps.string ?? url
        let socket = try RtspSocket(host: host, port: UInt16(comps.port ?? 554), alive: alive)
        defer { socket.close() }
        let client = RtspClient(socket: socket, auth: auth)

        let options = try? client.request("OPTIONS", requestUrl)
        let keepAliveMethod = (options?.headers["public"] ?? "").uppercased().contains("GET_PARAMETER") ? "GET_PARAMETER" : "OPTIONS"

        let describe = try client.request("DESCRIBE", requestUrl, ["Accept: application/sdp"])
        let base = describe.headers["content-base"] ?? describe.headers["content-location"] ?? requestUrl
        let track = try SdpTrack.parse(describe.body, base: base)

        let setup = try client.request("SETUP", track.control, ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1"])
        guard let sessionHeader = setup.headers["session"] else { throw RtspError("the camera returned no session") }
        let parts = sessionHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        client.session = parts.first
        let timeout = parts.first(where: { $0.lowercased().hasPrefix("timeout=") }).flatMap { Double($0.dropFirst(8)) } ?? 60
        var rtpChannel: UInt8 = 0
        if let t = setup.headers["transport"], let r = t.range(of: "interleaved=") {
            rtpChannel = UInt8(t[r.upperBound...].prefix(while: { $0.isNumber })) ?? 0
        }
        _ = try client.request("PLAY", base, ["Range: npt=0.000-"])

        let depacketizer = Depacketizer(codec: track.codec)
        let decoder = FrameDecoder(codec: track.codec, parameterSets: track.parameterSets)
        let keepAliveEvery = max(timeout / 2, 5)
        var lastKeepAlive = Date()

        while alive() {
            if Date().timeIntervalSince(lastKeepAlive) > keepAliveEvery {
                try client.send(keepAliveMethod, base)
                lastKeepAlive = Date()
            }
            let first = try socket.readByte()
            if first == 0x24 { // '$': interleaved binary packet
                let channel = try socket.readByte()
                let packet = try socket.read(Int(try socket.readUInt16()))
                guard channel == rtpChannel else { continue } // RTCP
                for unit in depacketizer.push(packet, payloadType: track.payloadType) {
                    guard let image = decoder.decode(unit.nalus, dropUntilKeyframe: unit.damaged) else { continue }
                    played = true
                    if !reportedLive { reportedLive = true; onStatus(nil) }
                    frames.submit(image, tMs: timelineMs(unit.timestamp, clockRate: track.clockRate))
                }
            } else if first == 0x52 { // 'R': a reply (keep-alive) arriving between packets
                _ = try client.readResponse(firstByte: first)
            }
            // anything else: lost sync, skip bytes until the next '$'
        }
    }

    private func timelineMs(_ ts: UInt32, clockRate: Int64) -> Int64 {
        let wall = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        if let p = prevTs {
            let d = Int64(Int32(bitPattern: ts &- p))
            if d >= 0 && d < 5 * clockRate {
                ticks += d
            } else {
                ticks += (wall - prevWallMs) * clockRate / 1000 // camera restarted its clock or packets were lost for long
            }
        }
        prevTs = ts
        prevWallMs = wall
        return ticks * 1000 / clockRate
    }
}

/// Keeps only the newest decoded frame and analyses it on its own queue, so a slow detector drops frames instead of
/// letting the stream fall behind real time.
private final class LatestFrame: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "freecount.rtsp.frames")
    private let alive: @Sendable () -> Bool
    private let onFrame: @Sendable (CGImage, Int64) -> Void
    private var pending: (CVPixelBuffer, Int64)?
    private var busy = false

    init(alive: @escaping @Sendable () -> Bool, onFrame: @escaping @Sendable (CGImage, Int64) -> Void) {
        self.alive = alive
        self.onFrame = onFrame
    }

    func submit(_ buffer: CVPixelBuffer, tMs: Int64) {
        lock.lock()
        pending = (buffer, tMs)
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [self] in
            while true {
                lock.lock()
                guard let next = pending else { busy = false; lock.unlock(); return }
                pending = nil
                lock.unlock()
                if alive(), let cg = makeFrame(CIImage(cvPixelBuffer: next.0)) { onFrame(cg, next.1) }
            }
        }
    }
}

// MARK: - RTSP messages

private struct RtspAuth {
    let user: String
    let password: String
}

private struct RtspResponse {
    let status: Int
    let headers: [String: String] // lowercased names
    let challenges: [String]      // every WWW-Authenticate value
    let body: String
}

private final class RtspClient {
    private let socket: RtspSocket
    private let auth: RtspAuth
    private var cseq = 0
    private var challenge: String?
    private var nonceCount = 0
    var session: String?

    init(socket: RtspSocket, auth: RtspAuth) {
        self.socket = socket
        self.auth = auth
    }

    /// Sends a request and waits for its reply, answering one authentication challenge.
    func request(_ method: String, _ uri: String, _ headers: [String] = []) throws -> RtspResponse {
        try send(method, uri, headers)
        var reply = try readResponse(firstByte: nil)
        if reply.status == 401, challenge == nil, !auth.user.isEmpty {
            challenge = reply.challenges.first(where: { $0.lowercased().hasPrefix("digest") }) ?? reply.challenges.first
            if challenge != nil {
                try send(method, uri, headers)
                reply = try readResponse(firstByte: nil)
            }
        }
        switch reply.status {
        case 200..<300: return reply
        case 401: throw RtspError(auth.user.isEmpty ? "the camera needs a user and password (rtsp://user:pass@host/…)" : "wrong user or password")
        case 404: throw RtspError("stream path not found (404). Check the path after the address")
        default: throw RtspError("\(method) failed with status \(reply.status)")
        }
    }

    func send(_ method: String, _ uri: String, _ headers: [String] = []) throws {
        cseq += 1
        var lines = ["\(method) \(uri) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: FreeCountTraffic"]
        if let a = authorization(method, uri) { lines.append("Authorization: \(a)") }
        if let session { lines.append("Session: \(session)") }
        lines += headers
        try socket.write(lines.joined(separator: "\r\n") + "\r\n\r\n")
    }

    /// Reads the next reply, skipping RTP packets that arrive before it.
    func readResponse(firstByte: UInt8?) throws -> RtspResponse {
        var first = firstByte
        while true {
            let b = try first ?? socket.readByte()
            first = nil
            if b == 0x24 {
                _ = try socket.readByte()
                _ = try socket.read(Int(try socket.readUInt16()))
                continue
            }
            let statusLine = String(UnicodeScalar(b)) + (try socket.readLine())
            guard statusLine.hasPrefix("RTSP/") else { continue }
            let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
            var headers: [String: String] = [:]
            var challenges: [String] = []
            while true {
                let line = try socket.readLine()
                if line.isEmpty { break }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
                if name == "www-authenticate" { challenges.append(value) }
            }
            let length = Int(headers["content-length"] ?? "") ?? 0
            let body = length > 0 ? String(decoding: try socket.read(length), as: UTF8.self) : ""
            return RtspResponse(status: status, headers: headers, challenges: challenges, body: body)
        }
    }

    private func authorization(_ method: String, _ uri: String) -> String? {
        guard let challenge else { return nil }
        if challenge.lowercased().hasPrefix("basic") {
            return "Basic " + Data("\(auth.user):\(auth.password)".utf8).base64EncodedString()
        }
        let p = Self.params(challenge)
        let realm = p["realm"] ?? ""
        let nonce = p["nonce"] ?? ""
        let ha1 = Self.md5("\(auth.user):\(realm):\(auth.password)")
        let ha2 = Self.md5("\(method):\(uri)")
        var out = "Digest username=\"\(auth.user)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\""
        if let qop = p["qop"], qop.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "auth" }) {
            nonceCount += 1
            let nc = String(format: "%08x", nonceCount)
            let cnonce = String(UUID().uuidString.prefix(8))
            out += ", qop=auth, nc=\(nc), cnonce=\"\(cnonce)\", response=\"\(Self.md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)"))\""
        } else {
            out += ", response=\"\(Self.md5("\(ha1):\(nonce):\(ha2)"))\""
        }
        if let opaque = p["opaque"] { out += ", opaque=\"\(opaque)\"" }
        return out
    }

    /// `Digest realm="x", nonce="y", qop="auth"` -> [realm: x, nonce: y, qop: auth]
    private static func params(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        let body = header.drop(while: { $0 != " " })
        var i = body.startIndex
        while i < body.endIndex {
            while i < body.endIndex, body[i] == " " || body[i] == "," { i = body.index(after: i) }
            guard let eq = body[i...].firstIndex(of: "=") else { break }
            let key = body[i..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            i = body.index(after: eq)
            var value = ""
            if i < body.endIndex, body[i] == "\"" {
                i = body.index(after: i)
                let end = body[i...].firstIndex(of: "\"") ?? body.endIndex
                value = String(body[i..<end])
                i = end < body.endIndex ? body.index(after: end) : end
            } else {
                let end = body[i...].firstIndex(of: ",") ?? body.endIndex
                value = body[i..<end].trimmingCharacters(in: .whitespaces)
                i = end
            }
            out[key] = value
        }
        return out
    }

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - SDP

private enum VideoCodec { case h264, h265 }

private struct SdpTrack {
    let codec: VideoCodec
    let payloadType: UInt8
    let clockRate: Int64
    let control: String
    let parameterSets: [[UInt8]]

    /// First H.264 / H.265 video track of the session description.
    static func parse(_ sdp: String, base: String) throws -> SdpTrack {
        var inVideo = false
        var seenCodec: String?
        var pt: UInt8?
        var codec: VideoCodec?
        var clock: Int64 = 90000
        var control: String?
        var fmtp: [String: String] = [:]
        for raw in sdp.split(whereSeparator: \.isNewline) { // "\r\n" is a single Character
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                if codec != nil { break }
                inVideo = line.hasPrefix("m=video")
                control = nil
                fmtp = [:]
                continue
            }
            guard inVideo else { continue }
            if line.hasPrefix("a=rtpmap:") {
                let parts = line.dropFirst(9).split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let enc = parts[1].split(separator: "/")
                let name = enc.first.map { $0.uppercased() } ?? ""
                seenCodec = name
                if name == "H264" || name == "H265" || name == "HEVC" {
                    codec = name == "H264" ? .h264 : .h265
                    pt = UInt8(parts[0])
                    if enc.count > 1, let c = Int64(enc[1]) { clock = c }
                }
            } else if line.hasPrefix("a=fmtp:") {
                for kv in line.drop(while: { $0 != " " }).split(separator: ";") {
                    let pair = kv.split(separator: "=", maxSplits: 1)
                    if pair.count == 2 { fmtp[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = String(pair[1]).trimmingCharacters(in: .whitespaces) }
                }
            } else if line.hasPrefix("a=control:") {
                control = String(line.dropFirst(10))
            }
        }
        guard let codec, let pt else {
            throw RtspError(seenCodec.map { "unsupported video codec \($0). Set the camera to H.264 or H.265" } ?? "no video in this stream")
        }
        let b64 = codec == .h264
            ? (fmtp["sprop-parameter-sets"] ?? "").split(separator: ",").map(String.init)
            : ["sprop-vps", "sprop-sps", "sprop-pps"].compactMap { fmtp[$0] }
        let sets = b64.compactMap { Data(base64Encoded: $0).map { [UInt8]($0) } }
        return SdpTrack(codec: codec, payloadType: pt, clockRate: clock, control: resolve(control ?? "", base: base), parameterSets: sets)
    }

    private static func resolve(_ control: String, base: String) -> String {
        if control.isEmpty || control == "*" { return base }
        if control.lowercased().hasPrefix("rtsp://") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }
}

// MARK: - RTP -> access units

private struct AccessUnit {
    let nalus: [[UInt8]]
    let timestamp: UInt32
    let damaged: Bool
}

private final class Depacketizer {
    private let codec: VideoCodec
    private var nalus: [[UInt8]] = []
    private var fragment: [UInt8]?
    private var timestamp: UInt32?
    private var lastSeq: UInt16?
    private var damaged = false

    init(codec: VideoCodec) { self.codec = codec }

    func push(_ p: [UInt8], payloadType: UInt8) -> [AccessUnit] {
        guard p.count >= 12, p[0] >> 6 == 2, p[1] & 0x7F == payloadType else { return [] }
        let marker = p[1] & 0x80 != 0
        let seq = UInt16(p[2]) << 8 | UInt16(p[3])
        let ts = UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7])
        var start = 12 + 4 * Int(p[0] & 0x0F)
        if p[0] & 0x10 != 0 {
            guard p.count >= start + 4 else { return [] }
            start += 4 + 4 * (Int(p[start + 2]) << 8 | Int(p[start + 3]))
        }
        var end = p.count
        if p[0] & 0x20 != 0 { end -= Int(p[end - 1]) }
        guard start < end else { return [] }

        var out: [AccessUnit] = []
        let gap = lastSeq.map { seq != $0 &+ 1 } ?? false
        lastSeq = seq
        if let t = timestamp, t != ts {
            // the previous frame never got its marker packet
            if gap { damaged = true }
            if let unit = flush() { out.append(unit) }
        }
        if gap { fragment = nil; damaged = true }
        timestamp = ts

        let payload = Array(p[start..<end])
        if codec == .h264 { h264(payload) } else { h265(payload) }
        if marker, let unit = flush() { out.append(unit) }
        return out
    }

    private func flush() -> AccessUnit? {
        defer { nalus = []; damaged = false; fragment = nil }
        guard !nalus.isEmpty, let ts = timestamp else { return nil }
        return AccessUnit(nalus: nalus, timestamp: ts, damaged: damaged)
    }

    private func aggregated(_ p: [UInt8], from: Int) {
        var i = from
        while i + 2 <= p.count {
            let size = Int(p[i]) << 8 | Int(p[i + 1])
            i += 2
            guard size > 0, i + size <= p.count else { return }
            nalus.append(Array(p[i..<i + size]))
            i += size
        }
    }

    private func fragmentPart(_ header: [UInt8], _ p: [UInt8], from: Int, first: Bool, last: Bool) {
        if first { fragment = header + p[from...] } else if fragment != nil { fragment! += p[from...] }
        if last, let f = fragment { nalus.append(f); fragment = nil }
    }

    private func h264(_ p: [UInt8]) {
        switch p[0] & 0x1F {
        case 1...23: nalus.append(p)
        case 24: aggregated(p, from: 1) // STAP-A
        case 28: // FU-A
            guard p.count > 2 else { return }
            fragmentPart([(p[0] & 0xE0) | (p[1] & 0x1F)], p, from: 2, first: p[1] & 0x80 != 0, last: p[1] & 0x40 != 0)
        default: break
        }
    }

    private func h265(_ p: [UInt8]) {
        guard p.count > 2 else { return }
        switch (p[0] >> 1) & 0x3F {
        case 0..<48: nalus.append(p)
        case 48: aggregated(p, from: 2) // aggregation packet
        case 49: // fragmentation unit
            guard p.count > 3 else { return }
            fragmentPart([(p[0] & 0x81) | ((p[2] & 0x3F) << 1), p[1]], p, from: 3, first: p[2] & 0x80 != 0, last: p[2] & 0x40 != 0)
        default: break
        }
    }
}

// MARK: - decoding

private final class FrameDecoder {
    private let codec: VideoCodec
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var formatDirty = true
    private var needKeyframe = true

    init(codec: VideoCodec, parameterSets: [[UInt8]]) {
        self.codec = codec
        for s in parameterSets where !s.isEmpty { _ = store(s) }
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    private func nalType(_ nal: [UInt8]) -> Int { codec == .h264 ? Int(nal[0] & 0x1F) : Int((nal[0] >> 1) & 0x3F) }

    /// Keeps a parameter set; true when the NAL was one.
    private func store(_ nal: [UInt8]) -> Bool {
        let t = nalType(nal)
        let slot: ReferenceWritableKeyPath<FrameDecoder, [UInt8]?>
        switch (codec, t) {
        case (.h264, 7), (.h265, 33): slot = \.sps
        case (.h264, 8), (.h265, 34): slot = \.pps
        case (.h265, 32): slot = \.vps
        default: return false
        }
        if self[keyPath: slot] != nal { self[keyPath: slot] = nal; formatDirty = true }
        return true
    }

    func decode(_ nalus: [[UInt8]], dropUntilKeyframe: Bool) -> CVPixelBuffer? {
        if dropUntilKeyframe { needKeyframe = true }
        var frame: [[UInt8]] = []
        var keyframe = false
        for nal in nalus where !nal.isEmpty {
            if store(nal) { continue }
            let t = nalType(nal)
            if (codec == .h264 ? t == 9 : t == 35) { continue } // access unit delimiter
            if (codec == .h264 ? t == 5 : (16...21).contains(t)) { keyframe = true }
            frame.append(nal)
        }
        guard !frame.isEmpty else { return nil }
        if needKeyframe && !keyframe { return nil }
        if formatDirty && !rebuild() { return nil }
        guard let session, let format else { return nil }

        var data = Data()
        for nal in frame {
            var n = UInt32(nal.count).bigEndian
            data.append(Data(bytes: &n, count: 4))
            data.append(contentsOf: nal)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        var output: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { output = image }
        }
        if status != noErr {
            // e.g. the decoder was torn down while the app was in the background: start over at the next keyframe
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            formatDirty = true
            needKeyframe = true
            return nil
        }
        if keyframe { needKeyframe = false }
        return output
    }

    private func rebuild() -> Bool {
        let sets = codec == .h264 ? [sps, pps] : [vps, sps, pps]
        guard sets.allSatisfy({ $0 != nil }) else { return false }
        let bytes = sets.map { $0! }
        let pointers = bytes.map { s -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
            p.initialize(from: s, count: s.count)
            return p
        }
        defer { pointers.forEach { $0.deallocate() } }
        let constPointers = pointers.map { UnsafePointer($0) }
        let sizes = bytes.map { $0.count }
        var desc: CMFormatDescription?
        let status = codec == .h264
            ? CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: bytes.count,
                                                                  parameterSetPointers: constPointers, parameterSetSizes: sizes,
                                                                  nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            : CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: bytes.count,
                                                                  parameterSetPointers: constPointers, parameterSetSizes: sizes,
                                                                  nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
        guard status == noErr, let desc else { return false }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        var created: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: desc, decoderSpecification: nil,
                                           imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &created) == noErr,
              let created else { return false }
        format = desc
        session = created
        formatDirty = false
        needKeyframe = true
        return true
    }
}

// MARK: - socket

/// Blocking TCP socket with timeouts; reads give up after `idleTimeout` without data or when the source is stopped.
private final class RtspSocket {
    private var fd: Int32 = -1
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var start = 0
    private var end = 0
    private let alive: @Sendable () -> Bool
    private let idleTimeout: TimeInterval = 10

    init(host: String, port: UInt16, alive: @escaping @Sendable () -> Bool) throws {
        self.alive = alive
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, list != nil else { throw RtspError("unknown host \(host)") }
        defer { freeaddrinfo(list) }
        var ai = list
        while let a = ai, fd < 0 {
            ai = a.pointee.ai_next
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s < 0 { continue }
            if Self.connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen, timeoutMs: 5000) { fd = s } else { Darwin.close(s) }
        }
        guard fd >= 0 else { throw RtspError("could not connect to \(host):\(port)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        tv.tv_sec = 5
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func connect(_ s: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: socklen_t, timeoutMs: Int32) -> Bool {
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(s, F_SETFL, flags) }
        if Darwin.connect(s, addr, len) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, timeoutMs) == 1 else { return false }
        var err: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &errLen)
        return err == 0
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    func write(_ text: String) throws {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { throw RtspError("connection closed") }
            sent += n
        }
    }

    private func fill() throws {
        let since = Date()
        while true {
            guard alive() else { throw CancellationError() }
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            let err = errno
            if n > 0 { start = 0; end = n; return }
            if n == 0 { throw RtspError("the camera closed the connection") }
            guard err == EAGAIN || err == EWOULDBLOCK || err == EINTR else { throw RtspError("connection error \(err)") }
            if Date().timeIntervalSince(since) > idleTimeout { throw RtspError("no data for \(Int(idleTimeout)) s") }
        }
    }

    func readByte() throws -> UInt8 {
        if start == end { try fill() }
        start += 1
        return buffer[start - 1]
    }

    func readUInt16() throws -> UInt16 {
        let hi = try readByte()
        let lo = try readByte()
        return UInt16(hi) << 8 | UInt16(lo)
    }

    func read(_ count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            if start == end { try fill() }
            let take = min(count - out.count, end - start)
            out += buffer[start..<start + take]
            start += take
        }
        return out
    }

    /// One CRLF-terminated line, without the line break.
    func readLine() throws -> String {
        var bytes = [UInt8]()
        while true {
            let b = try readByte()
            if b == 0x0A { break }
            if b != 0x0D { bytes.append(b) }
            if bytes.count > 8192 { throw RtspError("invalid reply") }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
