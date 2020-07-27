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
    private let erosionFilter: CIConvolution
    private let dilationFilter: CIConvolution
    private let thresholdFilter: CIColorCubeWithColorSpace

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
        let erosionFilter = CIFilter.convolution3X3()
        let dilationFilter = CIFilter.convolution3X3()
        let thresholdFilter = CIFilter.colorCubeWithColorSpace()

        // configure the filters
        let weights = CIVector(string: "[1 1 1 1 1 1 1 1 1]")
        dilationFilter.weights = weights
        erosionFilter.weights = weights
        erosionFilter.bias = -Float(weights.count - 1)
        thresholdFilter.colorSpace = context.workingColorSpace

        // initialize stored properties
        self.pool = pool
        self.context = context
        self.roiRect = roiRect
        self.inputSize = inputSize
        self.transform = transform
        self.erosionFilter = erosionFilter
        self.dilationFilter = dilationFilter
        self.thresholdFilter = thresholdFilter
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


        // begin binary search of optimal filter parameters

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
        // crop
        let cropped = CIImage(cvImageBuffer: image).cropped(to: self.roiRect)

        // transform
        let transformed = cropped.transformed(by: self.transform)

        // threshold
        self.thresholdFilter.inputImage = transformed
        guard let thresholded = self.thresholdFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }

        // clamp
        let clamped = thresholded.clampedToExtent()

        // dilate
        self.dilationFilter.inputImage = clamped
        guard let dilated = self.dilationFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }

        // erode thrice
        self.erosionFilter.inputImage = dilated
        guard let eroded = self.erosionFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }
        self.erosionFilter.inputImage = eroded
        guard let erodedx2 = self.erosionFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }
        self.erosionFilter.inputImage = erodedx2
        guard let erodedx3 = self.erosionFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }

        // dilate twice
        self.dilationFilter.inputImage = erodedx3
        guard let dilatedx2 = self.dilationFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }
        self.dilationFilter.inputImage = dilatedx2
        guard let filtered = self.dilationFilter.outputImage else {
            throw WandDetectorError.couldNotUseFilter
        }

        // create the output pixel buffer
        var pixelBufferOut: CVPixelBuffer?
        let code = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pool, &pixelBufferOut)
        guard let output = pixelBufferOut else {
            throw WandDetectorError.couldNotCreatePixelBuffer(code: code)
        }

        // render to the output
        self.context.render(filtered, to: output)

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
                      cube.append(color) // alpha
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
