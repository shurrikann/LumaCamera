import SwiftUI
import UIKit

/// SDR/P3 视频编辑的底部滤镜弹窗，沿用相机视频模式的分类、缩略图、
/// 收藏和参数滑条布局；Log 视频仍使用原有的 Log LUT 面板。
struct VideoFilterPopup: View {
    @ObservedObject var model: VideoEditorViewModel
    @ObservedObject var filters: FilterPickerViewModel
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var browsing: Bool { !filters.showStrength }
    private var sideInset: CGFloat { 24 }
    private var cornerRadius: CGFloat {
        let bottom = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.safeAreaInsets.bottom ?? 0
        return bottom > 0 ? 55 : 0
    }

    var body: some View {
        VStack(spacing: 10) {
            if filters.showStrength { strengthPanel } else { browserPanel }
        }
        .padding(.top, browsing ? 20 : 10)
        .padding(.bottom, browsing ? 14 : 4)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .background {
            PopupGlassBackground(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                materialOpacity: AppTheme.cameraPopupMaterialOpacity
            )
        }
        .onAppear { filters.prepareThumbnails() }
        .accessibilityIdentifier("video.filter.popup")
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            model.captureButtonFramesForTesting["video.filter.popup"] = $0
        }
        #endif
    }

    private var browserPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(FilterCategory.allCases) { category in
                            Button { selectCategory(category) } label: {
                                Group {
                                    if category == .all {
                                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13))
                                    } else if category == .favorites {
                                        Image(systemName: "star.fill").font(.system(size: 13))
                                    } else {
                                        Text(category.rawValue).font(.system(size: 11, weight: .medium))
                                    }
                                }
                                .foregroundStyle(filters.category == category ? AppTheme.accentForeground : .white.opacity(0.9))
                                .frame(minWidth: category == .all || category == .favorites ? 38 : 44)
                                .frame(height: 28)
                                .padding(.horizontal, category == .all || category == .favorites ? 0 : 4)
                                .background(filters.category == category ? AppTheme.accent : .white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(category.rawValue + "滤镜")
                            .accessibilityAddTraits(filters.category == category ? .isSelected : [])
                        }
                    }.padding(.horizontal, sideInset + 2)
                }
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.10), in: Circle())
                        .contentShape(Circle())
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起视频滤镜列表")
                .padding(.trailing, 10)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(filters.styles) { film in
                            Button { select(film) } label: {
                                VStack(spacing: 8) {
                                    ZStack {
                                        if let image = filters.thumbnails[film] ?? (film == .original ? UIImage(named: "FilterLandscape") : nil) {
                                            Image(uiImage: image).resizable().scaledToFill()
                                        } else { Circle().fill(.white.opacity(0.08)) }
                                    }
                                    .frame(width: 48, height: 48).clipShape(Circle())
                                    .padding(3)
                                    .overlay(Circle().stroke(model.style == film ? AppTheme.accent : .white.opacity(0.12),
                                                             lineWidth: model.style == film ? 2 : 0.5))
                                    .overlay(alignment: .topTrailing) {
                                        if filters.favorites.contains(film) {
                                            Image(systemName: "star.fill").font(.system(size: 9))
                                                .foregroundStyle(AppTheme.accent)
                                                .padding(3).background(Color.black.opacity(0.65), in: Circle())
                                        }
                                    }
                                    Text(film.title).font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(model.style == film ? AppTheme.accent : .white.opacity(0.85))
                                }.frame(width: 60)
                            }
                            .id(film.id).buttonStyle(.plain)
                            .accessibilityLabel("视频滤镜" + film.title)
                            .accessibilityAddTraits(model.style == film ? .isSelected : [])
                        }
                        if filters.styles.isEmpty {
                            Text("还没有收藏，点击下方星标收藏当前滤镜")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).frame(height: 79)
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 3)
                }.frame(height: 79)
                .onAppear { proxy.scrollTo(model.style.id, anchor: .center) }
                .onChange(of: model.style) { _, style in
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18)) {
                        proxy.scrollTo(style.id, anchor: .center)
                    }
                }
                .onChange(of: filters.category) { _, _ in
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18)) {
                        proxy.scrollTo(model.style.id, anchor: .center)
                    }
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Button { toggleFavorite() } label: {
                    filterActionIcon(filters.favorites.contains(model.style) ? "star.fill" : "star",
                                     highlighted: filters.favorites.contains(model.style))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(filters.favorites.contains(model.style) ? "取消收藏当前滤镜" : "收藏当前滤镜")
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.style.title).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(model.style.subtitle).font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(height: 44, alignment: .center)
                Spacer(minLength: 0)
                Button { withAnimation(AppTheme.popupAnimation) { filters.showStrength = true } } label: {
                    filterActionIcon("slider.horizontal.3", highlighted: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("调整视频滤镜参数")
                .accessibilityValue(model.style == .original ? "原片，无基础滤镜浓度" : "\(Int(model.intensity * 100))%")
            }.padding(.horizontal, sideInset)
        }
    }

    private var strengthPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button { withAnimation(AppTheme.popupAnimation) { filters.showStrength = false } } label: {
                    Image(systemName: "chevron.left").frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回视频滤镜列表")
                Spacer(minLength: 0)
                Text(model.style.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button { model.resetCurrentLook() } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重置当前视频滤镜")
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.10), in: Circle())
                        .contentShape(Circle())
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起视频滤镜参数")
            }
            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))

            FilterAdjustmentTabs(model: model)
            FilterDialEditor(model: model, tab: model.filterEditorTab)
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .frame(height: 348)
        .accessibilityIdentifier("video.filter.dialPad")
        .onDisappear {
            model.setFilterParameterEditing(false)
            model.dismissFilterNumericInput()
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

    private func selectCategory(_ category: FilterCategory) {
        filters.category = category
        if !filters.styles.contains(model.style), let first = filters.styles.first {
            model.style = first
        }
    }

    private func select(_ film: FilmStyle) {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.1 : 0.18)) {
            model.style = film
        }
    }

    private func toggleFavorite() {
        filters.toggleFavorite(model.style)
        if filters.category == .favorites {
            selectCategory(.favorites)
        }
    }

    private func close() {
        filters.showStrength = false
        onClose()
    }
}
