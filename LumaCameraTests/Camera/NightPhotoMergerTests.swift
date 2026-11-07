import CoreImage
import ImageIO
import XCTest
@testable import LumaCamera

/// 使用确定性的暗部噪声和移动物体检查真正渲染后的像素，不把 CI 惰性建图耗时当作处理耗时。
final class NightPhotoMergerTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private let width = 320
    private let height = 240

    private func texturedFixture()->CIImage {
        var bytes = [UInt8](repeating:255,count:width*height*4)
        for y in 0..<height { for x in 0..<width {
            var state = UInt64(x/19+1) &* 6364136223846793005 ^ UInt64(y/17+1) &* 1442695040888963407
            state ^= state >> 23; state = state &* 2862933555777941757
            let value = UInt8(30+(state>>32)%190)
            for c in 0..<3 { bytes[(y*width+x)*4+c] = value }
        } }
        return CIImage(bitmapData:Data(bytes),bytesPerRow:width*4,size:CGSize(width:width,height:height),format:.RGBA8,colorSpace:space)
    }

    private func fixture(seed: UInt64, movingX: Int? = nil) -> CIImage {
        var state = seed
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1
                let noise = Int((state >> 32) % 25) - 12
                let base = y < 160 ? 48 : 230
                let offset = (y * width + x) * 4
                for channel in 0..<3 { bytes[offset + channel] = UInt8(base + noise) }
                if let movingX, (movingX..<(movingX + 32)).contains(x), (80..<120).contains(y) {
                    bytes[offset] = 220; bytes[offset + 1] = 20; bytes[offset + 2] = 20
                }
            }
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4,
                       size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: space)
    }

    private func pixels(_ image: CIImage) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &result, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: space)
        return result
    }

    private func deviation(_ bytes: [UInt8]) -> Double {
        var values = [Double]()
        for y in 20..<60 { for x in 30..<290 { values.append(Double(bytes[(y * width + x) * 4])) } }
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count))
    }

    func testStaticDarkNoiseDropsWithoutBlowingHighlights() throws {
        let frames = [fixture(seed: 1), fixture(seed: 2), fixture(seed: 3)]
        let output = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(frames, referenceIndex: 1, context: context)))
        let reference = pixels(frames[1])
        let before = deviation(reference), after = deviation(output)
        XCTAssertLessThan(after, before * 0.85)
        XCTAssertGreaterThan(output[(30 * width + 30) * 4], 48, "暗部应适度抬起")
        let clipped = stride(from: 160 * width * 4, to: output.count, by: 4).filter { output[$0] >= 254 }.count
        XCTAssertEqual(clipped, 0, "原有未过曝亮部不能被整体曝光推白")
        print("NIGHT-NOISE fixture=320x240 samples=10400 shadow-code-std-before=\(before) after=\(after)")
    }

    func testColoredDarkFramesRetainSaturationAfterFusion() throws {
        func colored(_ seed: UInt64) -> CIImage {
            var state = seed
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                for c in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1
                    let base = y < 160 ? [72, 38, 26][c] : [220, 150, 110][c]
                    bytes[(y*width+x)*4+c] = UInt8(clamping: base + Int((state>>32)%17)-8)
                }
            } }
            return CIImage(bitmapData: Data(bytes), bytesPerRow: width*4,
                           size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: space)
                .settingProperties([kCGImagePropertyExifDictionary as String: [
                    kCGImagePropertyExifISOSpeedRatings as String: [800],
                    kCGImagePropertyExifExposureTime as String: 1.0
                ]])
        }
        func saturation(_ bytes: [UInt8]) -> Double {
            var total = 0.0, count = 0.0
            for y in 20..<60 { for x in 30..<290 {
                let o = (y*width+x)*4
                let r = Double(bytes[o]), g = Double(bytes[o+1]), b = Double(bytes[o+2])
                let mx = max(r,g,b), mn = min(r,g,b)
                if mx > 0 { total += (mx-mn)/mx; count += 1 }
            } }
            return total / count
        }
        let input = saturation(pixels(colored(1)))
        let output = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(
            (1...3).map { colored(UInt64($0)) }, referenceIndex: 1, context: context, adaptiveTone: true)))
        let result = saturation(output)
        print("NIGHT-COLOR-PRESERVE inputSat=\(input) outputSat=\(result)")
        XCTAssertGreaterThan(result, input * 0.65, "暗部彩色内容不应被融合无条件去色")
    }

    func testSourceISOIsPreservedThroughRegistrationAndCropping() throws {
        let image = fixture(seed: 7).settingProperties([kCGImagePropertyExifDictionary as String:
            [kCGImagePropertyExifISOSpeedRatings as String: [3200], kCGImagePropertyExifExposureTime as String: 1.0]])
        let result = try NightPhotoMerger.merge([image, image, image], context: context, adaptiveTone: true)
        XCTAssertEqual(result.alignedFrameCount, 3)
        let exif = try XCTUnwrap(result.image.properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue, 3200)
        XCTAssertEqual((exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue, 1.0)
        XCTAssertFalse(pixels(result.image).isEmpty)
    }

    func testHighISOMetadataStrengthensShadowDenoiseWithoutDimmingOrErasingEdges() throws {
        func noisy(_ seed: UInt64, iso: Int) -> CIImage {
            var state = seed, bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let base = y < 160 ? 70 : 220
                for c in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1
                    bytes[(y*width+x)*4+c] = UInt8(clamping: base + Int((state >> 32) % 81) - 40)
                }
            } }
            return CIImage(bitmapData: Data(bytes), bytesPerRow: width*4, size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: space)
                .settingProperties([kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifISOSpeedRatings as String: [iso]]])
        }
        func stats(_ bytes: [UInt8]) -> (mean: Double, sigma: Double, edge: Double) {
            let values = (20..<60).flatMap { y in (30..<290).map { x in Double(bytes[(y*width+x)*4]) } }
            let mean = values.reduce(0,+) / Double(values.count)
            let variance = values.reduce(0) { $0 + pow($1-mean, 2) } / Double(values.count)
            return (mean, sqrt(variance), Double(bytes[(180*width+160)*4]) - Double(bytes[(130*width+160)*4]))
        }
        var times = [Double]()
        for count in [3,6,9] {
            let baseline = stats(pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames((1...count).map { noisy(UInt64($0), iso: 100) }, referenceIndex: 1, context: context, adaptiveTone: true))))
            let began = CACurrentMediaTime()
            let result = stats(pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames((1...count).map { noisy(UInt64($0), iso: 3200) }, referenceIndex: 1, context: context, adaptiveTone: true))))
            times.append(CACurrentMediaTime()-began)
            XCTAssertLessThan(result.sigma, baseline.sigma * 0.85)
            XCTAssertEqual(result.mean, baseline.mean, accuracy: baseline.mean * 0.08)
            XCTAssertGreaterThan(result.edge, baseline.edge * 0.8)
            print("NIGHT-ISO-DENOISE n=\(count) sigma=\(baseline.sigma)->\(result.sigma) mean=\(baseline.mean)->\(result.mean) edge=\(baseline.edge)->\(result.edge)")
        }
        print("NIGHT-ISO-RENDER samples=3 size=320x240 maxSeconds=\(times.max() ?? -1) notDisplayFPS=true")
    }

    func testAutomaticHighNoiseFusionRetainsBrightnessAndSuppressesIndependentColorGrain() throws {
        func noisy(_ seed: UInt64) -> CIImage {
            var state = seed
            var bytes = [UInt8](repeating:255,count:width*height*4)
            for y in 0..<height { for x in 0..<width {
                let base = y < 160 ? 38 : 220
                for c in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1
                    bytes[(y*width+x)*4+c] = UInt8(base + Int((state>>32)%61)-30)
                }
            } }
            return CIImage(bitmapData:Data(bytes),bytesPerRow:width*4,size:CGSize(width:width,height:height),format:.RGBA8,colorSpace:space)
        }
        func statistics(_ bytes:[UInt8])->(mean:Double,grain:Double,chroma:Double) {
            var luminances = [Double](), colors = [Double]()
            for y in 20..<60 { for x in 30..<290 {
                let o = (y*width+x)*4
                let r = Double(bytes[o]), g = Double(bytes[o+1]), b = Double(bytes[o+2])
                luminances.append((r+g+b)/3); colors.append((r-g)*(r-g)+(b-g)*(b-g))
            } }
            let mean = luminances.reduce(0,+)/Double(luminances.count)
            let sigma = sqrt(luminances.reduce(0) { $0+pow($1-mean,2) }/Double(luminances.count))
            return (mean,sigma/mean,sqrt(colors.reduce(0,+)/Double(colors.count))/mean)
        }
        let reference = statistics(pixels(noisy(2)))
        for count in [3,6,9] {
            let frames = (1...count).map { noisy(UInt64($0)) }
            let output = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(frames,referenceIndex:1,context:context,adaptiveTone:true)))
            let result = statistics(output)
            XCTAssertGreaterThan(result.mean,reference.mean,"不能靠压暗掩盖噪声")
            XCTAssertLessThan(result.grain,reference.grain*0.65)
            XCTAssertLessThan(result.chroma,reference.chroma*0.70)
            XCTAssertLessThan(output[(200*width+160)*4],254,"保留未过曝亮部")
            print("NIGHT-COLOR-NOISE n=\(count) pixels=10400 mean=\(reference.mean)->\(result.mean) normalizedLumaGrain=\(reference.grain)->\(result.grain) normalizedChroma=\(reference.chroma)->\(result.chroma)")
        }
    }

    func testAutomaticNoiseAwareMotionMaskStillRejectsMovingObjects() throws {
        let clean = fixture(seed:2)
        let frames = [fixture(seed:1,movingX:30),clean,fixture(seed:3,movingX:240)]
        let output = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(frames,referenceIndex:1,context:context,adaptiveTone:true)))
        let baseline = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames([clean,clean,clean],referenceIndex:1,context:context,adaptiveTone:true)))
        for x in [45,255] {
            let o = (100*width+x)*4
            XCTAssertLessThan(abs(Int(output[o])-Int(baseline[o])),12)
            XCTAssertLessThan(abs(Int(output[o])-Int(output[o+1])),8)
        }
        let beforeEdge = (155*width+160)*4, afterEdge = (165*width+160)*4
        XCTAssertGreaterThan(Int(output[afterEdge])-Int(output[beforeEdge]),100,"不能用整体模糊抹掉结构边缘")
    }

    func testDeepDarkCoarseColorNoiseBrightensWithoutErasingStructure() throws {
        func noisy(_ seed:UInt64)->CIImage {
            var bytes=[UInt8](repeating:255,count:width*height*4),state=seed
            for y in 0..<height { for x in 0..<width { for c in 0..<3 {
                state=state &* 6364136223846793005 &+ 1
                let block=(UInt64(x/8+1) &* 1442695040888963407) ^ (UInt64(y/8+1) &* 2862933555777941757) ^ (seed &* 6364136223846793005) ^ (UInt64(c+1) &* 3202034522624059733)
                let base=y<160 ? 28:195
                let value=base+Int((state>>32)%25)-12+Int((block>>32)%23)-11
                bytes[(y*width+x)*4+c]=UInt8(clamping:value)
            } } }
            return CIImage(bitmapData:Data(bytes),bytesPerRow:width*4,size:CGSize(width:width,height:height),format:.RGBA8,colorSpace:space)
        }
        func stats(_ bytes:[UInt8])->(mean:Double,grain:Double,chroma:Double) {
            var values=[Double](),color=0.0
            for y in 20..<60 { for x in 30..<290 {
                let i=(y*width+x)*4,r=Double(bytes[i]),g=Double(bytes[i+1]),b=Double(bytes[i+2])
                values.append((r+g+b)/3);color+=(r-g)*(r-g)+(b-g)*(b-g)
            } }
            let mean=values.reduce(0,+)/Double(values.count)
            return (mean,sqrt(values.reduce(0){$0+pow($1-mean,2)}/Double(values.count))/mean,sqrt(color/Double(values.count))/mean)
        }
        let baseline=stats(pixels(noisy(2)))
        for count in [3,6,9] {
            let start=CACurrentMediaTime()
            let output=pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames((1...count).map{noisy(UInt64($0))},referenceIndex:1,context:context,adaptiveTone:true)))
            let result=stats(output)
            XCTAssertGreaterThan(result.mean,60)
            XCTAssertLessThan(result.grain,baseline.grain*0.65)
            XCTAssertLessThan(result.chroma,baseline.chroma*0.55)
            XCTAssertGreaterThan(Int(output[(170*width+160)*4])-Int(output[(150*width+160)*4]),70)
            XCTAssertLessThan(output[(200*width+160)*4],254)
            print("NIGHT-DEEP-NOISE n=\(count) samples=10400 mean=\(baseline.mean)->\(result.mean) grain=\(baseline.grain)->\(result.grain) chroma=\(baseline.chroma)->\(result.chroma) renderedSeconds=\(CACurrentMediaTime()-start)")
        }
    }

    func testHandheldRotationAndTranslationUsePerspectiveAlignment() throws {
        let reference = texturedFixture()
        var times = [Double]()
        var compensatedCases = 0
        for angle in [-3.0,2.5,1.5] {
            let transform = CGAffineTransform(translationX:-160,y:-120).rotated(by:angle * .pi/180)
                .concatenating(CGAffineTransform(translationX:168,y:115))
            // 相机帧始终保留完整传感器画布；不能用CI交集裁切意外改变输入尺寸/原点。
            let canvas = CIImage(color:.black).cropped(to:reference.extent)
            let shaken = reference.transformed(by:transform).composited(over:canvas).cropped(to:reference.extent)
            let t = CACurrentMediaTime()
            let result = try NightPhotoMerger.merge([shaken,reference,reference],context:context,maximumRegistrationDimension:320,adaptiveTone:true)
            _ = pixels(result.image)
            times.append(CACurrentMediaTime()-t)
            XCTAssertGreaterThanOrEqual(result.alignedFrameCount,2,"个别难匹配帧不得导致整张放弃多帧")
            if result.perspectiveAlignedFrameCount+result.rotationAlignedFrameCount>0 { compensatedCases += 1 }
            XCTAssertLessThan(result.croppedFraction,0.28)
        }
        XCTAssertGreaterThanOrEqual(compensatedCases,2,"多数小角度样本应实际恢复旋转帧，不只依赖两张相同参考")
        print("NIGHT-HANDHELD rotations=-3,2.5,1.5 translation=8,-5 n=3 renderedSeconds=\(times)")
    }

    func testTranslationCompensatesInTheCorrectDirectionRatherThanDoublingHandShake() throws {
        let reference = texturedFixture()
        let canvas = CIImage(color:.black).cropped(to:reference.extent)
        let shifted = reference.transformed(by:CGAffineTransform(translationX:9,y:-6)).composited(over:canvas).cropped(to:reference.extent)
        let transform = try XCTUnwrap(NightPhotoMerger.translationForTesting(shifted,reference:reference,context:context))
        XCTAssertEqual(transform.tx,-9,accuracy:0.5); XCTAssertEqual(transform.ty,6,accuracy:0.5)
        let result = try NightPhotoMerger.merge([shifted,reference,reference],context:context,maximumRegistrationDimension:320)
        XCTAssertEqual(result.alignedFrameCount,3)
        let crop = try XCTUnwrap(result.referenceCrop)
        let clean = reference.cropped(to:crop).transformed(by:CGAffineTransform(translationX:-crop.minX,y:-crop.minY))
        let expected = try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames([clean,clean,clean],referenceIndex:1,context:context))
        let a = pixels(result.image),b = pixels(expected)
        let valid = stride(from:0,to:a.count,by:4).filter { a[$0+3]>250 && b[$0+3]>250 }
        let error = valid.reduce(0.0) { $0+abs(Double(a[$1])-Double(b[$1])) }/Double(valid.count)
        XCTAssertLessThan(error,4,"8位量化与亚像素插值的平均差限制为4/255")
        print("NIGHT-TRANSLATION shift=9,-6 meanCodeError=\(error) accepted=\(result.alignedFrameCount)")
    }

    func testCompositeMetadataSurvivesActualJPEGHEIFTIFFAndSingleFrameFallback() throws {
        let sources = [0.0625,0.125,0.25].map { time in
            fixture(seed:2).settingProperties([kCGImagePropertyExifDictionary as String:[
                kCGImagePropertyExifExposureTime as String:time,
                kCGImagePropertyExifFNumber as String:1.78,
                kCGImagePropertyExifFocalLength as String:6.765,
                kCGImagePropertyExifISOSpeedRatings as String:[800],
                kCGImagePropertyExifLensModel as String:"iPhone 17 Pro back camera 6.765mm f/1.78"
            ]])
        }
        let merged = try NightPhotoMerger.merge(sources,context:context,maximumRegistrationDimension:320)
        XCTAssertEqual(merged.alignedFrameCount,3)
        for format in [PhotoFileFormat.jpeg,.heif,.tiff] {
            let encoded = try PhotoEncoder.encode(source:merged.image,raw:nil,look:CaptureLook(),options:PhotoOptions(format:format),context:context)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(encoded.resources.first?.data) as CFData,nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
            let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String:Any])
            XCTAssertEqual((exif[kCGImagePropertyExifCompositeImage as String] as? NSNumber)?.intValue,2)
            XCTAssertEqual((exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue,1.78)
            XCTAssertEqual((exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue,6.765)
            XCTAssertEqual((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue,800)
            XCTAssertEqual(exif[kCGImagePropertyExifLensModel as String] as? String,"iPhone 17 Pro back camera 6.765mm f/1.78")
            if format != .tiff { // 当前ImageIO TIFF写入器不保留此SHORT[2]，曝光数组及CompositeImage仍核对。
                XCTAssertEqual((exif[kCGImagePropertyExifSourceImageNumberOfCompositeImage as String] as? [NSNumber])?.map(\.intValue),[3,3])
            }
            let values = try XCTUnwrap(exif[kCGImagePropertyExifSourceExposureTimesOfCompositeImage as String] as? [NSNumber])
            XCTAssertEqual(values.count,12); XCTAssertEqual(values[1].doubleValue,0.4375,accuracy:0.00001)
            XCTAssertEqual(values.suffix(3).map(\.doubleValue),[0.0625,0.125,0.25])
        }
        let fallback = try NightPhotoMerger.merge([sources[1]],context:context)
        let exif = fallback.image.properties[kCGImagePropertyExifDictionary as String] as? [String:Any]
        XCTAssertNil(exif?[kCGImagePropertyExifCompositeImage as String])
        let partial = NightCompositeMetadata.applying(to:sources[1],sources:sources,usedIndices:[1,2],referenceIndex:1)
        let partialExif = try XCTUnwrap(partial.properties[kCGImagePropertyExifDictionary as String] as? [String:Any])
        XCTAssertEqual((partialExif[kCGImagePropertyExifSourceImageNumberOfCompositeImage as String] as? [Int]),[3,2])
    }

    func testNightPreviewAssistBrightensOnlyDisplayAndPreservesCaptureLookOutput() throws {
        let dark = CIImage(color:CIColor(red:0.015,green:0.015,blue:0.015)).cropped(to:CGRect(x:0,y:0,width:width,height:height))
        let ev = NightPreviewRenderer.exposureEV(mean:0.015)
        XCTAssertGreaterThan(ev,0); XCTAssertLessThanOrEqual(ev,1.5)
        XCTAssertGreaterThan(Imaging.meanLuminance(NightPreviewRenderer.apply(dark,ev:ev),context:context),Imaging.meanLuminance(dark,context:context)*2)
        var look = CaptureLook(); look.nightPreviewAssist = true
        XCTAssertEqual(pixels(Imaging.filtered(dark,look:look)),pixels(Imaging.filtered(dark,look:CaptureLook())))
        XCTAssertEqual(NightPreviewRenderer.exposureEV(mean:0.5),0)
    }

    func testAutomaticToneImprovesDarkMidtonesWithoutClippingHighlights() throws {
        let frames = [fixture(seed: 1), fixture(seed: 2), fixture(seed: 3)]
        let standard = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(frames, referenceIndex: 1, context: context)))
        let automatic = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(frames, referenceIndex: 1, context: context, adaptiveTone: true)))
        let shadow = (30 * width + 30) * 4
        XCTAssertGreaterThan(Int(automatic[shadow]), Int(standard[shadow]) + 6)
        let highlights = stride(from: 160 * width * 4, to: automatic.count, by: 4)
        XCTAssertEqual(highlights.filter { automatic[$0] >= 254 }.count, 0)
        print("NIGHT-AUTO-TONE shadow-before=\(standard[shadow]) after=\(automatic[shadow]) unclipped-bright-region=true")
    }

    func testAutomaticToneUsesHighlightHeadroomForVeryDarkScene() throws {
        let dark = CIImage(color: CIColor(red: 0.055, green: 0.05, blue: 0.045)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let frames = [dark, dark, dark]
        let standard = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(frames, referenceIndex: 1, context: context)))
        let automatic = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(frames, referenceIndex: 1, context: context, adaptiveTone: true)))
        let center = (height / 2 * width + width / 2) * 4
        XCTAssertGreaterThan(Int(automatic[center]), Int(standard[center]) + 12,
                             "整幅偏暗且无高光风险时应使用可用曝光余量，而不只做固定阴影抬升")
        XCTAssertLessThan(automatic[center], 230)
    }

    func testDeepDarkRoomBrightensWithoutClippingSmallLampOrRaisingBlack() throws {
        var bytes=[UInt8](repeating:255,count:width*height*4)
        for y in 0..<height { for x in 0..<width {
            let value:UInt8 = (280..<315).contains(x) && (200..<235).contains(y) ? 230 : ((10..<25).contains(x) && (10..<25).contains(y) ? 0:20)
            for c in 0..<3 { bytes[(y*width+x)*4+c]=value }
        } }
        let source=CIImage(bitmapData:Data(bytes),bytesPerRow:width*4,size:CGSize(width:width,height:height),format:.RGBA8,colorSpace:space)
        let output=pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames([source,source,source],referenceIndex:1,context:context,adaptiveTone:true)))
        let dark=output[(80*width+80)*4],lamp=output[(215*width+295)*4],black=output[(17*width+17)*4]
        XCTAssertGreaterThan(dark,65,"深暗场景需要可辨中间调，不能只通过加少量亮度的检查")
        XCTAssertLessThan(lamp,250,"小面积灯光仍保留余量")
        XCTAssertLessThanOrEqual(black,2,"黑位不能被整体抬灰")
        print("NIGHT-DARK-ROOM inputCode=20 outputCode=\(dark) lamp230=\(lamp) black0=\(black)")
    }

    func testNearBlackChannelOffsetsDoNotBecomePurplePatchesAfterBrightening() throws {
        var bytes=[UInt8](repeating:255,count:width*height*4)
        for y in 0..<height { for x in 0..<width {
            let color:[UInt8] = y<160 ? [9,3,11]:[110,50,30]
            for c in 0..<3 { bytes[(y*width+x)*4+c]=color[c] }
        } }
        let source=CIImage(bitmapData:Data(bytes),bytesPerRow:width*4,size:CGSize(width:width,height:height),format:.RGBA8,colorSpace:space)
        let output=pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames([source,source,source],referenceIndex:1,context:context,adaptiveTone:true)))
        let dark=(80*width+160)*4,warm=(200*width+160)*4
        let values=(0..<3).map{Int(output[dark+$0])}
        XCTAssertLessThan(values.max()!-values.min()!,8,"极低信号偏色不能在提亮后形成紫斑")
        XCTAssertGreaterThan(values.min()!,10)
        XCTAssertGreaterThan(Int(output[warm])-Int(output[warm+1]),15,"有效暖色不能被整体去色")
        print("NIGHT-LOW-SIGNAL-COLOR input=9,3,11 output=\(values) warm=\(Array(output[warm..<warm+3]))")
    }

    func testExposureNormalizationPreservesReferenceBrightness() throws {
        let clean = fixture(seed: 15)
        let bracket = [-1.0, 0.0, 1.0].map { clean.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: $0]) }
        let output = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(bracket, referenceIndex: 1, context: context)))
        let expected = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames([clean, clean, clean], referenceIndex: 1, context: context)))
        for y in [30, 180] {
            let offset = (y * width + 120) * 4
            XCTAssertLessThan(abs(Int(output[offset]) - Int(expected[offset])), 12, "不同曝光先归一，不能融合后整体变暗")
        }
    }

    func testMovingObjectUsesReferenceRatherThanGhostCopies() throws {
        let clean = fixture(seed: 2)
        let frames = [fixture(seed: 1, movingX: 30), clean, fixture(seed: 3, movingX: 240)]
        let output = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(frames, referenceIndex: 1, context: context)))
        let baseline = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames([clean, clean, clean], referenceIndex: 1, context: context)))
        for x in [45, 255] {
            let offset = (100 * width + x) * 4
            XCTAssertLessThan(abs(Int(output[offset]) - Int(baseline[offset])), 10)
            XCTAssertLessThan(abs(Int(output[offset]) - Int(output[offset + 1])), 8, "移动的红色主体不能残留在参考帧不存在的位置")
        }
    }

    func testPartialMergeAndSingleFrameFallbackKeepReferenceProperties() throws {
        let frame = fixture(seed: 5)
        let partial = try NightPhotoMerger.merge([frame, frame, .empty()], context: context, maximumRegistrationDimension: 320)
        XCTAssertEqual(partial.alignedFrameCount, 2)
        XCTAssertEqual(partial.image.extent.size, frame.extent.size)
        let single = try NightPhotoMerger.merge([.empty(), frame, .empty()], context: context, maximumRegistrationDimension: 320)
        XCTAssertEqual(single.alignedFrameCount, 1)
        XCTAssertEqual(pixels(single.image), pixels(frame), "单帧回退不伪装成融合，也不额外提亮")
        XCTAssertNil(NightPhotoMerger.fuseAlignedFrames([frame], referenceIndex: 0, context: context))
    }

    func testMergedImageEncodesEveryPhotoRatioAndOrientation() throws {
        let frame = fixture(seed: 23)
        let merged = try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames([frame, frame, frame], referenceIndex: 1, context: context))
        for ratio in FrameRatio.photoOptions {
            for landscape in [false, true] {
                let photo = try PhotoEncoder.encode(source: merged, raw: nil, look: CaptureLook(ratio: ratio, landscape: landscape),
                                                    options: PhotoOptions(format: .jpeg), context: context)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(photo.resources.first).data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let target = landscape ? ratio.landscapeRatio : ratio.portraitRatio
                XCTAssertEqual(Double(image.width) / Double(image.height), Double(target), accuracy: 0.02)
                XCTAssertGreaterThan(image.width, 0); XCTAssertGreaterThan(image.height, 0)
            }
        }
    }

    func testMotionAssessmentUsesAlignmentAndRejectsUnknownScene() throws {
        var reference = fixture(seed: 10)
        for index in 0..<24 {
            let rect = CGRect(x: (index * 47) % 280, y: (index * 71) % 200, width: 30, height: 30)
            let tile = CIImage(color: CIColor(red: 0.65, green: 0.45, blue: 0.3)).cropped(to: rect)
            reference = tile.composited(over: reference)
        }
        let same = NightPhotoMerger.assessMotion([reference, reference, reference], reference: reference, context: context)
        XCTAssertEqual(same.motion, .stable)
        let shifted = reference.clampedToExtent().transformed(by: CGAffineTransform(translationX: 32, y: 0))
            .cropped(to: reference.extent)
        let moved = NightPhotoMerger.assessMotion([reference, shifted], reference: reference, context: context)
        XCTAssertNotEqual(moved.motion, .stable, "大幅手持位移不能追加长序列")
        let black = CIImage(color: .black).cropped(to: reference.extent)
        XCTAssertEqual(NightPhotoMerger.assessMotion([black, black], reference: black, context: context).motion, .unknown)
        let oneAxis = fixture(seed: 10)
        XCTAssertEqual(NightPhotoMerger.assessMotion([oneAxis, oneAxis], reference: oneAxis, context: context).motion, .unknown,
                       "单方向边缘与细小噪声不能成为暗景放宽判断的依据")
    }

    func testCompensatedOrdinaryHandheldShiftDoesNotStopDenoising() {
        let reference=texturedFixture(),extent=reference.extent
        let shifted=reference.clampedToExtent().transformed(by:CGAffineTransform(translationX:9,y:-6)).cropped(to:extent)
        let assessed=NightPhotoMerger.assessMotion([reference,shifted],reference:reference,context:context)
        XCTAssertEqual(assessed.motion,.stable,"整体位移配准后应继续降噪，不应当作主体运动")
        XCTAssertGreaterThan(assessed.maximumShift,0.015)
        XCTAssertLessThan(assessed.changedFraction,0.10)
        print("NIGHT-HANDHELD-ASSESS shift=9,-6 maximumFraction=\(assessed.maximumShift) changedFraction=\(assessed.changedFraction) motion=\(assessed.motion)")
    }

    /// 优化前在同一真机保存的确定性像素网格，校验 3/6/9 帧的输出配方没有改变。
    func testSpeedOptimizationMatchesOriginalPixelReference() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "NightSpeedPixelReference", withExtension: "json"))
        let reference = try JSONDecoder().decode([String: [UInt8]].self, from: Data(contentsOf: url))
        for count in [3, 6, 9] {
            let frames = (0..<count).map { index in fixture(seed: UInt64(index + 1), movingX: index == 0 ? 30 : nil) }
            let output = pixels(try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(frames, referenceIndex: 1, context: context)))
            let expected = try XCTUnwrap(reference[String(count)])
            var grid = [UInt8]()
            for y in stride(from: 8, to: height, by: 16) {
                for x in stride(from: 8, to: width, by: 16) {
                    let offset = (y * width + x) * 4
                    grid.append(contentsOf: output[offset..<(offset + 4)])
                }
            }
            XCTAssertEqual(grid.count, expected.count)
            let differences = zip(grid, expected).map { abs(Int($0) - Int($1)) }
            XCTAssertLessThanOrEqual(differences.max() ?? 256, 2, "GPU 量化容差最多 2/255")
            print("NIGHT-PIXEL-PARITY frames=\(count) samples=\(grid.count) maxCodeDifference=\(differences.max() ?? -1)")
        }
    }

    func testTransparentProbeSafelyRejectsFusion() {
        let clear = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        XCTAssertNil(NightPhotoMerger.fuseAlignedFrames([clear, clear], referenceIndex: 1, context: context))
    }

    func testAutomaticToneRepeatedRenderPerformance() throws {
        var durations = [Double]()
        for iteration in 0..<12 {
            let frames = [fixture(seed: UInt64(iteration + 1)), fixture(seed: 99), fixture(seed: UInt64(iteration + 50))]
            let started = CACurrentMediaTime()
            let output = try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(frames, referenceIndex: 1, context: context, adaptiveTone: true))
            XCTAssertEqual(pixels(output).count, width * height * 4)
            durations.append(CACurrentMediaTime() - started)
        }
        let sorted = durations.sorted()
        print("NIGHT-AUTO-RENDER fixture=320x240 n=12 median=\(sorted[6]) p95=\(sorted[11]) seconds includes-fusion-render-and-64px-tone-probe=true not-preview-fps=true")
    }

    func testRepeatedRenderPerformanceAndBackToBackInputs() throws {
        var durations = [Double]()
        for iteration in 0..<12 {
            let frames = [fixture(seed: UInt64(iteration + 1)), fixture(seed: 99), fixture(seed: UInt64(iteration + 50))]
            let start = CACurrentMediaTime()
            let output = try XCTUnwrap(NightPhotoMerger.fuseAlignedFrames(frames, referenceIndex: 1, context: context))
            let rendered = pixels(output)
            XCTAssertEqual(rendered.count, width * height * 4)
            durations.append(CACurrentMediaTime() - start)
        }
        let sorted = durations.sorted()
        print("NIGHT-RENDER fixture=320x240 n=12 median-seconds=\(sorted[6]) p95=\(sorted[11]); includes CPU masks and CI render; not preview FPS/full-resolution latency")
    }
}
