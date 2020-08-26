import CoreImage
import UIKit.UIColor
import CoreImage.CIFilterBuiltins

public typealias ImageSize = (width: Int, height: Int)
public typealias Wand = (center: (x: Double, y: Double), radius: Double)
public typealias ImageRegion = (origin: (x: Int, y: Int), size: ImageSize)

private typealias PixelPoint = (x: Int, y: Int)

public enum WandDetectorError: Error {
    case invalidWand
    case invalidImage
    case couldNotFilterImage
    case invalidRegionOfInterest
    case invalidOutputImagePoolMinCardinality
    case couldNotCreateOutputImage(code: CVReturn)
    case couldNotCreateOutputImagePool(code: CVReturn)
    case couldNotCreateCalibrationImage(code: CVReturn)
}

public struct WandDetector {
    // TODO: calculate maxOutputImagePixels based on some fidelity length and
    // screen projection size at some standard gameplay distance for that screen
    private let maxOutputImagePixels = 50_000 // <- why?

    private let ROIRectangle: CGRect
    private let context: CIContext
    private let inputImageSize: ImageSize
    private let pool: CVPixelBufferPool
    private let transform: CGAffineTransform
    private let thresholdFilter: CIColorCube
    private let binarizationFilter: CIColorPosterize
    private var widthErosionFilter: CIMorphologyRectangleMinimum
    private var heightErosionFilter: CIMorphologyRectangleMinimum
    private let squareErosionFilter: CIMorphologyRectangleMinimum
    private let squareDilationFilter: CIMorphologyRectangleMaximum

    // MARK: Initialization

