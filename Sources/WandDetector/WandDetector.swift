import CoreVideo

public enum WandDetectorError: Error {
    case invalidRegionOfInterest
    case invalidMaxRetainedOutputImages
    case failedPixelBufferPoolCreation(code: CVReturn)
}

public struct WandDetector {
    // TODO: calculate minPixels based on some fidelity length and
    // screen projection size at some standard gameplay distance for that screen
    private let minPixels = 50_000

    private let region: CGRect
    private let pool: CVPixelBufferPool
    private let transform: CGAffineTransform

    // MARK: Initialization

    public init(inputImageDimensions dimensions: CGSize, regionOfInterest region: CGRect, maxRetainedOutputImages maxRetain: UInt = 1) throws {
        // verify maxRetain is positive
        if maxRetain <= 0 {
            throw WandDetectorError.invalidMaxRetainedOutputImages
        }

        // verify that dimensions contain region
        let dimensionsRect = CGRect(origin: CGPoint(x: 0, y: 0), size: dimensions)
        if !dimensionsRect.contains(region) {
            throw WandDetectorError.invalidRegionOfInterest
        }

        // create the translation transform
        let dx = -region.origin.x
        let dy = -region.origin.y
        var transform = CGAffineTransform(translationX: dx, y: dy)

        // width and height for the output pixel buffers
        var outWidth = region.width
        var outHeight = region.height

        let pixels = outWidth * outHeight
        if pixels > CGFloat(minPixels) { // create the downscale transform
            let downscale = CGFloat(sqrt(Double(minPixels) / Double(pixels)))

            // adjust the scale so width and height will be integers
            let downscaledRegion = region.applying(CGAffineTransform(scaleX: downscale, y: downscale))
            outWidth = downscaledRegion.width.rounded(.up)
            outHeight = downscaledRegion.height.rounded(.up)

            let adjustedScaleX = outWidth / region.width
            let adjustedScaleY = outHeight / region.height

            // concatenate with the translation transform
            transform = transform.concatenating(CGAffineTransform(scaleX: adjustedScaleX, y: adjustedScaleY))
        }

        // create the output pixel buffer pool
        let poolAttributes: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: maxRetain]
        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: outWidth,
            kCVPixelBufferHeightKey: outHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent8
        ]

        var poolOut: CVPixelBufferPool?
        var code = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, pixelBufferAttributes, &poolOut)
        guard let pool = poolOut else {
            throw WandDetectorError.failedPixelBufferPoolCreation(code: code)
        }

        // preallocate maxRetain number of buffers
        var pixelBufferOut: CVPixelBuffer?
        var pixelBufferRetainer = [CVPixelBuffer]() // prevents recycling during the below while loop
        let auxAttributes: NSDictionary = [kCVPixelBufferPoolAllocationThresholdKey: maxRetain]

        code = kCVReturnSuccess
        while code == kCVReturnSuccess {
            code = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &pixelBufferOut)
            if let pixelBuffer = pixelBufferOut {
                pixelBufferRetainer.append(pixelBuffer)
            }
            pixelBufferOut = nil
        }

        assert(code == kCVReturnWouldExceedAllocationThreshold, "Unexpected CVReturn code \(code)")

        // initialize stored properties
        self.pool = pool
        self.region = region
        self.transform = transform
    }
}
