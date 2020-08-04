import CoreImage
import UIKit.UIColor
import CoreImage.CIFilterBuiltins

public typealias ImageSize = (width: Int, height: Int)
public typealias Wand = (center: (x: Double, y: Double), radius: Double)
public typealias ImageRegion = (origin: (x: Int, y: Int), size: ImageSize)

private typealias PixelPoint = (x: Int, y: Int)
private typealias ColorCube = (data: Data, dimension: Float)

public enum WandDetectorError: Error {
    case invalidWand
    case invalidImage
    case couldNotUseFilter
    case invalidRegionOfInterest
    case invalidMaxRetainedOutputImages
    case couldNotCreatePixelBuffer(code: CVReturn)
    case couldNotCreatePixelBufferPool(code: CVReturn)
}

public struct WandDetector {
    // TODO: calculate minPixels based on some fidelity length and
    // screen projection size at some standard gameplay distance for that screen
    private let minPixels = 50_000

    private let roiRect: CGRect
    private let context: CIContext
    private let inputSize: ImageSize
    private let pool: CVPixelBufferPool
    private let transform: CGAffineTransform
    private let thresholdFilter: CIColorCube
    private let binarizationFilter: CIColorPosterize
    private let widthErosionFilter: CIMorphologyRectangleMinimum
    private let heightErosionFilter: CIMorphologyRectangleMinimum
    private let squareErosionFilter: CIMorphologyRectangleMinimum
    private let squareDilationFilter: CIMorphologyRectangleMaximum

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
        let inputSizeRect = CGRect(origin: .zero, size: CGSize(width: inputSize.width, height: inputSize.height))
        let roiRect = CGRect(origin: CGPoint(x: roi.origin.x, y: roi.origin.y), size: CGSize(width: roi.size.width, height: roi.size.height))

