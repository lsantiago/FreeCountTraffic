import CoreGraphics
import CoreImage
import CoreML
import Foundation
import TrafficCore
import Vision

/// Three accuracy / speed trade-offs, like the reference app's "Detection Model" setting.
enum DetectionModel: String, CaseIterable, Identifiable {
    case highAccuracy, balanced, fastest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highAccuracy: return "High Accuracy"
        case .balanced: return "Balanced"
        case .fastest: return "Fastest"
        }
    }

    /// YOLO11 medium / small / nano, exported to Core ML with built-in NMS by `scripts/export-models.sh`.
    var resource: String {
        switch self {
        case .highAccuracy: return "yolo11m"
        case .balanced: return "yolo11s"
        case .fastest: return "yolo11n"
        }
    }
}

/// On-device COCO object detector: an Ultralytics YOLO11 Core ML model run through Vision.
/// The models are not committed; `scripts/export-models.sh` generates them into Resources/ before building.
final class VehicleDetector {
    private let model: VNCoreMLModel
    private let request: VNCoreMLRequest

    init(_ kind: DetectionModel) throws {
        guard let url = Self.modelURL(kind.resource) else {
            throw NSError(
                domain: "VehicleDetector", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(kind.resource) model not found in the app bundle. Run ios/scripts/export-models.sh and rebuild."]
            )
        }
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        let vnModel = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
        model = vnModel
        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFit
        request = req
        applyThresholds()
    }

    /// Minimum detection confidence (Settings > Confidence Threshold).
    var confidence: Float = 0.30 {
        didSet { applyThresholds() }
    }

    /// Inputs of the exported NMS pipeline.
    private func applyThresholds() {
        model.featureProvider = try? MLDictionaryFeatureProvider(dictionary: [
            "iouThreshold": MLFeatureValue(double: 0.45),
            "confidenceThreshold": MLFeatureValue(double: Double(confidence)),
        ])
    }

    /// Xcode builds ship a precompiled .mlmodelc; xtool/SwiftPM builds copy the raw .mlpackage, compiled here on first launch.
    private static func modelURL(_ name: String) -> URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        if let compiled = bundle.url(forResource: name, withExtension: "mlmodelc") { return compiled }
        for sub in [nil, "Resources"] as [String?] {
            if let raw = bundle.url(forResource: name, withExtension: "mlpackage", subdirectory: sub) {
                return try? MLModel.compileModel(at: raw)
            }
        }
        return nil
    }

    /// Detects on the source's own pixel buffer (Vision scales it to the model's input, with no extra conversion).
    /// - Parameter area: part of the upright frame to analyse, normalized with origin top-left (nil = whole frame).
    ///   It is cut from the full-resolution frame; the boxes are returned in whole-frame coordinates.
    func detect(_ frame: FrameInput, area: RectN?) -> [Detection] {
        var handler = VNImageRequestHandler(cvPixelBuffer: frame.buffer, orientation: frame.orientation, options: [:])
        var crop = RectN(left: 0, top: 0, right: 1, bottom: 1)
        if let area, area.width < 0.98 || area.height < 0.98 {
            let image = frame.image
            let e = image.extent
            // Core Image's origin is at the bottom left
            let rect = CGRect(x: e.minX + CGFloat(area.left) * e.width, y: e.minY + (1 - CGFloat(area.bottom)) * e.height,
                              width: CGFloat(area.width) * e.width, height: CGFloat(area.height) * e.height)
                .intersection(e).integral
            if rect.width >= 32, rect.height >= 32 {
                let cut = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                handler = VNImageRequestHandler(ciImage: cut, options: [:])
                crop = RectN(left: Float((rect.minX - e.minX) / e.width), top: Float(1 - (rect.maxY - e.minY) / e.height),
                             right: Float((rect.maxX - e.minX) / e.width), bottom: Float(1 - (rect.minY - e.minY) / e.height))
            }
        }
        do { try handler.perform([request]) } catch { return [] }
        let observations = (request.results as? [VNRecognizedObjectObservation]) ?? []
        return observations.compactMap { o in
            guard let top = o.labels.first, top.confidence >= confidence,
                  let cls = VehicleClass.fromCoco(top.identifier) else { return nil }
            let b = o.boundingBox // normalized to the analysed image, origin bottom-left
            let l = Float(b.minX), t = Float(1 - b.maxY), r = Float(b.maxX), btm = Float(1 - b.minY)
            return Detection(
                box: RectN(left: crop.left + l * crop.width, top: crop.top + t * crop.height,
                           right: crop.left + r * crop.width, bottom: crop.top + btm * crop.height),
                cls: cls,
                score: top.confidence
            )
        }
    }
}