    public init(forRegionOfInterest ROI: ImageRegion, inInputImagesOfSize inputImageSize: ImageSize, usingOutputImagePoolMinCardinality minPoolCardinality: Int = 1) throws {
        // verify output image pool min cardinality is positive
        guard minPoolCardinality > 0 else {
            throw WandDetectorError.invalidOutputImagePoolMinCardinality
        }

        // verify region of interest size is positive
        guard ROI.size.width > 0 && ROI.size.height > 0 else {
           throw WandDetectorError.invalidRegionOfInterest
        }

        // make rectangles from input image size and region of interest
        let imageSizeRectangle = CGRect(origin: .zero, size: CGSize(width: inputImageSize.width, height: inputImageSize.height))
        let ROIRectangle = CGRect(origin: CGPoint(x: ROI.origin.x, y: ROI.origin.y), size: CGSize(width: ROI.size.width, height: ROI.size.height))

        // verify input image size contains the region of interest
        guard imageSizeRectangle.contains(ROIRectangle) else {
            throw WandDetectorError.invalidRegionOfInterest
        }

        // create the translation transform
        let dx = -ROIRectangle.origin.x
        let dy = -ROIRectangle.origin.y
        var transform = CGAffineTransform(translationX: dx, y: dy)

        // width and height for the output images
        var outputImageWidth = ROIRectangle.width
        var outputImageHeight = ROIRectangle.height

        let outputImagePixels = outputImageWidth * outputImageHeight
        if outputImagePixels > CGFloat(self.maxOutputImagePixels) { // create a downscale transform
            let downscale = CGFloat(sqrt(Double(self.maxOutputImagePixels) / Double(outputImagePixels)))

            // adjust the scale so output width and height will be integers
            let downscaledROIRectangle = ROIRectangle.applying(CGAffineTransform(scaleX: downscale, y: downscale))
            outputImageWidth = downscaledROIRectangle.width.rounded(.down)
            outputImageHeight = downscaledROIRectangle.height.rounded(.down)
            let adjustedScaleX = outputImageWidth / ROIRectangle.width
            let adjustedScaleY = outputImageHeight / ROIRectangle.height

            // concatenate with the translation transform
            transform = transform.concatenating(CGAffineTransform(scaleX: adjustedScaleX, y: adjustedScaleY))
        }

        // create the output image pool
        let poolAttributes: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: minPoolCardinality]
        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: outputImageWidth,
            kCVPixelBufferHeightKey: outputImageHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent8
        ]

        var poolOut: CVPixelBufferPool?
        var code = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, pixelBufferAttributes, &poolOut)
        guard let pool = poolOut else {
            throw WandDetectorError.couldNotCreateOutputImagePool(code: code)
        }

        // preallocate minPoolCardinality number of output images
        var outputImageOut: CVPixelBuffer?
        var outputImageRetainer = [CVPixelBuffer]() // prevents recycling during the below while loop
        let auxAttributes: NSDictionary = [kCVPixelBufferPoolAllocationThresholdKey: minPoolCardinality]

        code = kCVReturnSuccess
        while code == kCVReturnSuccess {
            code = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &outputImageOut)
            if let outputImage = outputImageOut {
                outputImageRetainer.append(outputImage)
            }
            outputImageOut = nil
        }

        assert(code == kCVReturnWouldExceedAllocationThreshold, "Unexpected CVReturn code \(code)")

        // create the context
        let context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!, // <- why?
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
        widthErosionFilter.width = 3
        widthErosionFilter.height = 1
        heightErosionFilter.width = 1
        heightErosionFilter.height = 3
        squareErosionFilter.width = 3
        squareErosionFilter.height = 3
        squareDilationFilter.width = 3
        squareDilationFilter.height = 3
        thresholdFilter.cubeDimension = 64 // max allowed by CIColorCube

        // initialize stored properties
        self.pool = pool
        self.context = context
        self.transform = transform
        self.ROIRectangle = ROIRectangle
        self.inputImageSize = inputImageSize
        self.thresholdFilter = thresholdFilter
        self.binarizationFilter = binarizationFilter
        self.widthErosionFilter = widthErosionFilter
        self.heightErosionFilter = heightErosionFilter
        self.squareErosionFilter = squareErosionFilter
        self.squareDilationFilter = squareDilationFilter
    }

    // MARK: Calibration

    public func calibrate(using wand: Wand, deadzoneScale deadzone: Double, minWandActivation minWA: Double, inRegionOfInterestIn image: CVImageBuffer) throws {
        // verify image size is correct
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        guard width == self.inputImageSize.width && height == self.inputImageSize.height else {
            throw WandDetectorError.invalidImage
        }

        // make a rectangle that bounds the wand
        let radius = abs(wand.radius)
        let diameter = radius * 2
        let wandRectangle = CGRect(origin: CGPoint(x: wand.center.x - radius, y: wand.center.y - radius), size: CGSize(width: diameter, height: diameter))

        assert(wandRectangle.midX == CGFloat(wand.center.x) && wandRectangle.midY == CGFloat(wand.center.y), "wandRectangle is centered incorrectly")

        // verify region of interest contains the wand
        guard self.ROIRectangle.contains(wandRectangle) else {
            throw WandDetectorError.invalidWand
        }

        // apply the transform to the wand rectangle and create the transformed wand
        let transformedWandRectangle = wandRectangle.applying(self.transform)
        let transformedWand: Wand = (center: (x: Double(transformedWandRectangle.midX), y: Double(transformedWandRectangle.midY)), radius: Double(transformedWandRectangle.width / 2))

        // crop and transform the image
        let transformedImage = CIImage(cvImageBuffer: image).cropped(to: self.ROIRectangle).transformed(by: self.transform)

        // get width and height of transformedImage
        let transformedWidth = Int(transformedImage.extent.width.rounded(.down))
        let transformedHeight = Int(transformedImage.extent.height.rounded(.down))

        // create the calibration image to render into
        var calibrationImageOut: CVPixelBuffer?
        let code = CVPixelBufferCreate(kCFAllocatorDefault, transformedWidth, transformedHeight, kCVPixelFormatType_32BGRA, nil, &calibrationImageOut)
        guard let calibrationImage = calibrationImageOut else {
            throw WandDetectorError.couldNotCreateCalibrationImage(code: code)
        }

        // render to the calibration image using the working color space as the output color space
        let bounds = CGRect(origin: .zero, size: CGSize(width: transformedWidth, height: transformedHeight))
        self.context.render(transformedImage, to: calibrationImage, bounds: bounds, colorSpace: self.context.workingColorSpace!)

        // get calibration image pixels in HSB format
        var pixels = [(h: CGFloat, s: CGFloat, b: CGFloat, isWand: Bool)]()
        calibrationImage.withPixelGetter(getting: UInt32.self, { getPixelAt in
            let width = CVPixelBufferGetWidth(calibrationImage)
            let height = CVPixelBufferGetHeight(calibrationImage)
            let deadzoneRadius = transformedWand.radius * abs(deadzone)

            for x in 0..<width {
                for y in 0..<height {
                    let point: PixelPoint = (x: x, y: y)
                    if let pixel = getPixelAt(point) {
                        // create an rgba color from the pixel bits
                        let blue = CGFloat((pixel << 24) >> 24) / 255
                        let green = CGFloat((pixel << 16) >> 24) / 255
                        let red = CGFloat((pixel << 8) >> 24) / 255
                        let rgba = UIColor(red: red, green: green, blue: blue, alpha: 1)

                        // get the HSB values
                        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
                        rgba.getHue(&h, saturation: &s, brightness: &b, alpha: nil)

                        // determine if wand pixel
                        let distanceFromWandCenter = sqrt(pow(Double(x) - transformedWand.center.x, 2) + pow(Double(y) - transformedWand.center.y, 2))
                        let isWand = distanceFromWandCenter <= transformedWand.radius

                        // ignore background pixels in the deadzone
                        if !isWand && distanceFromWandCenter <= deadzoneRadius { continue }

                        pixels.append((h, s, b, isWand))
                    }
                }
            }
        })

        assert(pixels.count > 0)

        // find the arc on the hue circle with the greatest portion of the wand
        var wandfullArc = 0
        var greatestPixelsInAnArc = 0
        let arcs = 360
        let unitRotation = 1 / CGFloat(arcs)
        let halfRotation: CGFloat = 0.5 // 180 degrees
        let halfArcAngle: CGFloat = 30 / 360 // arcs are 60 degrees
        let arcRange = (halfRotation - halfArcAngle)...(halfRotation + halfArcAngle)

        var wandPixels = pixels.filter({ $0.isWand })
        for arc in 0..<arcs {
            let hueRotation = CGFloat(arc) * unitRotation // will rotate hue circle so degree 180 bisects the arc

            let pixelsInArc = wandPixels.filter({ arcRange.contains($0.h.rotated(by: hueRotation)) }).count

            if pixelsInArc > greatestPixelsInAnArc {
                greatestPixelsInAnArc = pixelsInArc
                wandfullArc = arc
            }
        }

        // rotate the hue values and filter for pixels that are in wandfullArc
        let hueRotation = CGFloat(wandfullArc) * unitRotation
        pixels = pixels.map({ ($0.h.rotated(by: hueRotation), $0.s, $0.b, $0.isWand) }).filter({ arcRange.contains($0.h) })

        assert(pixels.count > 0)

        // create wandfull HSB ranges
        wandPixels = pixels.filter({ $0.isWand })
        wandPixels.sort(by: { $0.h < $1.h })
        let wandfullHueRange = wandPixels.first!.h...wandPixels.last!.h
        wandPixels.sort(by: { $0.s < $1.s })
        let wandfullSaturationRange = wandPixels.first!.s...wandPixels.last!.s
        wandPixels.sort(by: { $0.b < $1.b })
        let wandfullBrightnessRange = wandPixels.first!.b...wandPixels.last!.b

        // filter for pixels that are in wandfull HSB ranges
        pixels = pixels.filter({ wandfullHueRange.contains($0.h) && wandfullSaturationRange.contains($0.s) && wandfullBrightnessRange.contains($0.b) })

        assert(pixels.count > 0)

        // get min wand activation pixel count
        let clampedMinWA = minWA.clamped(to: 0.nextUp...1)
        let minWAC = Int((Double(wandPixels.count) * clampedMinWA).rounded(.up))

        // create HSB range combinations where only one range is optimized
        var rangeCombos = [(score: Int, WAC: Int, hueRange: ClosedRange<CGFloat>, saturationRange: ClosedRange<CGFloat>, brightnessRange: ClosedRange<CGFloat>)]()
        for i in 0..<3 {
            switch i {
            case 0:
                pixels.sort(by: { $0.h < $1.h })
            case 1:
                pixels.sort(by: { $0.s < $1.s })
            default:
                pixels.sort(by: { $0.b < $1.b })
            }

            var upper = 0, lower = 0
            var bestScore = Int.min, score = 0, WAC = 0
            for i in 0..<pixels.count { // find the best upper bound
                if pixels[i].isWand {
                    score += 1; WAC += 1;

                    if WAC >= minWAC && score >= bestScore {
                        bestScore = score
                        upper = i
                    }
                } else { score -= 1 }
            }

            var bestWAC = 0
            bestScore = Int.min; score = 0; WAC = 0
            for i in (0...upper).reversed() { // find the best lower bound
                if pixels[i].isWand {
                    score += 1; WAC += 1;

                    if WAC >= minWAC && score >= bestScore {
                        bestScore = score
                        bestWAC = WAC
                        lower = i
                    }
                } else { score -= 1 }
            }

            switch i {
            case 0:
                rangeCombos.append((bestScore, bestWAC, pixels[lower].h...pixels[upper].h, wandfullSaturationRange, wandfullBrightnessRange))
            case 1:
                rangeCombos.append((bestScore, bestWAC, wandfullHueRange, pixels[lower].s...pixels[upper].s, wandfullBrightnessRange))
            default:
                rangeCombos.append((bestScore, bestWAC, wandfullHueRange, wandfullSaturationRange, pixels[lower].b...pixels[upper].b))
            }
        }

        // get HSB ranges from the highest scoring range combo using WAC as a tie breaker
        var bestRangeCombo = rangeCombos.max(by: { $0.score < $1.score })!
        bestRangeCombo = rangeCombos.first(where: { $0.score == bestRangeCombo.score && $0.WAC > bestRangeCombo.WAC }) ?? bestRangeCombo
        let hueRange = bestRangeCombo.hueRange
        let saturationRange = bestRangeCombo.saturationRange
        let brightnessRange = bestRangeCombo.brightnessRange

        // create color cube data
        var colorCube = [Float]()
        let dimension = Int(self.thresholdFilter.cubeDimension - 1)
        for b in 0...dimension {
            let blue = CGFloat(b) / CGFloat(dimension)
            for g in 0...dimension {
                let green = CGFloat(g) / CGFloat(dimension)
                for r in 0...dimension {
                    let red = CGFloat(r) / CGFloat(dimension)

                    // create an rgba color
                    let rgba = UIColor(red: red, green: green, blue: blue, alpha: 1)

                    // get the HSB values
                    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
                    rgba.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
                    h = h.rotated(by: hueRotation)

                    // use white color if all HSB values are in range, black otherwise
                    let color: Float =
                        hueRange.contains(h) &&
                        saturationRange.contains(s) &&
                        brightnessRange.contains(b) ? 1 : 0

                    colorCube.append(color) // red
                    colorCube.append(color) // green
                    colorCube.append(color) // blue
                    colorCube.append(1)     // alpha
                }
            }
        }

        let colorCubeData = colorCube.withUnsafeBufferPointer({ buffer in Data(buffer: buffer) })

        // configure the threshold filter
        self.thresholdFilter.cubeData = colorCubeData

        // if calibration requires the user to position the wand m meters distance from the camera
        // then we can compute the size of the wand at max_m distance and see if that size is >=
        // some minimum size (maybe 3x3 pixels) which can then be used as the break condition
        // for calibrating the width and height erosion filters
    }

