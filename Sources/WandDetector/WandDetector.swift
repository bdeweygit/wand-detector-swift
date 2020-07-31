import CoreImage
import UIKit.UIColor
import CoreImage.CIFilterBuiltins

public typealias ImageSize = (width: Int, height: Int)
public typealias Wand = (center: (x: Double, y: Double), radius: Double)
public typealias ImageRegion = (origin: (x: Int, y: Int), size: ImageSize)

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
        let inputSizeRect = CGRect(origin: CGPoint.zero, size: CGSize(width: inputSize.width, height: inputSize.height))
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

        // create the context
        let options: [CIContextOption : Any] = [
            CIContextOption.cacheIntermediates: false,
            CIContextOption.workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!,
        ]
        let context = CIContext(options: options)

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

        // make CGRect from wand
        let diameter = wand.radius * 2
        var wandRect = CGRect(origin: CGPoint(x: wand.center.x - wand.radius, y: wand.center.y - wand.radius), size: CGSize(width: diameter, height: diameter))

        assert(wandRect.midX == CGFloat(wand.center.x) && wandRect.midY == CGFloat(wand.center.y), "wandRect is centered incorrectly")

        // verify roiRect contains wandRect
        guard self.roiRect.contains(wandRect) else {
            throw WandDetectorError.invalidWand
        }

        // apply the transform to wandRect
        wandRect = wandRect.applying(self.transform)



        // pick a point on the hue circle
        // calculate the percentage of wand pixels within the 90 degree angle bisected by the point
        // if the percentage is >= ? then rotate the point 180 degrees around the ring
        // cut the hue circle at the point so that it becomes a hue line segment

        // binary search the upper and lower hue

        // binary search the upper and lower saturation

        // binary search the upper and lower brightness

        var minH: CGFloat = 0, maxH: CGFloat = 1
        var minS: CGFloat = 0, maxS: CGFloat = 1
        var minB: CGFloat = 0, maxB: CGFloat = 1

        let colorCube = self.createColorCube(hueRange: minH...maxH, saturationRange: minS...maxS, brightnessRange: minB...maxB)
        thresholdFilter.cubeData = colorCube.data
        thresholdFilter.cubeDimension = colorCube.dimension

        let filtered = try self.filter(image: image)
    }

    // MARK: Filtration

    private func filter(image: CVImageBuffer) throws -> CVImageBuffer {
        // create the output pixel buffer to render into
        var pixelBufferOut: CVPixelBuffer?
        let code = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pool, &pixelBufferOut)
        guard let output = pixelBufferOut else {
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

        // render to the output
        self.context.render(heightEroded, to: output)

        return output
    }

    // MARK: Color Cube Creation

      private func createColorCube(hueRange: ClosedRange<CGFloat>, saturationRange: ClosedRange<CGFloat>, brightnessRange: ClosedRange<CGFloat>) -> ColorCube {
          var cube = [Float]()

          let size = 64
          let dimension = Float(size)

          for z in 0 ..< size {
              let blue = CGFloat(z) / CGFloat(size-1)

              for y in 0 ..< size {
                  let green = CGFloat(y) / CGFloat(size-1)

                  for x in 0 ..< size {
                      let red = CGFloat(x) / CGFloat(size-1)

                      var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
                      let rgba = UIColor(red: red, green: green, blue: blue, alpha: 1)
                      rgba.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

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

          var data = Data()
          cube.withUnsafeBufferPointer({ buffer in
              data.append(buffer)
          })

          return (data: data, dimension: dimension)
      }
}
