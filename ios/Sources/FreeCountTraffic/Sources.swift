import AVFoundation
import CoreImage
import Foundation
import ImageIO

let maxFrameSide: CGFloat = 640

let sharedCIContext = CIContext()

/// A frame to analyse: the source's own pixel buffer, read by the detector with no conversion. It becomes a picture
/// only when it is shown or a counted vehicle's photo is cut from it.
struct FrameInput: @unchecked Sendable {
    let buffer: CVPixelBuffer
    /// How to turn the buffer upright (videos recorded with the phone upright are stored sideways).
    let orientation: CGImagePropertyOrientation
    /// Timestamp in ms on a monotonic clock (video position or camera presentation time).
    let tMs: Int64

    /// The upright frame for Core Image (origin at the bottom left).
    var image: CIImage { CIImage(cvPixelBuffer: buffer).oriented(orientation) }

    /// Width / height as shown.
    var aspect: Float {
        let e = image.extent
        return Float(e.width / max(e.height, 1))
    }

    /// Downscaled picture for the screen.
    func displayImage() -> CGImage? { makeFrame(image) }
}

/// Downscales so the longest side is `maxFrameSide` and renders to a CGImage.
func makeFrame(_ input: CIImage) -> CGImage? {
    var image = input
    let longest = max(image.extent.width, image.extent.height)
    if longest > maxFrameSide {
        let s = maxFrameSide / longest
        image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }
    return sharedCIContext.createCGImage(image, from: image.extent)
}

/// Back camera -> frames (the camera's own buffers). Runs on its own queue.
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "freecount.camera")
    private var onFrame: (@Sendable (FrameInput) -> Void)?
    private var running = false

    func start(onFrame: @escaping @Sendable (FrameInput) -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.onFrame = onFrame
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun(onError)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                if ok { self?.configureAndRun(onError) } else { DispatchQueue.main.async { onError("Camera permission denied.") } }
            }
        default:
            DispatchQueue.main.async { onError("Camera permission denied. Enable it in Settings.") }
        }
    }

    private func configureAndRun(_ onError: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            if running { return }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { onError("No camera available on this device.") }
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            if let connection = output.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                } else if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
            session.commitConfiguration()
            session.startRunning()
            running = true
        }
    }

    func stop() {
        queue.async { [self] in
            if running { session.stopRunning() }
            running = false
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ms = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000)
        onFrame?(FrameInput(buffer: buffer, orientation: .up, tMs: ms))
    }
}

enum VideoSource {
    /// When the device falls behind real time, still analyse at least one frame per `stepMs` of video (tracking needs it).
    static let stepMs: Int64 = 100
    /// Never analyse more than ~33 frames per second of video.
    static let minGapMs: Int64 = 30

    /// First frame of the video, to place boxes before the run.
    static func firstFrame(_ url: URL) async -> CGImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: maxFrameSide, height: maxFrameSide)
        return try? await g.image(at: .zero).image
    }

    private static func orientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return .right }
        if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return .left }
        if t.a == -1 && t.d == -1 { return .down }
        return .up
    }

    /// Plays the video at real speed through the hardware decoder, like a live camera: frames the device has no time
    /// for are dropped, but never more than `stepMs` apart (a slow device then plays slower than real time).
    /// Timestamps are the real presentation times, so speed estimates do not depend on how fast the device processes.
    /// If iOS interrupts the reader (app sent to background, screen locked), reading resumes where it stopped.
    static func run(
        url: URL,
        process: @Sendable (FrameInput) -> Void,
        onProgress: @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoSource", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found."])
        }
        let totalMs = max(Int64(try await asset.load(.duration).seconds * 1000), 1)
        let transform = try await track.load(.preferredTransform)
        let orient = orientation(transform)

        var lastMs: Int64 = -stepMs
        var originMs: Int64?
        var clockStart = Date()
        var retries = 0

        while true {
            let reader = try AVAssetReader(asset: asset)
            if lastMs > 0 {
                reader.timeRange = CMTimeRange(start: CMTime(value: lastMs + 1, timescale: 1000), duration: .positiveInfinity)
            }
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? NSError(domain: "VideoSource", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read the video."])
            }

            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let ms = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1000)
                if ms < lastMs + minGapMs { continue }

                let now = Date()
                if originMs == nil { originMs = ms; clockStart = now }
                let videoElapsed = ms - (originMs ?? ms)
                let wallElapsed = Int64(now.timeIntervalSince(clockStart) * 1000)
                if videoElapsed < wallElapsed {
                    // behind real time: drop this frame unless tracking would get too sparse
                    if ms < lastMs + stepMs { continue }
                    // do not race to catch up afterwards
                    if wallElapsed - videoElapsed > 250 { clockStart = now.addingTimeInterval(-Double(videoElapsed) / 1000) }
                } else if videoElapsed > wallElapsed {
                    try await Task.sleep(nanoseconds: UInt64(videoElapsed - wallElapsed) * 1_000_000)
                }

                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                process(FrameInput(buffer: buffer, orientation: orient, tMs: ms))
                onProgress(min(Double(ms) / Double(totalMs), 1))
                lastMs = ms
            }
            try Task.checkCancellation()

            if reader.status == .failed {
                // usually the app is in the background: wait (up to ~2 min) until it can read again
                retries += 1
                if retries > 120 { throw reader.error ?? NSError(domain: "VideoSource", code: 3) }
                originMs = nil
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            onProgress(1)
            return
        }
    }
}
