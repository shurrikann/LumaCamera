import CoreImage
import CoreVideo
import XCTest
@testable import LumaCamera

final class VideoFrameFilterRendererTests: XCTestCase {
    func testStillPhotoFilterIsRenderedIntoEncoderPixelBufferInSDRAndP3() throws {
        let width = 64, height = 64
        let colorSpaces = [CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpace(name: CGColorSpace.displayP3)!]
        let sourceContext = CIContext(options: [.cacheIntermediates: false])
        let renderer = VideoFrameFilterRenderer()
        for colorSpace in colorSpaces {
            let source = try makeBuffer(width: width, height: height)
            let destination = try makeBuffer(width: width, height: height)
            let extent = CGRect(x: 0, y: 0, width: width, height: height)
            let sourceColor = try XCTUnwrap(CIColor(red: 0.86, green: 0.16, blue: 0.08, alpha: 1, colorSpace: colorSpace))
            let sourceImage = CIImage(color: sourceColor).cropped(to: extent)
            sourceContext.render(sourceImage, to: source, bounds: extent, colorSpace: colorSpace)
            let look = CaptureLook(style: .mono, intensity: 1, ratio: .standard)
            renderer.render(source: source, destination: destination, look: look, colorSpace: colorSpace, grainPhase: 1024)
            let pixel = try centerRGB(destination, x: width / 2, y: height / 2)
            XCTAssertLessThan(abs(pixel.0 - pixel.1), 8, "Monochrome must be baked into SDR/P3 video pixels")
            XCTAssertLessThan(abs(pixel.1 - pixel.2), 8, "Monochrome must be baked into SDR/P3 video pixels")
            XCTAssertGreaterThan(pixel.0, 20, "The processed pixel buffer must not remain blank")
        }
    }

    func testFoodCubeLookIsBakedIntoSDRAndP3VideoFrames() throws {
        let width = 64, height = 64
        let colorSpaces = [CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpace(name: CGColorSpace.displayP3)!]
        let sourceContext = CIContext(options: [.cacheIntermediates: false])
        let renderer = VideoFrameFilterRenderer()
        for colorSpace in colorSpaces {
            let source = try makeBuffer(width: width, height: height)
            let destination = try makeBuffer(width: width, height: height)
            let extent = CGRect(x: 0, y: 0, width: width, height: height)
            let color = try XCTUnwrap(CIColor(red: 0.82, green: 0.34, blue: 0.12, alpha: 1, colorSpace: colorSpace))
            sourceContext.render(CIImage(color: color).cropped(to: extent), to: source, bounds: extent, colorSpace: colorSpace)
            let sourcePixel = try centerRGB(source, x: width / 2, y: height / 2)
            let look = CaptureLook(style: .food, intensity: 1, ratio: .standard)

            renderer.render(source: source, destination: destination, look: look, colorSpace: colorSpace, grainPhase: 0)

            let outputPixel = try centerRGB(destination, x: width / 2, y: height / 2)
            let difference = abs(outputPixel.0 - sourcePixel.0) + abs(outputPixel.1 - sourcePixel.1) + abs(outputPixel.2 - sourcePixel.2)
            XCTAssertGreaterThan(difference, 4, "The 美食 CUBE must be baked into SDR and P3 video pixels")
            XCTAssertGreaterThan(outputPixel.0 + outputPixel.1 + outputPixel.2, 0)
        }
    }

    func testFoodCubeRendersThirty640pFramesForPerformanceSample() throws {
        let width = 640, height = 360
        let source = try makeBuffer(width: width, height: height)
        let destination = try makeBuffer(width: width, height: height)
        let renderer = VideoFrameFilterRenderer()
        let look = CaptureLook(style: .food, intensity: 0.8, ratio: .standard)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<30 {
                renderer.render(source: source, destination: destination, look: look,
                                colorSpace: colorSpace, grainPhase: 0)
            }
        }
    }

    func testLogLUTRenderKeepsTenBitEncoderPixelFormat() throws {
        let width = 64, height = 64
        let tenBitFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let source = try makeBuffer(width: width, height: height, pixelFormat: tenBitFormat)
        let destination = try makeBuffer(width: width, height: height, pixelFormat: tenBitFormat)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let sourceImage = CIImage(color: CIColor(red: 0.72, green: 0.31, blue: 0.12, alpha: 1))
            .cropped(to: extent)
        CIContext(options: [.cacheIntermediates: false]).render(sourceImage, to: source, bounds: extent, colorSpace: colorSpace)
        let preset = try XCTUnwrap(LogLUTCubeRepository.presets().first)
        let cube = try LogLUTCubeRepository.load(preset)

        VideoFrameFilterRenderer().renderLogLUT(source: source, destination: destination, cube: cube)

        XCTAssertEqual(CVPixelBufferGetPixelFormatType(source), tenBitFormat)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(destination), tenBitFormat,
                       "The filtered encoder buffer must stay 10-bit 4:2:0 for Log recording")
        XCTAssertGreaterThan(try lumaCode(destination, x: width / 2, y: height / 2), 0,
                             "The Log LUT render must write image pixels into the encoder buffer")
    }

    func testLogLUTRenderPerformanceAt640x360ForThirtyFrames() throws {
        let width = 640, height = 360
        let source = try makeBuffer(width: width, height: height)
        let destination = try makeBuffer(width: width, height: height)
        let preset = try XCTUnwrap(LogLUTCubeRepository.presets().first)
        let cube = try LogLUTCubeRepository.load(preset)
        let renderer = VideoFrameFilterRenderer()

        measure {
            for _ in 0..<30 {
                renderer.renderLogLUT(source: source, destination: destination, cube: cube)
            }
        }
    }

    private func centerRGB(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> (Int, Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(base[offset + 2]), Int(base[offset + 1]), Int(base[offset]))
    }

    private func lumaCode(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> UInt16 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
        let rowStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / MemoryLayout<UInt16>.size
        return base[y * rowStride + x] >> 6
    }

    private func makeBuffer(width: Int, height: Int,
                            pixelFormat: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                                            attributes as CFDictionary, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}
