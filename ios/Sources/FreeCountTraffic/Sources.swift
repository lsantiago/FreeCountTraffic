import AVFoundation
import CoreImage
import Foundation

let maxFrameSide: CGFloat = 640

/// Back camera -> frames (downscaled so the longest side is 640 px). Runs on its own queue.
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "freecount.camera")
    private let ciContext = CIContext()
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
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image = CIImage(cvPixelBuffer: buffer)
        let longest = max(image.extent.width, image.extent.height)
        if longest > maxFrameSide {
            let s = maxFrameSide / longest
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return }
        let ms = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000)
        onFrame?(cg, ms)
    }
}

enum VideoSource {
    static let stepMs: Int64 = 100

    private static func generator(_ asset: AVAsset) -> AVAssetImageGenerator {
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: maxFrameSide, height: maxFrameSide)
        // A little tolerance keeps decoding fast; the exact frame time is read back from `actualTime`.
        g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 40)
        g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 40)
        return g
    }

    /// First frame of the video, to place boxes before the run.
    static func firstFrame(_ url: URL) async -> CGImage? {
        let g = generator(AVURLAsset(url: url))
        return try? await g.image(at: .zero).image
    }

    /// Steps through the video every `stepMs`. Timestamps are the real frame times, so speed estimates do not
    /// depend on how fast the device processes.
    static func run(
        url: URL,
        process: @Sendable (CGImage, Int64) -> Void,
        onProgress: @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let totalMs = Int64(duration.seconds * 1000)
        let g = generator(asset)
        var t: Int64 = 0
        while t <= totalMs {
            try Task.checkCancellation()
            let result = try await g.image(at: CMTime(value: t, timescale: 1000))
            process(result.image, Int64(result.actualTime.seconds * 1000))
            onProgress(totalMs > 0 ? Double(t) / Double(totalMs) : 1)
            t += stepMs
        }
    }
}
