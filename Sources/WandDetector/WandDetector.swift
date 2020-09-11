import ContourTracer
import CoreImage.CIFilterBuiltins

#if os(iOS) || os(tvOS)
import UIKit.UIColor
fileprivate typealias Color = UIColor
#elseif os(macOS)
import AppKit.NSColor
fileprivate typealias Color = NSColor
#endif

fileprivate typealias PixelPoint = (x: Int, y: Int)
public typealias ImageSize = (width: Int, height: Int)
public typealias Wand = (center: (x: Double, y: Double), radius: Double)
public typealias ImageRegion = (origin: (x: Int, y: Int), size: ImageSize)

public enum WandDetectorError: Error {
    case invalidWand
    case invalidImage
    case couldNotFilterImage
    case invalidMinWandRadius
    case regionOfInterestDoesNotContainWand
    case invalidOutputImagePoolMinCardinality
    case imageSizeDoesNotContainRegionOfInterest
    case couldNotCreateOutputImage(code: CVReturn)
    case couldNotCreateOutputImagePool(code: CVReturn)
}

public struct WandDetector {
    // TODO: calculate maxOutputImagePixels based on some fidelity length and
    // screen projection size at some standard gameplay distance for that screen
    private let maxOutputImagePixels = 50_000 // <- why?
    private let thresholdFilter = CIFilter.colorCube()
    private let binarizationFilter = CIFilter.colorPosterize()
    private let widthErosionFilter = CIFilter.morphologyRectangleMinimum()
    private let heightErosionFilter = CIFilter.morphologyRectangleMinimum()
    private let squareErosionFilter = CIFilter.morphologyRectangleMinimum()
    private let squareDilationFilter = CIFilter.morphologyRectangleMaximum()
    private let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!, // <- why?
    ])

    private let minWA: Double
    private let rowStride: Int
    private let ROIRectangle: CGRect
    private let imageRectangle: CGRect
    private let pool: CVPixelBufferPool
    private let transform: CGAffineTransform

    // MARK: Initialization

    public init(imageSize: ImageSize, regionOfInterest ROI: ImageRegion, minWandActivation minWA: Double, minWandRadius: Double = 0, outputImagePoolMinCardinality minPoolCardinality: Int = 1) throws {
        // verify min pool cardinality is positive
        guard minPoolCardinality > 0 else {
            throw WandDetectorError.invalidOutputImagePoolMinCardinality
        }

        // verify min wand radius is nonnegative
        guard minWandRadius >= 0 else {
            throw WandDetectorError.invalidMinWandRadius
        }

        // make rectangle from min wand radius
        let minWandDiameter = minWandRadius * 2
        let minWandRectangle = CGRect(origin: .zero, size: CGSize(width: minWandDiameter, height: minWandDiameter))

        // make rectangle from image size
        let imageRectangle = CGRect(origin: .zero, size: CGSize(width: imageSize.width, height: imageSize.height))

        // make rectangle from region of interest
        let ROIRectangle = CGRect(origin: CGPoint(x: ROI.origin.x, y: ROI.origin.y), size: CGSize(width: ROI.size.width, height: ROI.size.height))

        // verify image contains region of interest
        guard imageRectangle.contains(ROIRectangle) else {
            throw WandDetectorError.imageSizeDoesNotContainRegionOfInterest
        }

        // create the translation transform
        let dx = -ROIRectangle.origin.x
        let dy = -ROIRectangle.origin.y
        var transform = CGAffineTransform(translationX: dx, y: dy)

        // width and height for the output images
        var outputImageWidth = Int(ROIRectangle.width)
        var outputImageHeight = Int(ROIRectangle.height)

        let outputImagePixels = outputImageWidth * outputImageHeight
        if outputImagePixels > self.maxOutputImagePixels { // create a downscale transform
            let downscale = CGFloat(sqrt(Double(self.maxOutputImagePixels) / Double(outputImagePixels)))

            // adjust the downscale so output width and height will still be integers
            let downscaledROIRectangle = ROIRectangle.applying(CGAffineTransform(scaleX: downscale, y: downscale))
            outputImageWidth = Int(downscaledROIRectangle.width.rounded(.down))
            outputImageHeight = Int(downscaledROIRectangle.height.rounded(.down))
            let adjustedDownscaleX = CGFloat(outputImageWidth) / ROIRectangle.width
            let adjustedDownscaleY = CGFloat(outputImageHeight) / ROIRectangle.height

            // concatenate with the translation transform
            transform = transform.concatenating(CGAffineTransform(scaleX: adjustedDownscaleX, y: adjustedDownscaleY))
        }

        // transform min wand to get the row stride
        let transformedMinWandRectangle = minWandRectangle.applying(transform)
        let rowStride = Int(transformedMinWandRectangle.width.rounded(.down)).clamped(to: 1...Int.max)

        // create the output image pool
        let poolAttributes: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: minPoolCardinality]
        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: outputImageWidth,
            kCVPixelBufferHeightKey: outputImageHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent8 // grayscale pixels
        ]

        var poolOut: CVPixelBufferPool?
        var code = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, pixelBufferAttributes, &poolOut)
        guard let pool = poolOut else {
            throw WandDetectorError.couldNotCreateOutputImagePool(code: code)
        }

        // preallocate min pool cardinality number of output images
        var outputImageOut: CVPixelBuffer?
        var outputImageRetainer = [CVPixelBuffer]() // prevents pool from recycling during the below while loop
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

        // configure the filters
        self.binarizationFilter.levels = 2
        self.widthErosionFilter.width = 3 // should this be proportional to maxOutputImagePixels?
        self.widthErosionFilter.height = 1
        self.heightErosionFilter.width = 1
        self.heightErosionFilter.height = 3
        self.squareErosionFilter.width = 3
        self.squareErosionFilter.height = 3
        self.squareDilationFilter.width = 3
        self.squareDilationFilter.height = 3
        self.thresholdFilter.cubeData = Data()
        self.thresholdFilter.cubeDimension = 64 // max allowed by CIColorCube

        // initialize stored properties
        self.pool = pool
        self.minWA = minWA
        self.transform = transform
        self.rowStride = rowStride
        self.ROIRectangle = ROIRectangle
        self.imageRectangle = imageRectangle
    }

    // MARK: Calibration

    public func calibrate(using image: CVImageBuffer, _ wand: Wand, deadzoneScale deadzone: Double) throws {
        // verify image size is correct
        guard CVImageBufferGetEncodedSize(image).equalTo(self.imageRectangle.size) else {
            throw WandDetectorError.invalidImage
        }

        // verify wand radius is positive
        guard wand.radius > 0 else {
            throw WandDetectorError.invalidWand
        }

        // make rectangle from wand
        let wandDiameter = wand.radius * 2
        let wandRectangle = CGRect(origin: CGPoint(x: wand.center.x - wand.radius, y: wand.center.y - wand.radius), size: CGSize(width: wandDiameter, height: wandDiameter))

        assert(wandRectangle.midX.rounded() == CGFloat(wand.center.x).rounded() && wandRectangle.midY.rounded() == CGFloat(wand.center.y).rounded(), "wandRectangle is centered incorrectly")

        // verify region of interest contains wand
        guard self.ROIRectangle.contains(wandRectangle) else {
            throw WandDetectorError.regionOfInterestDoesNotContainWand
        }

        // transform the wand
        let transformedWandRectangle = wandRectangle.applying(self.transform)
        let transformedWand: Wand = (center: (x: Double(transformedWandRectangle.midX), y: Double(transformedWandRectangle.midY)), radius: Double(transformedWandRectangle.width / 2))

        // crop image to region of interest and transform
        let transformedImage = CIImage(cvImageBuffer: image).cropped(to: self.ROIRectangle).transformed(by: self.transform)

        // create the output image to render into
        var outputImageOut: CVPixelBuffer?
        let code = CVPixelBufferCreate(kCFAllocatorDefault, Int(transformedImage.extent.width), Int(transformedImage.extent.height), kCVPixelFormatType_32BGRA, nil, &outputImageOut)
        guard let outputImage = outputImageOut else {
            throw WandDetectorError.couldNotCreateOutputImage(code: code)
        }

        // render to the output image using the working color space as the output color space
        let bounds = CGRect(origin: .zero, size: CVImageBufferGetEncodedSize(outputImage))
        self.context.render(transformedImage, to: outputImage, bounds: bounds, colorSpace: self.context.workingColorSpace!)

        // get output image pixels in HSB format
        var pixels = [(h: CGFloat, s: CGFloat, b: CGFloat, isWand: Bool)]()
        outputImage.withPixelGetter({ getPixelAt in
            let width = CVPixelBufferGetWidth(outputImage)
            let height = CVPixelBufferGetHeight(outputImage)
            let deadzoneRadius = transformedWand.radius * abs(deadzone)

            for row in 0..<height {
                for col in 0..<width {
                    let point: PixelPoint = (x: col, y: row)
                    guard let pixel = getPixelAt(point) else { continue }

                    // create an rgba color from the UInt32 pixel bits
                    let blue = CGFloat((pixel << 24) >> 24) / 255
                    let green = CGFloat((pixel << 16) >> 24) / 255
                    let red = CGFloat((pixel << 8) >> 24) / 255

                    let rgba = Color(red: red, green: green, blue: blue, alpha: 1)

                    // get the HSB values
                    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
                    rgba.getHue(&h, saturation: &s, brightness: &b, alpha: nil)

                    // determine if wand pixel
                    let distanceFromWandCenter = sqrt(pow(Double(point.x) - transformedWand.center.x, 2) + pow(Double(point.y) - transformedWand.center.y, 2))
                    let isWand = distanceFromWandCenter <= transformedWand.radius

                    // verify pixel is not in the deadzone
                    guard isWand || distanceFromWandCenter > deadzoneRadius else { continue }

                    pixels.append((h, s, b, isWand))
                }
            }
        }, getting: UInt32.self)

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
            guard pixelsInArc > greatestPixelsInAnArc else { continue }
            greatestPixelsInAnArc = pixelsInArc
            wandfullArc = arc
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
        let clampedMinWA = self.minWA.clamped(to: 0.nextUp...1)
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
                    guard WAC >= minWAC && score >= bestScore else { continue }
                    bestScore = score; upper = i
                } else { score -= 1 }
            }

            var bestWAC = 0
            bestScore = Int.min; score = 0; WAC = 0
            for i in (0...upper).reversed() { // find the best lower bound
                if pixels[i].isWand {
                    score += 1; WAC += 1;
                    guard WAC >= minWAC && score >= bestScore else { continue }
                    bestScore = score; bestWAC = WAC; lower = i
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
        let oldColorCube = self.thresholdFilter.cubeData.count > 0 ? self.thresholdFilter.cubeData.withUnsafeBytes({ unsafeBitCast($0, to: UnsafeBufferPointer<Float>.self) }) : nil
        let gamut = Int(self.thresholdFilter.cubeDimension - 1)
        for b in 0...gamut {
            let blue = CGFloat(b) / CGFloat(gamut)
            for g in 0...gamut {
                let green = CGFloat(g) / CGFloat(gamut)
                for r in 0...gamut {
                    let red = CGFloat(r) / CGFloat(gamut)

                    // get old color
                    let oldColor = oldColorCube?[(b * (gamut + 1) * (gamut + 1) * 4) + (g * (gamut + 1) * 4) + (r * 4)]

                    // create an rgba color
                    let rgba = Color(red: red, green: green, blue: blue, alpha: 1)

                    // get the HSB values
                    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
                    rgba.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
                    h = h.rotated(by: hueRotation)

                    // white if all HSB values are in range, black otherwise
                    let color: Float =
                        oldColor == 1 ||
                        (hueRange.contains(h) &&
                        saturationRange.contains(s) &&
                        brightnessRange.contains(b)) ? 1 : 0

                    colorCube.append(color) // red
                    colorCube.append(color) // green
                    colorCube.append(color) // blue
                    colorCube.append(1)     // alpha
                }
            }
        }

        let cubeData = colorCube.withUnsafeBufferPointer({ Data(buffer: $0) })

        // configure the threshold filter
        self.thresholdFilter.cubeData = cubeData
    }

    // MARK: Detection

    public func detect(in image: CVImageBuffer, shouldContinueAfterDetecting: (Wand) -> Bool) throws -> CVImageBuffer {
        // verify image size is correct
        guard CVImageBufferGetEncodedSize(image).equalTo(self.imageRectangle.size) else {
            throw WandDetectorError.invalidImage
        }

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

        // use contour tracing to detect wands in the output image
        outputImage.withPixelGetter({ getPixelAt in
            let width = CVPixelBufferGetWidth(outputImage)
            let height = CVPixelBufferGetHeight(outputImage)

            ContourTracer.trace(
                size: (width, height),
                canTrace: {
                    guard let pixel = getPixelAt($0) else { return false }
                    return pixel != 0
                },
                shouldScan: { $0 % self.rowStride == 0 },
                shouldContinueAfterTracing: {
                    let (_, (x, y), area) = $0

                    guard area > 0 else { return true }

                    // calculate the wand radius
                    var radius = sqrt(area / .pi)

                    // correct radius to undo affect of the width and height erosion filters
                    radius += 1

                    // make rectangle from wand
                    let diameter = radius * 2
                    let wandRectangle = CGRect(origin: CGPoint(x: x - radius, y: y - radius), size: CGSize(width: diameter, height: diameter))

                    assert(wandRectangle.midX.rounded() == CGFloat(x).rounded() && wandRectangle.midY.rounded() == CGFloat(y).rounded(), "wandRectangle is centered incorrectly")

                    // untransform the wand
                    let untransformedWandRectangle = wandRectangle.applying(self.transform.inverted())
                    let untransformedWand: Wand = (center: (x: Double(untransformedWandRectangle.midX), y: Double(untransformedWandRectangle.midY)), radius: Double(untransformedWandRectangle.width / 2))

                    return shouldContinueAfterDetecting(untransformedWand)
            })

        }, getting: UInt8.self)

        return outputImage
    }
}

