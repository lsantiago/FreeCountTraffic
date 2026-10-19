import CoreGraphics
import CoreML
import Foundation
import TrafficCore
import Vision

/// On-device COCO object detector: Apple's YOLOv3-Tiny Core ML model run through Vision.
/// The model is not committed; `scripts/fetch-model.sh` downloads it into Resources/ before building.
final class VehicleDetector {
    private let model: VNCoreMLModel

    init() throws {
        guard let url = Self.compiledModelURL() else {
            throw NSError(
                domain: "VehicleDetector", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "YOLOv3Tiny model not found in the app bundle. Run ios/scripts/fetch-model.sh and rebuild."]
            )
        }
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
    }

    /// Xcode builds ship a precompiled .mlmodelc; xtool/SwiftPM builds copy the raw .mlmodel, compiled here on first launch.
    private static func compiledModelURL() -> URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        if let compiled = bundle.url(forResource: "YOLOv3Tiny", withExtension: "mlmodelc") { return compiled }
        for sub in [nil, "Resources"] as [String?] {
            if let raw = bundle.url(forResource: "YOLOv3Tiny", withExtension: "mlmodel", subdirectory: sub) {
                return try? MLModel.compileModel(at: raw)
            }
        }
        return nil
    }

    func detect(_ image: CGImage, threshold: Float = 0.35) -> [Detection] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let observations = (request.results as? [VNRecognizedObjectObservation]) ?? []
        return observations.compactMap { o in
            guard let top = o.labels.first, top.confidence >= threshold,
                  let cls = VehicleClass.fromCoco(top.identifier) else { return nil }
            let b = o.boundingBox // normalized, origin bottom-left
            return Detection(
                box: RectN(left: Float(b.minX), top: Float(1 - b.maxY), right: Float(b.maxX), bottom: Float(1 - b.minY)),
                cls: cls,
                score: top.confidence
            )
        }
    }
}