//    // MARK: Detection
//
//    public func detect(inRegionOfInterestIn image: CVImageBuffer) throws -> CVImageBuffer {
//        // verify image size is correct
//        let width = CVPixelBufferGetWidth(image)
//        let height = CVPixelBufferGetHeight(image)
//        guard width == self.inputImageSize.width && height == self.inputImageSize.height else {
//            throw WandDetectorError.invalidImage
//        }
//
//        return try self.filter(image: image)
//    }

    // MARK: Filtration

    private func filter(image: CVImageBuffer) throws -> CVImageBuffer {
        // crop
        let cropped = CIImage(cvImageBuffer: image).cropped(to: self.ROIRectangle)

        // transform
        let transformed = cropped.transformed(by: self.transform)

        // threshold
        self.thresholdFilter.inputImage = transformed
        let thresholded = self.thresholdFilter.outputImage

        // binarize
        self.binarizationFilter.inputImage = thresholded
        let binarized = self.binarizationFilter.outputImage

        // clamp
        let clamped = binarized?.clampedToExtent()

        // square dilate
        self.squareDilationFilter.inputImage = clamped
        let squareDilated = self.squareDilationFilter.outputImage

        // square erode
        self.squareErosionFilter.inputImage = squareDilated
        let squareEroded = self.squareErosionFilter.outputImage

        // width erode
        self.widthErosionFilter.inputImage = squareEroded
        let widthEroded = self.widthErosionFilter.outputImage

        // height erode
        self.heightErosionFilter.inputImage = widthEroded
        let heightEroded = self.heightErosionFilter.outputImage

        // unwrap
        guard let filtered = heightEroded else {
            throw WandDetectorError.couldNotFilterImage
        }

        // create the output image to render into
        var outputImageOut: CVPixelBuffer?
        let code = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pool, &outputImageOut)
        guard let outputImage = outputImageOut else {
            throw WandDetectorError.couldNotCreateOutputImage(code: code)
        }

        // render to the output image
        self.context.render(filtered, to: outputImage)

        return outputImage

        // WARNING!
        // when contour tracing don't forget to correct wand's
        // area according to the number of pixels eroded
    }
}

