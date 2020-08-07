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
    case couldNotFilterImage
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
    private let squareErosionFilter: CIMorphologyRectangleMinimum
    private let squareDilationFilter: CIMorphologyRectangleMaximum

    private var widthErosionFilter: CIMorphologyRectangleMinimum?
    private var heightErosionFilter: CIMorphologyRectangleMinimum?

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
        let squareErosionFilter = CIFilter.morphologyRectangleMinimum()
        let squareDilationFilter = CIFilter.morphologyRectangleMaximum()

        // configure the filters
        binarizationFilter.levels = 2
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

        // find the arc on the hue circle with the greatest percent of the wand
        var wandfullArc = 0
        var greatestWandfullness = Double.zero
        let arcs = 12 // 3 primaries, 3 secondaries, 6 tertiaries
        let unitRotation = 1 / CGFloat(arcs)
        let halfRotation: CGFloat = 180 / 360
        let halfArcAngle: CGFloat = 30 / 360 // arcs are 60 degrees
        let prelimHueRange = (halfRotation - halfArcAngle)...(halfRotation + halfArcAngle)

        for arc in 0..<arcs {
            let hueRotation = CGFloat(arc) * unitRotation // will rotate hue circle so degree 180 bisects the arc

            let wandfullness = self.measure(percentOf: transformedWand, satisfying: { pixel in
                // create an rgba color from the pixel data
                let blue = CGFloat((pixel << 24) >> 24) / 255
                let green = CGFloat((pixel << 16) >> 24) / 255
                let red = CGFloat((pixel << 8) >> 24) / 255
                let rgba = UIColor(red: red, green: green, blue: blue, alpha: 1)

                // get the hue of the rgba color
                var hue: CGFloat = 0
                rgba.getHue(&hue, saturation: nil, brightness: nil, alpha: nil)

                hue = (hue + hueRotation).truncatingRemainder(dividingBy: 1)

                return prelimHueRange.contains(hue)
            }, in: outputImage, ofPixelType: UInt32.self)

            if wandfullness > greatestWandfullness {
                greatestWandfullness = wandfullness
                wandfullArc = arc
            }
        }

        // will rotate hue circle so degree 180 bisects the wandfullArc
        let hueRotation = CGFloat(wandfullArc) * unitRotation

        // configure the threshold filter using the preliminary hue range
        let prelimColorCube = self.createColorCube(hueRotation: hueRotation, hueRange: prelimHueRange, saturationRange: 0...1, brightnessRange: 0...1)
        self.thresholdFilter.cubeData = prelimColorCube.data
        self.thresholdFilter.cubeDimension = prelimColorCube.dimension

        // filter the image
        let prelimFilteredImage = try self.filter(image: image)

        // calculate the percent of the wand that is active, i.e. not black
        let prelimActivition = self.measure(percentOf: transformedWand, satisfying: { $0 != 0 }, in: prelimFilteredImage, ofPixelType: UInt8.self)

        // calibrate the HSB parameters used to configure the threshold filter
        let maxPrecision: CGFloat = 1 / 64 // same as the precision of the color cube?
        var parameters = [prelimHueRange.lowerBound, prelimHueRange.upperBound, 0, 1, 0, 1] // [minH, maxH, minS, maxS, minB, maxB]

        try parameters.indices.forEach { index in
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

                // configure the threshold filter
                let colorCube = self.createColorCube(hueRotation: hueRotation, hueRange: hueRange, saturationRange: saturationRange, brightnessRange: brightnessRange)
                self.thresholdFilter.cubeData = colorCube.data
                self.thresholdFilter.cubeDimension = colorCube.dimension

                // filter the image
                let filteredImage = try self.filter(image: image)

                // calculate the percent of the wand that is activated, i.e. not black
                let activation = self.measure(percentOf: transformedWand, satisfying: { $0 != 0 }, in: filteredImage, ofPixelType: UInt8.self)

                // reduce the search space
                if activation >= prelimActivition {
                    if isMinParameter { lower = middle }
                    else { upper = middle }
                } else {
                    if isMinParameter {
                        upper = middle
                        parameters[index] = lower
                    }
                    else {
                        lower = middle
                        parameters[index] = upper
                    }
                }
            }
        }

        // configure the threshold filter
        let hueRange = parameters[0]...parameters[1]
        let saturationRange = parameters[2]...parameters[3]
        let brightnessRange = parameters[4]...parameters[5]
        let colorCube = self.createColorCube(hueRotation: hueRotation, hueRange: hueRange, saturationRange: saturationRange, brightnessRange: brightnessRange)
        self.thresholdFilter.cubeData = colorCube.data
        self.thresholdFilter.cubeDimension = colorCube.dimension

//        let f = try self.filter(image: image)
//        let percentActive = self.measure(percentOf: transformedWand, satisfying: { $0 != 0 }, in: f, ofPixelType: UInt8.self)
//
//        print(parameters)
//        print(percentActive)
//
//
//        return f


        // if calibration requires the user to position the wand m meters distance from the camera
        // then we can compute the size of the wand at max_m distance and see if that size is >=
        // some minimum size (maybe 3x3 pixels) which can then be used as the break condition
        // for calibrating the width and height erosion filters
    }

    // MARK: Detection
    //
    //
    //
    //
    //

    // MARK: Filtration

    private func filter(image: CVImageBuffer) throws -> CVImageBuffer {
        // crop
        let cropped = CIImage(cvImageBuffer: image).cropped(to: self.roiRect)

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

        // maybe width erode
        self.widthErosionFilter?.inputImage = squareEroded
        let widthEroded = self.widthErosionFilter?.outputImage

        // maybe height erode
        self.heightErosionFilter?.inputImage = widthEroded
        let heightEroded = self.heightErosionFilter?.outputImage

        // unwrap
        guard let filtered = heightEroded ?? squareEroded else {
            throw WandDetectorError.couldNotFilterImage
        }

        // create the output image to render into
        var pixelBufferOut: CVPixelBuffer?
        let code = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pool, &pixelBufferOut)
        guard let outputImage = pixelBufferOut else {
            throw WandDetectorError.couldNotCreatePixelBuffer(code: code)
        }

        // render to the output image
        self.context.render(filtered, to: outputImage)

        return outputImage

        // WARNING!
        // when contour tracing don't forget to correct wand's
        // area according to the number of pixels eroded
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
                        if length <= wand.radius { // is wand pixel
                            total += 1
                            if condition(pixel) { passing += 1 }
                        }
                    }
                }
            }

            return passing / total
        }
    }

    // MARK: Color Cube Creation

    private func createColorCube(hueRotation: CGFloat, hueRange: ClosedRange<CGFloat>, saturationRange: ClosedRange<CGFloat>, brightnessRange: ClosedRange<CGFloat>) -> ColorCube {
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

        // call body with a getter function
        return body { point in
            let (x, y) = point
            let inImage = widthRange.contains(x) && heightRange.contains(y)
            return inImage ? pixels[x + (y * rowLength)] : nil
        }
    }
}
