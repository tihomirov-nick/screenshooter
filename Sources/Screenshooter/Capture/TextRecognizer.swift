import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Text in an image, Russian and English, lines in reading order.
enum TextRecognizer {
    static func recognize(_ image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: recognizeNow(image))
            }
        }
    }

    static func recognize(fileAt url: URL) async -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        return await recognize(image)
    }

    private static func recognizeNow(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.automaticallyDetectsLanguage = true
        // No lower limit on text height: small labels in a large capture are read too.
        request.minimumTextHeight = 0
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []

        // Group observations into rows by their vertical centre, then left to right.
        struct Line { var box: CGRect; var text: String }
        let lines = observations.compactMap { o -> Line? in
            guard let text = o.topCandidates(1).first?.string else { return nil }
            return Line(box: o.boundingBox, text: text)
        }.sorted { $0.box.midY > $1.box.midY }

        var rows: [[Line]] = []
        for line in lines {
            if let last = rows.last?.first,
               abs(last.box.midY - line.box.midY) < min(last.box.height, line.box.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
