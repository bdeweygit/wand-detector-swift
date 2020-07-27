import CoreVideo

public typealias ImageSize = (width: Int, height: Int)
public typealias Wand = (center: (x: Double, y: Double), radius: Double)
public typealias ImageRegion = (origin: (x: Int, y: Int), size: ImageSize)

public enum WandDetectorError: Error {
    case invalidWand
    case invalidImage
    case invalidRegionOfInterest
    case invalidMaxRetainedOutputImages
    case couldNotCreatePixelBufferPool(code: CVReturn)
}

public struct WandDetector {
    // TODO: calculate minPixels based on some fidelity length and
    // screen projection size at some standard gameplay distance for that screen
    private let minPixels = 50_000

    private let roi: ImageRegion
    private let inputSize: ImageSize
    private let pool: CVPixelBufferPool
    private let transform: CGAffineTransform

    // MARK: Initialization

    public init(inputSize: ImageSize, regionOfInterest roi: ImageRegion, maxRetainedOutputImages maxRetain: Int = 1) throws {
        // verify maxRetain is positive
        guard maxRetain > 0 else {
            throw WandDetectorError.invalidMaxRetainedOutputImages
        }

        // verify roi size is positive
        guard roi.size.width > 0 && roi.size.height > 0 else {
           throw WandDetectorError.invalidRegionOfInterest
        }

        // make CGRects from inputSize and roi
        let inputRect = CGRect(origin: CGPoint.zero, size: CGSize(width: inputSize.width, height: inputSize.height))
        let roiRect = CGRect(origin: CGPoint(x: roi.origin.x, y: roi.origin.y), size: CGSize(width: roi.size.width, height: roi.size.height))

        // verify inputRect contains roiRect
        guard inputRect.contains(roiRect) else {
            throw WandDetectorError.invalidRegionOfInterest
        }

        // create the translation transform
        let dx = -roiRect.origin.x
        let dy = -roiRect.origin.y
        var transform = CGAffineTransform(translationX: dx, y: dy)

        // width and height for the output pixel buffers
        var outputWidth = roiRect.width
        var outputHeight = roiRect.height

        let outputPixels = outputWidth * outputHeight
        if outputPixels > CGFloat(minPixels) { // create the downscale transform
            let downscale = CGFloat(sqrt(Double(minPixels) / Double(outputPixels)))

            // adjust the scale so output width and height will be integers
            let downscaledRoiRect = roiRect.applying(CGAffineTransform(scaleX: downscale, y: downscale))
            outputWidth = downscaledRoiRect.width.rounded(.up)
            outputHeight = downscaledRoiRect.height.rounded(.up)

            let adjustedScaleX = outputWidth / roiRect.width
            let adjustedScaleY = outputHeight / roiRect.height

            // concatenate with the translation transform
            transform = transform.concatenating(CGAffineTransform(scaleX: adjustedScaleX, y: adjustedScaleY))
        }

        // create the output pixel buffer pool
        let poolAttributes: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: maxRetain]
        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: outputWidth,
            kCVPixelBufferHeightKey: outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent8
        ]

        var poolOut: CVPixelBufferPool?
        var code = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, pixelBufferAttributes, &poolOut)
        guard let pool = poolOut else {
            throw WandDetectorError.couldNotCreatePixelBufferPool(code: code)
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
        self.roi = roi
        self.pool = pool
        self.inputSize = inputSize
        self.transform = transform
    }

    // MARK: Calibration

    public func calibrate(using wand: Wand, inRegionOfInterestIn image: CVImageBuffer) throws -> CVImageBuffer {
        // verify image size is correct
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        guard width == self.inputSize.width && height == self.inputSize.height else {
            throw WandDetectorError.invalidImage
        }

        // make CGRects from roi and wand
        let roiRect = CGRect(origin: CGPoint(x: self.roi.origin.x, y: self.roi.origin.y), size: CGSize(width: self.roi.size.width, height: self.roi.size.height))
        let diameter = wand.radius * 2
        var wandRect = CGRect(origin: CGPoint(x: wand.center.x - wand.radius, y: wand.center.y - wand.radius), size: CGSize(width: diameter, height: diameter))

        assert(wandRect.midX == CGFloat(wand.center.x) && wandRect.midY == CGFloat(wand.center.y), "wandRect is centered incorrectly")

        // verify roiRect contains wandRect
        guard roiRect.contains(wandRect) else {
            throw WandDetectorError.invalidWand
        }

        // apply the transform to wandRect
        wandRect = wandRect.applying(self.transform)

        // begin binary search of optimal filter parameters
        //
        //
    }
}