        // verify inputSizeRect contains roiRect
        guard inputSizeRect.contains(roiRect) else {
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
            outputWidth = downscaledRoiRect.width.rounded(.down)
            outputHeight = downscaledRoiRect.height.rounded(.down)

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

        // create the context
        let context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!,
        ])

        // create the filters
        let thresholdFilter = CIFilter.colorCube()
        let binarizationFilter = CIFilter.colorPosterize()
        let widthErosionFilter = CIFilter.morphologyRectangleMinimum()
        let heightErosionFilter = CIFilter.morphologyRectangleMinimum()
        let squareErosionFilter = CIFilter.morphologyRectangleMinimum()
        let squareDilationFilter = CIFilter.morphologyRectangleMaximum()

        // configure the filters
        binarizationFilter.levels = 2
        widthErosionFilter.width = 9
        widthErosionFilter.height = 1
        heightErosionFilter.width = 1
        heightErosionFilter.height = 9
        squareErosionFilter.width = 3
        squareErosionFilter.height = 3
        squareDilationFilter.width = 3
        squareDilationFilter.height = 3

        // initialize stored properties
        self.pool = pool
        self.context = context
        self.roiRect = roiRect
        self.inputSize = inputSize
        self.transform = transform
        self.thresholdFilter = thresholdFilter
        self.binarizationFilter = binarizationFilter
        self.widthErosionFilter = widthErosionFilter
        self.heightErosionFilter = heightErosionFilter
        self.squareErosionFilter = squareErosionFilter
        self.squareDilationFilter = squareDilationFilter
    }

    // MARK: Calibration

    public func calibrate(using wand: Wand, inRegionOfInterestIn image: CVImageBuffer) throws {
        // verify image size is correct
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        guard width == self.inputSize.width && height == self.inputSize.height else {
            throw WandDetectorError.invalidImage
        }

        // make a CGRect that bounds the wand
        let diameter = wand.radius * 2
        let wandRect = CGRect(origin: CGPoint(x: wand.center.x - wand.radius, y: wand.center.y - wand.radius), size: CGSize(width: diameter, height: diameter))

        assert(wandRect.midX == CGFloat(wand.center.x) && wandRect.midY == CGFloat(wand.center.y), "wandRect is centered incorrectly")

        // verify roiRect contains wandRect
        guard self.roiRect.contains(wandRect) else {
            throw WandDetectorError.invalidWand
        }

        // create the transformed wand
        let transformedWandRect = wandRect.applying(self.transform)
        let transformedWand: Wand = (center: (x: Double(transformedWandRect.midX), y: Double(transformedWandRect.midY)), radius: Double(transformedWandRect.width / 2))

        // crop and transform the image
        let transformedImage = CIImage(cvImageBuffer: image).cropped(to: self.roiRect).transformed(by: self.transform)

        // get width and height of transformedImage
        let transformedImageWidth = Int(transformedImage.extent.width.rounded(.down))
        let transformedImageHeight = Int(transformedImage.extent.height.rounded(.down))

        // create the output image to render into
        var pixelBufferOut: CVPixelBuffer?
        let code = CVPixelBufferCreate(kCFAllocatorDefault, transformedImageWidth, transformedImageHeight, kCVPixelFormatType_32BGRA, nil, &pixelBufferOut)
        guard let outputImage = pixelBufferOut else {
            throw WandDetectorError.couldNotCreatePixelBuffer(code: code)
        }

        // render to the output image
        self.context.render(transformedImage, to: outputImage)

        // find the arc on the hue circle containing the least percent of the wand
        var wandlessArc = 0
        var leastPercentInArc = Double.infinity
        let arcs = 6 // arcs of the hue circle: 3 primaries and 3 secondaries
        let arcAngle = 1 / CGFloat(arcs)
        let thirtyDegrees: CGFloat = 30 / 360 // will rotate hue circle so that degree 0 is the start of the first arc

        for arc in 0..<arcs {
            // create the arc's range
            let lowerAngle = CGFloat(arc) * arcAngle
            let arcRange: ClosedRange<CGFloat> = lowerAngle...(lowerAngle + arcAngle)

            // calculate the percent of the wand within the arc
            let percentInArc = self.measure(percentOf: transformedWand, satisfying: { pixel in
                // create an rgba color from the pixel data
                let blue = CGFloat(pixel >> 24) / 255
                let green = CGFloat((pixel << 8) >> 24) / 255
                let red = CGFloat((pixel << 16) >> 24) / 255
                let rgba = UIColor(red: red, green: green, blue: blue, alpha: 1)

                // get the hue of the rgba color
                var hue: CGFloat = 0;
                rgba.getHue(&hue, saturation: nil, brightness: nil, alpha: nil)
                hue = (hue + thirtyDegrees).truncatingRemainder(dividingBy: 1)

                return arcRange.contains(hue)
            }, in: outputImage, ofPixelType: UInt32.self)

            if percentInArc < leastPercentInArc {
                leastPercentInArc = percentInArc
                wandlessArc = arc
            }
        }

        // will rotate hue circle so that degree 0 bisects wandlessArc
        let hueRotation = CGFloat(wandlessArc) * arcAngle

        // calibrate the threshold filter by finding optimal
        // HSB parameters for the threshold filter's color cube
        let minActivity: Double = 0.8 // 80 percent <- why this number?
        let maxPrecision: CGFloat = 1 / 64 // same as the precision of the color cube
        var parameters: [CGFloat] = [0, 1, 0, 1, 0, 1] // [minH, maxH, minS, maxS, minB, maxB]

        try parameters.indices.forEach({ index in
            let isMinParameter = index % 2 == 0
            var lower = isMinParameter ? parameters[index] : parameters[index - 1]
            var upper = isMinParameter ? parameters[index + 1] : parameters[index]

            // binary search the optimal value of parameters[index]
            while (upper - lower) > maxPrecision {
                let middle = (lower + upper) / 2
                parameters[index] = middle

                // create HSB ranges
                let hueRange = parameters[0]...parameters[1]
                let saturationRange = parameters[2]...parameters[3]
                let brightnessRange = parameters[4]...parameters[5]

                // calibrate the threshold filter
                let colorCube = self.createColorCube(hueRotation: hueRotation, hueRange: hueRange, saturationRange: saturationRange, brightnessRange: brightnessRange)
                self.thresholdFilter.cubeData = colorCube.data
                self.thresholdFilter.cubeDimension = colorCube.dimension

                // filter the image
                let filteredImage = try self.filter(image: image)

                // calculate the percent of the wand that is active, i.e. not black
                let percentActive = self.measure(percentOf: transformedWand, satisfying: { $0 != 0 }, in: filteredImage, ofPixelType: UInt8.self)

                // reduce the search space
                if percentActive >= minActivity {
                    if isMinParameter { lower = middle }
                    else { upper = middle }
                } else {
                    if isMinParameter { upper = middle }
                    else { lower = middle }
                }
            }
        })

        // if calibration requires the user to position the wand m meters distance from the camera
        // then we can compute the size of the wand at max_m distance and see if that size is >=
        // some minimum size (maybe 3x3 pixels) which can then be used as the break condition
        // for calibrating the width and height erosion filters
    }

    // MARK: Measurement

    private func measure<T>(percentOf wand: Wand, satisfying condition: (T) -> Bool, in image: CVImageBuffer, ofPixelType type: T.Type) -> Double {
        return image.withPixelGetter(getting: type) { getPixelAt in
            // start point
            let startX = Int((wand.center.x - wand.radius).rounded(.down))
            let startY = Int((wand.center.y - wand.radius).rounded(.down))

            // end point
            let diameter = Int((wand.radius * 2).rounded(.up))
            let endX = startX + diameter
            let endY = startY + diameter

            var total: Double = 0
            var passing: Double = 0

            for x in startX...endX {
                for y in startY...endY {
                    let point: PixelPoint = (x: x, y: y)
                    if let pixel = getPixelAt(point) {
                        let length = sqrt(pow(Double(x) - wand.center.x, 2) + pow(Double(y) - wand.center.y, 2))
                        if length <= wand.radius {
                            total += 1
                            if condition(pixel) { passing += 1 }
                        }
                    }
                }
            }

            return passing / total
        }
    }

    // MARK: Filtration

    private func filter(image: CVImageBuffer) throws -> CVImageBuffer {
        // create the output image to render into
        var pixelBufferOut: CVPixelBuffer?
        let code = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pool, &pixelBufferOut)
        guard let outputImage = pixelBufferOut else {
            throw WandDetectorError.couldNotCreatePixelBuffer(code: code)
        }

        // crop
        let cropped = CIImage(cvImageBuffer: image).cropped(to: self.roiRect)

        // transform
        let transformed = cropped.transformed(by: self.transform)

        // threshold
        self.thresholdFilter.inputImage = transformed
        guard let thresholded = self.thresholdFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }

        // binarize
        self.binarizationFilter.inputImage = thresholded
        guard let binarized = self.binarizationFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }

        // clamp
        let clamped = binarized.clampedToExtent()

        // square dilate
        self.squareDilationFilter.inputImage = clamped
        guard let squareDilated = self.squareDilationFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }

        // square erode
        self.squareErosionFilter.inputImage = squareDilated
        guard let squareEroded = self.squareErosionFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }

        // width erode
        self.widthErosionFilter.inputImage = squareEroded
        guard let widthEroded = self.widthErosionFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }

        // height erode
        self.heightErosionFilter.inputImage = widthEroded
        guard let heightEroded = self.heightErosionFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }

        // WARNING!
        // when contour tracing don't forget to correct wand's
        // area according to the number of pixels eroded

        // render to the output image
        self.context.render(heightEroded, to: outputImage)

        return outputImage
    }

    // MARK: Color Cube Creation

    private func createColorCube(hueRotation: CGFloat = 0, hueRange: ClosedRange<CGFloat>, saturationRange: ClosedRange<CGFloat>, brightnessRange: ClosedRange<CGFloat>) -> ColorCube {
        var cube = [Float]()

        let size = 64
        let dimension = Float(size)

        for z in 0 ..< size {
            let blue = CGFloat(z) / CGFloat(size-1)
            for y in 0 ..< size {
                let green = CGFloat(y) / CGFloat(size-1)
                for x in 0 ..< size {
                    let red = CGFloat(x) / CGFloat(size-1)

                    let rgba = UIColor(red: red, green: green, blue: blue, alpha: 1)

                    var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
                    rgba.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
                    hue = (hue + hueRotation).truncatingRemainder(dividingBy: 1)

                    let color: Float =
                        hueRange.contains(hue) &&
                        saturationRange.contains(saturation) &&
                        brightnessRange.contains(brightness) ? 1 : 0

                    cube.append(color) // red
                    cube.append(color) // green
                    cube.append(color) // blue
                    cube.append(1)     // alpha
                }
            }
        }

        let data = cube.withUnsafeBufferPointer { buffer in Data(buffer: buffer) }

        return (data: data, dimension: dimension)
    }
}

// MARK: Extensions

private extension CVImageBuffer {
    func withPixelGetter<T, R>(getting type: T.Type, body: ((PixelPoint) -> T?) -> R) -> R {
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)
        let bpr = CVPixelBufferGetBytesPerRow(self)

        let widthRange = 0..<width
        let heightRange = 0..<height

        // lock and later unlock
        CVPixelBufferLockBaseAddress(self, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(self, .readOnly) }

        // get pixels
        let baseAddress = CVPixelBufferGetBaseAddress(self)
        let pixels = unsafeBitCast(baseAddress, to: UnsafePointer<T>.self)

        // call body with a getter function
        return body { point in
            let (x, y) = point
            let inImage = widthRange.contains(x) && heightRange.contains(y)
            return inImage ? pixels[x + (y * bpr)] : nil
        }
    }
}
