import XCTest
import CoreImage
import ImageIO
import UIKit
@testable import LumaCamera

final class VirtualApertureTests: XCTestCase {
    func testEightRayAngularBalance() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let extent = CGRect(x: 0, y: 0, width: 256, height: 256)
        let point = CIImage(color: .white).cropped(to: CGRect(x: 126, y: 126, width: 4, height: 4))
            .composited(over: CIImage(color: .black).cropped(to: extent))
        for f in [5.6, 16.0] {
            let output = VirtualApertureRenderer.apply(point, fNumber: f)
            var pixels = [Float](repeating: 0, count: 256*256*4)
            let start = CACurrentMediaTime()
            pixels.withUnsafeMutableBytes { context.render(output, toBitmap: $0.baseAddress!, rowBytes: 256*16, bounds: extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!) }
            var energies = [Double](repeating: 0, count: 8)
            for y in 0..<256 { for x in 0..<256 {
                let dx = Double(x) + 0.5 - 128, dy = Double(y) + 0.5 - 128
                let r = hypot(dx, dy)
                guard r > 5 && r < 15 else { continue }
                let angle = atan2(dy, dx)
                let sector = (Int((angle / (.pi / 4)).rounded()) + 8) % 8
                energies[sector] += Double(pixels[(y*256+x)*4])
            } }
            XCTAssertGreaterThan(energies.min() ?? 0, 0.05)
            print("VIRTUAL-EIGHT f=\(f) energy=\(energies) ratio=\((energies.max() ?? 0) / max(energies.min() ?? 0,0.00001)) wall=\(CACurrentMediaTime()-start)")
            if let cg = context.createCGImage(output, from: extent) { let a = XCTAttachment(image: UIImage(cgImage: cg)); a.name = "Eight-\(f)"; a.lifetime = .keepAlways; add(a) }
        }
    }
    func testPointIsolationRejectsPanelsAndLongEdges() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        let extent = CGRect(x: 0, y: 0, width: 256, height: 256)
        let black = CIImage(color: .black).cropped(to: extent)
        let shapes: [(String, CIImage, Bool)] = [
            ("点光源", CIImage(color: .white).cropped(to: CGRect(x: 125, y: 125, width: 6, height: 6)), true),
            ("灯板", CIImage(color: .white).cropped(to: CGRect(x: 70, y: 80, width: 110, height: 80)), false),
            ("发光圆面", CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: 128, y: 128), "inputRadius0": 30, "inputRadius1": 31, "inputColor0": CIColor.white, "inputColor1": CIColor.clear])!.outputImage!.cropped(to: extent), false),
            ("横长亮边", CIImage(color: .white).cropped(to: CGRect(x: 40, y: 127, width: 176, height: 2)), false),
            ("竖长亮边", CIImage(color: .white).cropped(to: CGRect(x: 127, y: 40, width: 2, height: 176)), false),
            ("斜长亮边", CIImage(color: .white).cropped(to: CGRect(x: -88, y: -1, width: 176, height: 2)).transformed(by: CGAffineTransform(rotationAngle: .pi / 5)).transformed(by: CGAffineTransform(translationX: 128, y: 128)), false)
        ]
        for (name, shape, accepted) in shapes {
            let input = shape.composited(over: black).cropped(to: extent)
            let began = CACurrentMediaTime()
            let output = VirtualApertureRenderer.apply(input, fNumber: 16)
            var baseline = [Float](repeating: 0, count: 256*256*4), result = baseline
            baseline.withUnsafeMutableBytes { context.render(input, toBitmap: $0.baseAddress!, rowBytes: 256*16, bounds: extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!) }
            result.withUnsafeMutableBytes { context.render(output, toBitmap: $0.baseAddress!, rowBytes: 256*16, bounds: extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!) }
            var added = 0.0
            for i in stride(from: 0, to: result.count, by: 4) { added += max(0, Double(result[i] - baseline[i])) }
            if accepted { XCTAssertGreaterThan(added, 50, name) } else { XCTAssertLessThan(added, 1, name) }
            print("VIRTUAL-POINT name=\(name) added=\(added) wall=\(CACurrentMediaTime()-began)")
            if let cg = context.createCGImage(output, from: extent) { let a = XCTAttachment(image: UIImage(cgImage: cg)); a.name = name; a.lifetime = .keepAlways; add(a) }
        }
    }
    func testContinuousRangeHighlightRaysAndUniformAreas() throws {
        XCTAssertTrue(VirtualApertureRenderer.available)
        for n in 0...100 {
            let position = Double(n) / 100
            XCTAssertEqual(VirtualApertureRenderer.position(for: VirtualApertureRenderer.value(at: position)), position, accuracy: 0.000001)
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let extent = CGRect(x: 0, y: 0, width: 256, height: 256)
        let background = CIImage(color: .black).cropped(to: extent)
        let point = CIImage(color: CIColor(red: 1.5, green: 1.2, blue: 0.8)).cropped(to: CGRect(x: 125, y: 125, width: 6, height: 6))
        let input = point.composited(over: background)
        var energies: [Double] = [], timings: [Double] = []
        for f in [1.4, 4.0, 8.0, 16.0] {
            let began = CACurrentMediaTime()
            let output = VirtualApertureRenderer.apply(input, fNumber: f)
            var pixels = [Float](repeating: 0, count: 256 * 256 * 4)
            pixels.withUnsafeMutableBytes { context.render(output, toBitmap: $0.baseAddress!, rowBytes: 256 * 16, bounds: extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!) }
            timings.append(CACurrentMediaTime() - began)
            var energy = 0.0
            for y in 0..<256 { for x in 0..<256 where abs(x-128) > 5 || abs(y-128) > 5 { energy += Double(pixels[(y*256+x)*4]) } }
            energies.append(energy)
            if let cg = context.createCGImage(output, from: extent) {
                let attachment = XCTAttachment(image: UIImage(cgImage: cg)); attachment.name = "Star-aperture-\(f)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        XCTAssertEqual(energies[0], 0, accuracy: 0.001)
        XCTAssertGreaterThan(energies[1], 0.1); XCTAssertGreaterThan(energies[2], energies[1]); XCTAssertGreaterThan(energies[3], energies[2]); XCTAssertGreaterThan(energies[3], 100); XCTAssertLessThan(energies[3], 400, "满档应缩小到上一版ƒ/6范围")
        let uniform = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { context.render(VirtualApertureRenderer.apply(uniform, fNumber: 16), toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 128, y: 128, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!) }
        XCTAssertEqual(pixel[0], 1, accuracy: 0.002)
        let largeExtent = CGRect(x: 0, y: 0, width: 4000, height: 3000)
        let tiny = CIImage(color: .white).cropped(to: CGRect(x: 1998, y: 1498, width: 4, height: 4))
            .composited(over: CIImage(color: .black).cropped(to: largeExtent))
        let largeStart = CACurrentMediaTime()
        let tinyOutput = VirtualApertureRenderer.apply(tiny, fNumber: 16).transformed(by: CGAffineTransform(scaleX: 0.1, y: 0.1))
        var tinyPixels = [Float](repeating: 0, count: 400 * 300 * 4)
        tinyPixels.withUnsafeMutableBytes { context.render(tinyOutput, toBitmap: $0.baseAddress!, rowBytes: 400 * 16, bounds: CGRect(x: 0, y: 0, width: 400, height: 300), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!) }
        var tinyEnergy = 0.0
        for y in 0..<300 { for x in 0..<400 where abs(x-200) > 2 || abs(y-150) > 2 { tinyEnergy += Double(tinyPixels[(y*400+x)*4]) } }
        XCTAssertGreaterThan(tinyEnergy, 0.01)
        print("VIRTUAL-APERTURE-TINY energy=\(tinyEnergy) seconds=\(CACurrentMediaTime()-largeStart)")
        let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 1.78, kCGImagePropertyExifUserComment: "LumaCamera.VirtualAperture=8.0000"]]
        var p = PhotoCaptureParameters(); p.updateEXIF(properties)
        XCTAssertEqual(p.aperture, 1.78); XCTAssertEqual(p.virtualAperture, 8)
        XCTAssertTrue(p.rows.contains { $0.title == "虚拟光圈" && $0.value == "ƒ/8.0" })
        XCTAssertNil(CaptureLook(virtualAperture: 16).forOutput(.raw).virtualAperture)
        print("VIRTUAL-APERTURE-SEEDS energy=\(energies) renderSeconds=\(timings)")
    }
}
