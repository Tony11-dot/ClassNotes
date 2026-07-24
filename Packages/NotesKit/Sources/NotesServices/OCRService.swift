import Foundation
import Vision
#if canImport(UIKit)
import UIKit
#endif

/// Handwriting / text recognition over a rendered page (or region) image.
/// Powers "turn my writing into text" and feeds NOVA's circle-to-explain with
/// the words inside the circled area.
public struct OCRService: Sendable {
    public init() {}

    public struct Line: Sendable, Equatable {
        public let text: String
        /// Normalized Vision bounding box (origin bottom-left).
        public let boundingBox: CGRect
    }

    public enum OCRError: Error, Sendable { case noImage, failed }

    #if canImport(UIKit)
    public func recognize(in image: UIImage, languages: [String] = ["en-US"]) async throws -> [Line] {
        guard let cgImage = image.cgImage else { throw OCRError.noImage }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if error != nil {
                    continuation.resume(throwing: OCRError.failed)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines: [Line] = observations.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return Line(text: candidate.string, boundingBox: observation.boundingBox)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: OCRError.failed)
                }
            }
        }
    }

    /// Recognized lines joined into a paragraph, top-to-bottom.
    public func recognizeText(in image: UIImage, languages: [String] = ["en-US"]) async throws -> String {
        let lines = try await recognize(in: image, languages: languages)
        return Self.assemble(lines)
    }
    #endif

    /// Orders lines top-to-bottom (Vision boxes are bottom-left origin) and
    /// joins them with newlines. Pure + testable.
    public static func assemble(_ lines: [Line]) -> String {
        lines
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .map(\.text)
            .joined(separator: "\n")
    }
}
