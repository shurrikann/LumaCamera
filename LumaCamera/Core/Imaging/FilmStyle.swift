import CoreImage

enum FilmStyle: String, CaseIterable, Identifiable {
    case original, daylight, amber, cinema, leicaM9, fujiNC, fujiCC, mono, food
    case lut8e01931695, lut2822fe566f, lut0f0bbcb69e, lut3d9aec28a2, lut32a8226ccc, lut5f95b51579, lut3675b050d8, lutabf0a1a1fc, lut74f0c757a6, lut65f12b4421, lutff68264412, lut68decd78c9, lut65079c544d, lut366e84500d, lut7e90ddc039, lut1775a81171, lut1e53d98a81, lut2141527536, lut49ad230de7, lut6e13efd4c3, lute3e60113bd, lut4680f1508c, lut8eac246ff8, lut3831567476, lut6be6214def, lutfcee0c278b, lut7e0ef8bdc8, lut4d6b1a3c06, lut00ce8780b3, lut5de92d3636, lut2873feea08, lut384a1211b6, lut54ce806fbb, lut64f854a875, lut80c7455c11, lutc18fc9c98c, lute3d53fa666, lut9e49d5257b, lut78143f1938, lut836114786e, lutf83466e34f
    static let availableStyles: [FilmStyle] = [.original] + ImportedFilterCatalog.entries.map(\.style)
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
        default: return "REFERENCE LUT"
        }
    }
    private static let strengthKernel = MetalImageKernels.color("filterStrength")

    static func effectStrength(for intensity: Double) -> Double {
        let value = intensity.isFinite ? min(max(intensity, 0), 1) : 0
        // 0...80% is uniform. Above the reference level, do not linearly extrapolate
        // the LUT (that crosses zero and turns black into pure black). Keep a
        // normalized boost value for a safe contrast/saturation enhancement.
        let progress = max(0, (value - 0.8) / 0.2)
        return value <= 0.8 ? value / 0.8 : 1 + 0.5 * progress * progress
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
            // 80...100% must remain visible, but linear extrapolation past a LUT
            // channel of zero is what turned the preview black. Enhance the already
            // decoded reference instead, preserving black/white endpoints.
            let boost = strength - 1
            let saturation = self == .mono ? 0 : 1 + 0.60 * boost
            let contrast = 1 + 0.35 * boost
            let safe = clampNonNegative(filtered)
            let enhanced = safe.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: saturation,
                kCIInputContrastKey: contrast
            ]).cropped(to: input.extent)
            return clampNonNegative(enhanced)
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
        default: output = input
        } }
        return ReferenceFilterCalibration.apply(self, to: output).cropped(to: input.extent)
    }

}

