import CoreImage

enum FilmStyle: String, CaseIterable, Identifiable {
    case original, daylight, amber, cinema, leicaM9, fujiNC, fujiCC, mono, food, daylightNegative400
    // 兼容刚测试过的 film400 存档；显示名已重定位为“暖调负片 200”。
    case warmNegative200 = "film400"
    case lut8e01931695, lut2822fe566f, lut0f0bbcb69e, lut3d9aec28a2, lut32a8226ccc, lut5f95b51579, lut3675b050d8, lutabf0a1a1fc, lut74f0c757a6, lut65f12b4421, lutff68264412, lut68decd78c9, lut65079c544d, lut366e84500d, lut7e90ddc039, lut1775a81171, lut1e53d98a81, lut2141527536, lut49ad230de7, lut6e13efd4c3, lute3e60113bd, lut4680f1508c, lut8eac246ff8, lut3831567476, lut6be6214def, lutfcee0c278b, lut7e0ef8bdc8, lut4d6b1a3c06, lut00ce8780b3, lut5de92d3636, lut2873feea08, lut384a1211b6, lut54ce806fbb, lut64f854a875, lut80c7455c11, lutc18fc9c98c, lute3d53fa666, lut9e49d5257b, lut78143f1938, lut836114786e, lutf83466e34f
    static let availableStyles: [FilmStyle] = [.original, .daylightNegative400, .warmNegative200] + ImportedFilterCatalog.entries.map(\.style)
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "原片"
        case .daylight: return "晴日"
        case .amber: return "暖忆"
        case .cinema: return "青幕"
        case .leicaM9: return "徕卡 M9"
        case .fujiNC: return "富士 NC"
        case .fujiCC: return "富士 CC"
        case .mono: return "银盐"
        case .food: return "美食"
        case .daylightNegative400: return "日光负片 400"
        case .warmNegative200: return "暖调负片 200"
        default: return ImportedFilterCatalog.definition(for: self)?.title ?? rawValue
        }
    }
    var filterButtonEquipment: String? {
        ImportedFilterCatalog.definition(for: self)?.equipment
    }
    var filterButtonName: String {
        ImportedFilterCatalog.definition(for: self)?.buttonName ?? title
    }
    var subtitle: String {
        switch self {
        case .original: return "TRUE COLOR"
        case .daylight: return "SOFT DAYLIGHT"
        case .amber: return "WARM MEMORIES"
        case .cinema: return "CINEMATIC TEAL"
        case .leicaM9: return "M9 · REFERENCE LUT"
        case .fujiNC: return "CLASSIC NEG."
        case .fujiCC: return "CLASSIC CHROME"
        case .mono: return "SILVER & SHADOW"
        case .food: return "FOOD LUT"
        case .daylightNegative400: return "DAYLIGHT NEGATIVE"
        case .warmNegative200: return "WARM NEGATIVE 200"
        default: return "REFERENCE LUT"
        }
    }

    var filterCategory: FilterCategory {
        switch self {
        case .daylightNegative400, .warmNegative200,
             .fujiNC, .fujiCC,
             .lut65f12b4421, .lut68decd78c9, .lut65079c544d, .lut366e84500d,
             .lut7e90ddc039, .lut1775a81171, .lutabf0a1a1fc, .lut4d6b1a3c06:
            return .film
        case .cinema, .lut8e01931695, .lut2822fe566f, .lut49ad230de7, .lut6e13efd4c3,
             .lute3e60113bd, .lut4680f1508c, .lut8eac246ff8, .lutff68264412,
             .lut5de92d3636, .lut2873feea08:
            return .cinema
        case .mono, .lut74f0c757a6, .lutfcee0c278b, .lut80c7455c11:
            return .mono
        case .lut0f0bbcb69e, .lut2141527536, .lut54ce806fbb, .lut836114786e, .lutf83466e34f:
            return .portrait
        case .lut384a1211b6, .lut9e49d5257b, .lute3d53fa666, .lut1e53d98a81, .lut64f854a875:
            return .landscape
        default:
            return .life
        }
    }

    /// 默认强度按使用场景和 LUT 强度分级；仍可由用户逐支覆盖。
    var defaultIntensity: Double {
        switch self {
        case .original: return 0.8
        case .leicaM9: return 0.72
        case .fujiNC, .fujiCC: return 0.75
        case .lut8e01931695, .lut2822fe566f: return 0.62
        case .lut49ad230de7, .lut6e13efd4c3: return 0.66
        case .lute3e60113bd, .lut4680f1508c, .lut8eac246ff8: return 0.70
        case .lut5de92d3636, .lut2873feea08: return 0.68
        case .daylightNegative400, .warmNegative200: return 0.80
        default:
            switch filterCategory {
            case .cinema: return 0.68
            case .film: return 0.80
            case .portrait: return 0.76
            case .landscape: return 0.75
            case .mono: return 0.80
            default: return 0.78
            }
        }
    }

    private static let strengthKernel = MetalImageKernels.color("filterStrength")

    static func effectStrength(for intensity: Double) -> Double {
        let value = intensity.isFinite ? min(max(intensity, 0), 1) : 0
        // 0...80% 线性到参考LUT（80%=1.0）；80...100% 继续线性到1.3倍。
        let progress = max(0, (value - 0.8) / 0.2)
        return value <= 0.8 ? value / 0.8 : 1 + 0.3 * progress
    }

    func apply(to input: CIImage, intensity: Double) -> CIImage {
        let strength = Self.effectStrength(for: intensity)
        guard self != .original else { return input }
        // 0% 也要走同一滤镜输出路径；直接返回 HLG 原图会让最后一帧绕过
        // 滤镜的颜色空间处理，表现为闪一下后变成另一种 SDR 观感。
        if strength <= 0 {
            if let neutral = Self.strengthKernel?.apply(extent: input.extent, arguments: [input, input, 0]) {
                return neutral.cropped(to: input.extent)
            }
            return input
        }
        let filtered = referenceImage(to: input)
        if abs(strength - 1) < 0.000001 { return filtered }
        if strength > 1 {
            // 80...100%: extrapolate the LUT difference up to 1.3x. The kernel
            // clamps negative channels, so a zero LUT channel cannot turn the
            // whole preview black as the old 1.5x linear path did.
            if let kernel = Self.strengthKernel {
                // 超浓度外推只处理滤镜拥有的色彩。银盐只有黑白亮度，
                // 因此先把输入转为单色，再做 1.3 倍外推；不能拿彩色 RGB 差值外推。
                let extrapolationInput = self == .mono
                    ? input.applyingFilter("CIPhotoEffectNoir")
                    : input
                if let extrapolated = kernel.apply(extent: input.extent,
                    arguments: [extrapolationInput, filtered, strength]) {
                    return extrapolated.cropped(to: input.extent)
                }
            }
        }
        guard strength < 1 else { return filtered }
        // A constant linear-light mask gives an actual strength blend, without transition endpoint snapping.
        guard let color = CIColor(red: CGFloat(strength), green: CGFloat(strength), blue: CGFloat(strength), alpha: 1,
                            colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!) else { return input }
        let mask = CIImage(color: color).cropped(to: input.extent)
        return filtered.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: input, kCIInputMaskImageKey: mask]).cropped(to: input.extent)
    }
    /// Keep HDR highlights >1, but never let a LUT's negative channels reach
    /// the display/preview where they clamp to pure black.
    private func clampNonNegative(_ image: CIImage) -> CIImage {
        guard let kernel = Self.strengthKernel else { return image }
        return kernel.apply(extent: image.extent, arguments: [image, image, 1])?.cropped(to: image.extent) ?? image
    }

    /// Original 100% transform, used unchanged by the new default 80% level.
    func referenceImage(to input: CIImage) -> CIImage {
        let output: CIImage
        if let reference = ImportedFilterCatalog.definition(for: self) {
            output = ImportedFilterCatalog.apply(reference, to: input)
        } else { switch self {
        case .original: output = input
        case .daylight:
            output = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.82, kCIInputContrastKey: 0.94, kCIInputBrightnessKey: 0.035])
                .applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6000, y: 0)])
        case .amber:
            output = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85, kCIInputContrastKey: 1.05])
                .applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 4800, y: 8)])
        case .cinema:
            output = input.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.9, y: 0.03, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1.02, z: 0.03, w: 0), "inputBVector": CIVector(x: 0.02, y: 0.03, z: 1.08, w: 0)])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.75, kCIInputContrastKey: 1.08])
        case .leicaM9, .fujiNC, .fujiCC:
            output = CameraFilmProfiles.apply(self, to: input)
        case .mono:
            output = input.applyingFilter("CIPhotoEffectNoir")
        case .daylightNegative400:
            // 高光柔和、中调偏暖、暗部通透：肩部压缩，抬黑并保留轻微冷色，
            // 中间调用暖色矩阵和色温，不使用整体褪色把画面压灰。
            output = input
                .applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0.032),
                    "inputPoint1": CIVector(x: 0.22, y: 0.235),
                    "inputPoint2": CIVector(x: 0.5, y: 0.535),
                    "inputPoint3": CIVector(x: 0.78, y: 0.80),
                    "inputPoint4": CIVector(x: 1, y: 0.915)])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.025, y: 0.012, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0.004, y: 1.008, z: 0.008, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0.008, z: 1.018, w: 0),
                    "inputBiasVector": CIVector(x: 0.006, y: 0.008, z: 0.012, w: 0)])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.80, kCIInputContrastKey: 1.0, kCIInputBrightnessKey: 0.006])
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 5800, y: 1)])
        case .warmNegative200:
            // 暖调负片200：更强的琥珀高光、轻微绿阴影和更明显对比。
            output = input
                .applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0.025),
                    "inputPoint1": CIVector(x: 0.25, y: 0.23),
                    "inputPoint2": CIVector(x: 0.5, y: 0.52),
                    "inputPoint3": CIVector(x: 0.75, y: 0.77),
                    "inputPoint4": CIVector(x: 1, y: 0.94)])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.06, y: 0.022, z: 0.0, w: 0),
                    "inputGVector": CIVector(x: 0.006, y: 1.005, z: 0.01, w: 0),
                    "inputBVector": CIVector(x: 0.0, y: 0.012, z: 0.965, w: 0),
                    "inputBiasVector": CIVector(x: 0.016, y: 0.008, z: 0.004, w: 0)])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.78, kCIInputContrastKey: 1.035, kCIInputBrightnessKey: 0.008])
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 5200, y: 2)])
        default: output = input
        } }
        return ReferenceFilterCalibration.apply(self, to: output).cropped(to: input.extent)
    }

}