// MARK: Extensions

fileprivate extension CVImageBuffer {
    func withPixelGetter<T, R>(_ body: ((PixelPoint) -> T?) -> R, getting type: T.Type) -> R {
        assert(CVPixelBufferGetPlaneCount(self) == 0)

        // create dimension ranges
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)
        let widthRange = 0..<width
        let heightRange = 0..<height

        // calculate row length
        let rowBytes = CVPixelBufferGetBytesPerRow(self)
        let pixelStride = MemoryLayout<T>.stride
        let rowLength = rowBytes / pixelStride

        // lock and later unlock
        CVPixelBufferLockBaseAddress(self, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(self, .readOnly) }

        // get pixels
        let baseAddress = CVPixelBufferGetBaseAddress(self)
        let pixels = unsafeBitCast(baseAddress, to: UnsafePointer<T>.self)

        // call body with a pixel getter function
        return body({ (x, y) in
            guard widthRange.contains(x) && heightRange.contains(y) else { return nil }
            return pixels[(y * rowLength) + x]
        })
    }
}

fileprivate extension CGFloat {
    func rotated(by rotation: CGFloat) -> CGFloat {
        return (self + rotation).truncatingRemainder(dividingBy: 1)
    }
}

fileprivate extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return max(range.lowerBound, min(self, range.upperBound))
    }
}
