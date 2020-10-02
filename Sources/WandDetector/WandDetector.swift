import ContourTracer
import CoreImage.CIFilterBuiltins

#if canImport(UIKit)
import UIKit.UIColor
fileprivate typealias Color = UIColor
#else
import AppKit.NSColor
fileprivate typealias Color = NSColor
#endif

fileprivate typealias PixelPoint = (x: Int, y: Int)

public typealias ResetToLastCalibration = () -> Void
public typealias Wand = (center: (x: CGFloat, y: CGFloat), radius: CGFloat)

public enum WandDetectorError: Error {
    case couldNotApplyFilters
    case imageOriginIsNotZero
    case imageDoesNotContainWand
    case wandDoesNotContainPixels
    case couldNotCreatePixelBuffer(code: CVReturn)
    case couldNotCreatePixelBufferPool(code: CVReturn)
}

public struct WandDetector {
    private let maxDimension: Int
    private let pool: CVPixelBufferPool

    private let rangeFilter = CIFilter.colorCube()
    private let widthErosionFilter = CIFilter.morphologyRectangleMinimum()
    private let heightErosionFilter = CIFilter.morphologyRectangleMinimum()
    private let squareErosionFilter = CIFilter.morphologyRectangleMinimum()
    private let squareDilationFilter = CIFilter.morphologyRectangleMaximum()
    private let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!, // <- why?
    ])

    // MARK: Initialization

    public init(maxImageDimension: Int, maxRunningDetections: Int = 1) throws {
        // clamp arguments
        let maxOutputSize = self.context.outputImageMaximumSize()
        let maxOutputDimension = Int(min(maxOutputSize.width, maxOutputSize.height))
        let maxDimension = abs(maxImageDimension).clamped(to: 1...maxOutputDimension)
        let maxDetections = abs(maxRunningDetections).clamped(to: 1...(.max))

        // create the pixel buffer pool
        let poolAttributes: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: maxDetections]
        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: maxDimension,
            kCVPixelBufferHeightKey: maxDimension,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent8 // grayscale pixels
        ]

        var poolOut: CVPixelBufferPool?
        var code = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, pixelBufferAttributes, &poolOut)
        guard let pool = poolOut else {
            throw WandDetectorError.couldNotCreatePixelBufferPool(code: code)
        }

        // preallocate max detections number of pixel buffers
        var pixelBufferOut: CVPixelBuffer?
        var pixelBufferRetainer = [CVPixelBuffer]() // prevents pool from recycling during the below while loop
        let auxAttributes: NSDictionary = [kCVPixelBufferPoolAllocationThresholdKey: maxDetections]

        code = kCVReturnSuccess
        while code == kCVReturnSuccess {
            code = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &pixelBufferOut)
            if let pixelBuffer = pixelBufferOut {
                pixelBufferRetainer.append(pixelBuffer)
            }
            pixelBufferOut = nil
        }

        assert(code == kCVReturnWouldExceedAllocationThreshold, "Unexpected CVReturn code: \(code)")

        // configure the filters
        self.rangeFilter.cubeData = Data() // data is empty until calibration
        self.rangeFilter.cubeDimension = 64 // max allowed by CIColorCube
        self.widthErosionFilter.width = 3 // should this be proportional to image size?
        self.widthErosionFilter.height = 1 // should this be configured during detection?
        self.heightErosionFilter.width = 1
        self.heightErosionFilter.height = 3
        self.squareErosionFilter.width = 3
        self.squareErosionFilter.height = 3
        self.squareDilationFilter.width = 3
        self.squareDilationFilter.height = 3

        // initialize stored properties
        self.pool = pool
        self.maxDimension = maxDimension
    }

    // MARK: Calibration

    public func calibrate(using image: CIImage, _ wand: Wand, deadzoneScale: CGFloat = 1, minWandActivation: CGFloat = 1) throws -> ResetToLastCalibration {
        // verify image origin is zero
        let extent = image.extent
        guard extent.origin == .zero else {
            throw WandDetectorError.imageOriginIsNotZero
        }

        // verify image contains the wand
        let wandDiameter = wand.radius * 2
        let wandRectangle = CGRect(x: wand.center.x - wand.radius, y: wand.center.y - wand.radius, width: wandDiameter, height: wandDiameter)
        guard extent.contains(wandRectangle) else {
            throw WandDetectorError.imageDoesNotContainWand
        }

        // clamp arguments
        let minWA = abs(minWandActivation).clamped(to: .leastNonzeroMagnitude...1)
        let deadzone = abs(deadzoneScale).clamped(to: 1...(.greatestFiniteMagnitude))

        // create the downscale transform
        var transform = CGAffineTransform.identity
        let greatestDimension = max(extent.width, extent.height)
        if greatestDimension > CGFloat(self.maxDimension) {
            let downscale = CGFloat(self.maxDimension) / greatestDimension
            transform = CGAffineTransform(scaleX: downscale, y: downscale)
        }

        // downscale
        let downscaledImage = image.transformed(by: transform)
        let downscaledWandRectangle = wandRectangle.applying(transform)
        let downscaledWand: Wand = (center: (x: downscaledWandRectangle.midX, y: downscaledWandRectangle.midY), radius: downscaledWandRectangle.width / 2)

        // create the pixel buffer to render into
        let pixelBufferWidth = Int(downscaledImage.extent.width.rounded(.down))
        let pixelBufferHeight = Int(downscaledImage.extent.height.rounded(.down))
        var pixelBufferOut: CVPixelBuffer?
        let code = CVPixelBufferCreate(kCFAllocatorDefault, pixelBufferWidth, pixelBufferHeight, kCVPixelFormatType_32BGRA, nil, &pixelBufferOut)
        guard let pixelBuffer = pixelBufferOut else {
            throw WandDetectorError.couldNotCreatePixelBuffer(code: code)
        }

        // render to the pixel buffer using the working color space as the destination color space
        let bounds = CGRect(x: 0, y: 0, width: pixelBufferWidth, height: pixelBufferHeight)
        self.context.render(downscaledImage, to: pixelBuffer, bounds: bounds, colorSpace: self.context.workingColorSpace!)

        // get pixels in HSB format
        var pixels = [(h: CGFloat, s: CGFloat, b: CGFloat, isWand: Bool)]()
        pixelBuffer.withPixelGetter({ getPixelAt in
            let deadzoneRadius = downscaledWand.radius * deadzone

            for row in 0..<pixelBufferHeight {
                for col in 0..<pixelBufferWidth {
                    let point: PixelPoint = (x: col, y: row)
                    guard let pixel = getPixelAt(point) else { continue }

                    // determine if wand pixel
                    let distanceFromWandCenter = sqrt(pow(CGFloat(point.x) - downscaledWand.center.x, 2) + pow(CGFloat(point.y) - downscaledWand.center.y, 2))
                    let isWand = distanceFromWandCenter <= downscaledWand.radius

                    // verify pixel is not in the deadzone
                    guard isWand || distanceFromWandCenter > deadzoneRadius else { continue }

                    // create an rgba color from the UInt32 pixel bits
                    let blue = CGFloat((pixel << 24) >> 24) / 255
                    let green = CGFloat((pixel << 16) >> 24) / 255
                    let red = CGFloat((pixel << 8) >> 24) / 255
                    let rgba = Color(red: red, green: green, blue: blue, alpha: 1)

                    // get the HSB values
                    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
                    rgba.getHue(&h, saturation: &s, brightness: &b, alpha: nil)

                    pixels.append((h, s, b, isWand))
                }
            }
        }, getting: UInt32.self)

        // verify there are wand pixels
        var wandPixels = pixels.filter({ $0.isWand })
        guard wandPixels.count > 0 else {
            throw WandDetectorError.wandDoesNotContainPixels
        }

        // find the arc on the hue circle with the greatest portion of the wand
        var wandfullArc = 0
        var greatestPixelsInAnArc = 0
        let arcs = 360
        let unitRotation = 1 / CGFloat(arcs)
        let halfRotation: CGFloat = 0.5 // 180 degrees
        let halfArcAngle: CGFloat = 30 / 360 // arcs are 60 degrees
        let arcRange = (halfRotation - halfArcAngle)...(halfRotation + halfArcAngle)
        for arc in 0..<arcs {
            let hueRotation = CGFloat(arc) * unitRotation // rotates hue circle so degree 180 bisects the arc

            let pixelsInArc = wandPixels.filter({ arcRange.contains($0.h.rotated(by: hueRotation)) }).count
            if pixelsInArc > greatestPixelsInAnArc {
                greatestPixelsInAnArc = pixelsInArc
                wandfullArc = arc
            }
        }

        // rotate the hue values and filter for pixels that are in wandfullArc
        let hueRotation = CGFloat(wandfullArc) * unitRotation
        pixels = pixels.map({ ($0.h.rotated(by: hueRotation), $0.s, $0.b, $0.isWand) }).filter({ arcRange.contains($0.h) })

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

        // get min wand activation pixel count
        let minWAC = Int((CGFloat(wandPixels.count) * minWA).rounded(.up))

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
                    if  WAC >= minWAC && score >= bestScore {
                        bestScore = score; upper = i
                    }
                } else { score -= 1 }
            }

            var bestWAC = 0
            bestScore = Int.min; score = 0; WAC = 0
            for i in (0...upper).reversed() { // find the best lower bound
                if pixels[i].isWand {
                    score += 1; WAC += 1;
                    if WAC >= minWAC && score >= bestScore {
                        bestScore = score; bestWAC = WAC; lower = i
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
        let bestRangeCombo = rangeCombos.max(by: { $0.score != $1.score ? $0.score < $1.score : $0.WAC < $1.WAC })!
        let hueRange = bestRangeCombo.hueRange
        let saturationRange = bestRangeCombo.saturationRange
        let brightnessRange = bestRangeCombo.brightnessRange

        // create color cube data
        var colorCube = [Float]()
        let oldCubeData = self.rangeFilter.cubeData
        let oldColorCube = oldCubeData.count > 0 ? oldCubeData.withUnsafeBytes({ unsafeBitCast($0, to: UnsafeBufferPointer<Float>.self) }) : nil
        let cubeDimension = Int(self.rangeFilter.cubeDimension)
        let gamut = cubeDimension - 1
        for b in 0...gamut {
            let blue = CGFloat(b) / CGFloat(gamut)
            for g in 0...gamut {
                let green = CGFloat(g) / CGFloat(gamut)
                for r in 0...gamut {
                    let red = CGFloat(r) / CGFloat(gamut)

                    // get the old texel
                    let rOffset = r * 4
                    let gOffset = cubeDimension * g * 4
                    let bOffset = cubeDimension * cubeDimension * b * 4
                    let index = rOffset + gOffset + bOffset
                    let oldTexel = oldColorCube?[index]

                    // create an rgba color
                    let rgba = Color(red: red, green: green, blue: blue, alpha: 1)

                    // get the HSB values
                    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
                    rgba.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
                    h = h.rotated(by: hueRotation)

                    // get the texel
                    let texel: Float =
                        oldTexel == 1 ||
                        (hueRange.contains(h) &&
                        saturationRange.contains(s) &&
                        brightnessRange.contains(b)) ? 1 : 0

                    colorCube += [texel, texel, texel, 1] // red, green, blue, alpha
                }
            }
        }

        let cubeData = colorCube.withUnsafeBufferPointer({ Data(buffer: $0) })

        // configure the range filter
        self.rangeFilter.cubeData = cubeData

        return { // a closure that sets the range filter to its prior state
            self.rangeFilter.cubeData = oldCubeData
        }
    }

    // MARK: Detection

    public func detect(in image: CIImage, minWandRadius: CGFloat = 1, shouldContinueAfterDetecting: (Wand) -> Bool) throws {
        // verify image origin is zero
        let extent = image.extent
        guard extent.origin == .zero else {
            throw WandDetectorError.imageOriginIsNotZero
        }

        // create the downscale transform and row stride
        var transform = CGAffineTransform.identity
        var minWandDiameter = CGFloat(abs(minWandRadius) * 2)
        let greatestDimension = max(extent.width, extent.height)
        if greatestDimension > CGFloat(self.maxDimension) {
            let downscale = CGFloat(self.maxDimension) / greatestDimension
            transform = CGAffineTransform(scaleX: downscale, y: downscale)
            minWandDiameter = minWandDiameter * downscale
        }
        let rowStride = Int(minWandDiameter.rounded(.down)).clamped(to: 1...(.max))

        // downscale
        let downscaled = image.transformed(by: transform)

        // range
        self.rangeFilter.inputImage = downscaled
        let ranged = self.rangeFilter.outputImage

        // clamp
        let clamped = ranged?.clampedToExtent()

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
        guard let filteredImage = heightEroded else {
            throw WandDetectorError.couldNotApplyFilters
        }

        // create the pixel buffer to render into
        var pixelBufferOut: CVPixelBuffer?
        let code = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pool, &pixelBufferOut)
        guard let pixelBuffer = pixelBufferOut else {
            throw WandDetectorError.couldNotCreatePixelBuffer(code: code)
        }

        // render to the pixel buffer
        let pixelBufferWidth = Int(downscaled.extent.width.rounded(.down))
        let pixelBufferHeight = Int(downscaled.extent.height.rounded(.down))
        let bounds = CGRect(x: 0, y: 0, width: pixelBufferWidth, height: pixelBufferHeight)
        self.context.render(filteredImage, to: pixelBuffer, bounds: bounds, colorSpace: nil)

        // detect wands in the pixel buffer by contour tracing
        pixelBuffer.withPixelGetter({ getPixelAt in
            ContourTracer.trace(
                size: (pixelBufferWidth, pixelBufferHeight),
                canTrace: {
                    guard let pixel = getPixelAt($0) else { return false }
                    return pixel >= 128 // 0.5 denormalized for UInt8
                },
                shouldScan: { $0 % rowStride == 0 },
                shouldContinueAfterTracing: {
                    let (_, (x, y), area) = $0

                    // ignore zero area contours
                    guard area > 0 else { return true }

                    // calculate the wand radius
                    var radius = sqrt(area / .pi)

                    // correct radius to undo affect of the width and height erosion filters
                    radius += 1

                    // make rectangle from wand
                    let diameter = radius * 2
                    let rectangle = CGRect(x: x - radius, y: y - radius, width: diameter, height: diameter)

                    // untransform the wand rectangle
                    let untransformed = rectangle.applying(transform.inverted())

                    // create the wand
                    let wand: Wand = (center: (x: untransformed.midX, y: untransformed.midY), radius: untransformed.width / 2)

                    return shouldContinueAfterDetecting(wand)
                }
            )

        }, getting: UInt8.self)
    }
}

// MARK: Extensions

fileprivate extension CVPixelBuffer {
    func withPixelGetter<T, R>(_ body: ((PixelPoint) -> T?) -> R, getting type: T.Type) -> R {
        assert(CVPixelBufferGetPlaneCount(self) == 0)

        // create dimension ranges
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)
        let widthRange = 0..<width
        let heightRange = 0..<height

        // get the vertical reflection
        let reflection = CVImageBufferIsFlipped(self) ? height - 1 : 0

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
            let index = (abs(reflection - y) * rowLength) + x
            return pixels[index]
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