// MARK: Extensions

private extension CVImageBuffer {
    func withPixelGetter<T, R>(getting type: T.Type, _ body: ((PixelPoint) -> T?) -> R) -> R {
        assert(CVPixelBufferGetPlaneCount(self) == 0)

        // create dimension ranges
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)
        let widthRange = 0..<width
        let heightRange = 0..<height

        // calculate row length
        let rowBytes = CVPixelBufferGetBytesPerRow(self)
        let pixelSize = MemoryLayout<T>.size
        let rowLength = rowBytes / pixelSize

        // lock and later unlock
        CVPixelBufferLockBaseAddress(self, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(self, .readOnly) }

        // get pixels
        let baseAddress = CVPixelBufferGetBaseAddress(self)
        let pixels = unsafeBitCast(baseAddress, to: UnsafePointer<T>.self)

        // call body with a pixel getter function
        return body({ pixelPoint in
            let (x, y) = pixelPoint
            let inImage = widthRange.contains(x) && heightRange.contains(y)
            return inImage ? pixels[x + (y * rowLength)] : nil
        })
    }
}

private extension CGFloat {
    func rotated(by rotation: CGFloat) -> CGFloat {
        return (self + rotation).truncatingRemainder(dividingBy: 1)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return max(range.lowerBound, min(self, range.upperBound))
    }
}
