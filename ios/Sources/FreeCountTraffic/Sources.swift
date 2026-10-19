import AVFoundation
import CoreImage
import Foundation
import ImageIO

let maxFrameSide: CGFloat = 640

private let sharedCIContext = CIContext()

/// Downscales so the longest side is `maxFrameSide` and renders to a CGImage.
private func makeFrame(_ input: CIImage) -> CGImage? {
    var image = input
    let longest = max(image.extent.width, image.extent.height)
    if longest > maxFrameSide {
        let s = maxFrameSide / longest
        image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }
    return sharedCIContext.createCGImage(image, from: image.extent)
}

/// Back camera -> frames (downscaled so the longest side is 640 px). Runs on its own queue.
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "freecount.camera")
    private var onFrame: (@Sendable (CGImage, Int64) -> Void)?
    private var running = false

    func start(onFrame: @escaping @Sendable (CGImage, Int64) -> Void, onError: @escaping @Sendable (String) -> Void) {
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
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cg = makeFrame(CIImage(cvPixelBuffer: buffer)) else { return }
        let ms = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000)
        onFrame?(cg, ms)
    }
}

enum VideoSource {
    static let stepMs: Int64 = 100

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

    /// Decodes the video sequentially (fast, hardware decoder) and hands every `stepMs` a frame to `process`.
    /// Timestamps are the real presentation times, so speed estimates do not depend on how fast the device processes.
    static func run(
        url: URL,
        process: @Sendable (CGImage, Int64) -> Void,
        onProgress: @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoSource", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found."])
        }
        let totalMs = max(Int64(try await asset.load(.duration).seconds * 1000), 1)
        let transform = try await track.load(.preferredTransform)
        let orient = orientation(transform)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VideoSource", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read the video."])
        }

        var nextMs: Int64 = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let ms = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1000)
            if ms < nextMs { continue }
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  let cg = makeFrame(CIImage(cvPixelBuffer: buffer).oriented(orient)) else { continue }
            process(cg, ms)
            onProgress(min(Double(ms) / Double(totalMs), 1))
            nextMs = ms + stepMs
        }
        if reader.status == .failed, let e = reader.error { throw e }
    }
}
