import SwiftUI
import UIKit

/// Log 视频编辑的底部 LUT 弹窗，沿用相机视频模式 Log 面板的分类、
/// 缩略图卡和收藏结构；编辑结果始终写入所选 LUT，没有相机端的烧录开关。
struct VideoLogFilterPopup: View {
    @ObservedObject var model: VideoEditorViewModel
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cornerRadius: CGFloat {
        let bottom = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.safeAreaInsets.bottom ?? 0
        return bottom > 0 ? 55 : 0
    }

    var body: some View {
        VStack(spacing: 10) {
            categoryHeader
            carousel
            actionRow
        }
        .padding(.top, 20)
        .padding(.bottom, 14)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .background {
            PopupGlassBackground(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                materialOpacity: AppTheme.cameraPopupMaterialOpacity
            )
        }
        .onAppear {
            for preset in model.logLUTOptions.prefix(12) {
                model.prepareLogLUTThumbnail(for: preset)
            }
        }
        .accessibilityIdentifier("video.logFilter.popup")
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            model.captureButtonFramesForTesting["video.logFilter.popup"] = $0
        }
        #endif
    }

    private var categoryHeader: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(LogLUTCategory.allCases) { category in
                        Button {
                            withAnimation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18)) {
                                model.selectLogLUTCategory(category)
                            }
                        } label: {
                            Group {
                                if category == .all {
                                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13))
                                } else if category == .favorites {
                                    Image(systemName: "star.fill").font(.system(size: 13))
                                } else {
                                    Text(category.rawValue).font(.system(size: 11, weight: .medium))
                                }
                            }
                            .foregroundStyle(model.logLUTCategory == category ? AppTheme.accentForeground : .white.opacity(0.9))
                            .frame(minWidth: category == .all || category == .favorites ? 38 : 44)
                            .frame(height: 28)
                            .padding(.horizontal, category == .all || category == .favorites ? 0 : 4)
                            .background(model.logLUTCategory == category ? AppTheme.accent : .white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(category.rawValue + " Log LUT")
                        .accessibilityAddTraits(model.logLUTCategory == category ? .isSelected : [])
                    }
                }.padding(.horizontal, 26)
            }
        }
    }

    private var carousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    if model.logLUTOptions.isEmpty {
                        Text("还没有收藏 Log 滤镜")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).frame(height: 79)
                    } else {
                        ForEach(model.logLUTOptions) { preset in
                            Button { select(preset) } label: {
                                VStack(spacing: 1) {
                                    thumbnail(for: preset)
                                        .frame(width: 48, height: 48)
                                        .clipShape(Circle())
                                        .padding(3)
                                        .overlay(Circle().stroke(
                                            model.selectedLogLUTID == preset.id ? AppTheme.accent : Color.white.opacity(0.12),
                                            lineWidth: model.selectedLogLUTID == preset.id ? 2 : 0.5
                                        ))
                                        .overlay(alignment: .topTrailing) {
                                            if model.logLUTFavorites.contains(preset.id) {
                                                Image(systemName: "star.fill")
                                                    .font(.system(size: 8, weight: .semibold))
                                                    .foregroundStyle(AppTheme.accent)
                                                    .padding(3)
                                                    .background(Color.black.opacity(0.7), in: Circle())
                                            }
                                        }
                                    VStack(spacing: 0) {
                                        Text(preset.title)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(model.selectedLogLUTID == preset.id ? AppTheme.accent : Color.white.opacity(0.85))
                                            .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.72)
                                        if let equipment = preset.equipment {
                                            Text(equipment)
                                                .font(.system(size: 8, weight: .medium))
                                                .foregroundStyle(Color.white.opacity(0.52))
                                                .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.7)
                                        }
                                    }
                                    .multilineTextAlignment(.center)
                                    .frame(width: 64, height: 20, alignment: .top)
                                }
                                .frame(width: 64)
                            }
                            .id(preset.id).buttonStyle(.plain)
                            .onAppear { model.prepareLogLUTThumbnail(for: preset) }
                            .accessibilityLabel([preset.equipment, preset.title, "Log LUT"].compactMap { $0 }.joined(separator: " "))
                            .accessibilityAddTraits(model.selectedLogLUTID == preset.id ? .isSelected : [])
                        }
                    }
                }.padding(.horizontal, 14).padding(.vertical, 2)
            }.frame(height: 79)
            .onAppear { proxy.scrollTo(model.selectedLogLUTID, anchor: .center) }
            .onChange(of: model.selectedLogLUTID) { _, id in
                withAnimation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: model.logLUTCategory) { _, _ in
                withAnimation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18)) {
                    proxy.scrollTo(model.selectedLogLUTID, anchor: .center)
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(alignment: .center, spacing: 10) {
            if model.selectedLogLUTID != LogLUTPreset.originalID {
                Button { withAnimation(.easeInOut(duration: 0.18)) { model.toggleLogLUTFavorite(model.selectedLogLUTID) } } label: {
                    filterActionIcon(model.logLUTFavorites.contains(model.selectedLogLUTID) ? "star.fill" : "star",
                                     highlighted: model.logLUTFavorites.contains(model.selectedLogLUTID))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.logLUTFavorites.contains(model.selectedLogLUTID) ? "取消收藏 Log 滤镜" : "收藏 Log 滤镜")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedLogLUTPreset?.title ?? "选择 Log LUT")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9)).lineLimit(1).truncationMode(.middle)
                    .minimumScaleFactor(0.72)
                if let equipment = model.selectedLogLUTPreset?.equipment {
                    Text(equipment).font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52)).lineLimit(1).truncationMode(.middle)
                }
                Text(model.selectedLogLUTID == LogLUTPreset.originalID ? "未套用 LUT" : "编辑输出套用所选 LUT")
                    .font(.system(size: 8)).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 44)
            Button { model.burnLogLUT.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.burnLogLUT ? "flame.fill" : "flame")
                        .font(.system(size: 14, weight: .medium))
                    Text("烧录").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(model.burnLogLUT ? AppTheme.accent : .white.opacity(0.86))
                .padding(.horizontal, 12).frame(height: 34)
                .background(model.burnLogLUT ? AppTheme.accent.opacity(0.14) : .white.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(model.burnLogLUT ? AppTheme.accent.opacity(0.48) : .white.opacity(0.12), lineWidth: 0.7))
            }
            .buttonStyle(.plain)
            .disabled(model.selectedLogLUTID == LogLUTPreset.originalID)
            .opacity(model.selectedLogLUTID == LogLUTPreset.originalID ? 0.4 : 1)
            .accessibilityLabel(model.burnLogLUT ? "关闭 Log LUT 烧录" : "开启 Log LUT 烧录")
            .accessibilityValue(model.burnLogLUT ? "已开启，导出时写入 LUT" : "已关闭，仅预览显示 LUT")
        }.padding(.horizontal, 24)
    }

    @ViewBuilder
    private func thumbnail(for preset: LogLUTPreset) -> some View {
        if preset.id == LogLUTPreset.originalID, let image = UIImage(named: "FilterLandscape") {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let image = model.logLUTThumbnails[preset.id] {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Circle().fill(model.selectedLogLUTID == preset.id ? AppTheme.accent : Color.white.opacity(0.08))
                if model.logLUTThumbnailLoading.contains(preset.id) {
                    ProgressView().controlSize(.mini).tint(.white.opacity(0.75))
                } else {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 17))
                        .foregroundStyle(model.selectedLogLUTID == preset.id ? AppTheme.accentForeground : .white.opacity(0.8))
                }
            }
        }
    }

    private func filterActionIcon(_ symbol: String, highlighted: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(highlighted ? AppTheme.accent : .white.opacity(0.85))
            .frame(width: 36, height: 36)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func select(_ preset: LogLUTPreset) {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18)) {
            model.selectLogLUT(preset.id)
        }
    }
}
