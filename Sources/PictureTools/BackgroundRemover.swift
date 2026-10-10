import CoreGraphics
import CoreImage
import CoreVideo
import Vision

/// The objects in the front of a picture on transparent pixels, found by Vision on this Mac.
public enum BackgroundRemover {
    public enum Failure: Error, Equatable {
        /// Vision found nothing that stands out from the background.
        case nothingFound
        /// Vision could not look at the picture (a format it does not take, a Mac without the model).
        case failed
    }

    /// Cropped to the objects; their pixels and colours stay as they were.
    public static func removeBackground(from image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw Failure.failed
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw Failure.nothingFound
        }
        let buffer: CVPixelBuffer
        do {
            buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: true)
        } catch {
            throw Failure.failed
        }
        // No colour matching on the way: the pixels are the picture's own, so they keep its colour space.
        let masked = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        let space = own ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard masked.extent.width >= 1, masked.extent.height >= 1,
              let result = context.createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: space) else {
            throw Failure.failed
        }
        return result
    }
}
