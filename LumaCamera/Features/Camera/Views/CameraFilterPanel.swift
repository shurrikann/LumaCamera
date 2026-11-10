import SwiftUI

extension CameraView {
    var filmPanel: some View {
        VStack(spacing: 10) {
            if model.logVideoLUTControlsEnabled {
                logLUTPanel
            } else if filters.showStrength { filterAdjustmentPanel }
            else {
                filterCategories
                filterCarousel
                filterActions
            }
        }
        .padding(.top, 10).padding(.bottom, 4)
        .background {
            PopupGlassBackground(
                shape: UnevenRoundedRectangle(
                    cornerRadii: .init(topLeading: 28, bottomLeading: 0, bottomTrailing: 0, topTrailing: 28),
                    style: .continuous
                ),
                materialOpacity: AppTheme.cameraPopupMaterialOpacity
            ).ignoresSafeArea(edges: .bottom)
        }
        .onAppear { if !model.logVideoLUTControlsEnabled { filters.prepareThumbnails() } }
        .allowsHitTesting(!model.camera.videoBusy)
    }

    private var logLUTPanel: some View {
        VStack(spacing: 10) {
            logLUTCategories
            if model.logLUTPresets.isEmpty {
                Text("未找到 Log LUT").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).frame(height: 79)
            } else if model.logLUTCategory == .favorites && model.logLUTOptions.isEmpty {
                Text("还没有收藏 Log 滤镜").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).frame(height: 79)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 10) {
                            ForEach(model.logLUTOptions) { preset in
                                logLUTCard(preset)
                            }
                        }.padding(.horizontal, 14).padding(.vertical, 2)
                    }.frame(height: 79)
                    .onAppear { proxy.scrollTo(logLUTScrollTarget, anchor: .center) }
                    .onChange(of: model.selectedLogLUTID) { _, id in
                        guard let id, model.logLUTOptions.contains(where: { $0.id == id }) else { return }
                        withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: model.logLUTCategory) { _, _ in
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(logLUTScrollTarget, anchor: .center)
                        }
                    }
                }
            }
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedLogLUTPreset?.title ?? "选择 Log LUT")
                        .rotatingCaptureContent().font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9)).lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.72)
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.logLUTTitleFrameForTesting = $0 }
                        #endif
                    if let equipment = model.selectedLogLUTPreset?.equipment {
                        Text(equipment).font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.52)).lineLimit(1).truncationMode(.middle)
                    }
                    Text(model.selectedLogLUTID == LogLUTPreset.originalID ? "未套用 LUT" : (model.burnLogLUT ? "已写入 Log 成片" : "仅影响预览画面"))
                        .font(.system(size: 8)).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.logLUTInfoFrameForTesting = $0 }
                #endif
                .frame(height: 44, alignment: .leading)
                if let preset = model.selectedLogLUTPreset, preset.id != LogLUTPreset.originalID {
                    Button {
                                                model.toggleLogLUTFavorite(preset.id)
                    } label: {
                        filterActionIcon(model.logLUTFavorites.contains(preset.id) ? "star.fill" : "star",
                                         highlighted: model.logLUTFavorites.contains(preset.id))
                    }
                    .buttonStyle(.plain).disabled(camera.videoBusy)
                    .accessibilityLabel(model.logLUTFavorites.contains(preset.id) ? "取消收藏 Log 滤镜" : "收藏 Log 滤镜")
                }
                Spacer(minLength: 0)
                Button {
                                        model.burnLogLUT.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.burnLogLUT ? "flame.fill" : "flame")
                            .font(.system(size: 14, weight: .medium))
                        Text("烧录").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(model.burnLogLUT ? AppTheme.accent : .white.opacity(0.86))
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(model.burnLogLUT ? AppTheme.accent.opacity(0.14) : .white.opacity(0.08),
                                in: Capsule())
                    .overlay(Capsule().stroke(model.burnLogLUT ? AppTheme.accent.opacity(0.48) : .white.opacity(0.12), lineWidth: 0.7))
                }
                .buttonStyle(.plain).disabled(camera.videoBusy || model.selectedLogLUTID == LogLUTPreset.originalID)
                .accessibilityLabel(model.burnLogLUT ? "关闭 Log LUT 烧录" : "开启 Log LUT 烧录")
                .accessibilityValue(model.burnLogLUT ? "已开启，录制时 LUT 写入成片并保留 Log 色彩标记" : "已关闭，仅在预览中显示 LUT")
            }.padding(.horizontal, 10)
        }
    }

    private func logLUTCard(_ preset: LogLUTPreset) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { model.selectLogLUT(preset.id) }
        } label: {
            VStack(spacing: 1) {
                logLUTThumbnail(for: preset)
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
                        .rotatingCaptureContent()
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(model.selectedLogLUTID == preset.id ? AppTheme.accent : Color.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.72)
                    if let equipment = preset.equipment {
                        Text(equipment)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.52))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .minimumScaleFactor(0.7)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(width: 64, height: 20, alignment: .top)
            }
            .frame(width: 64)
        }
        .id(preset.id)
        .buttonStyle(.plain)
        .disabled(camera.videoBusy)
        .onAppear { model.prepareLogLUTThumbnail(for: preset) }
        .accessibilityLabel([preset.equipment, preset.title, "Log LUT"].compactMap { $0 }.joined(separator: " "))
        .accessibilityAddTraits(model.selectedLogLUTID == preset.id ? .isSelected : [])
    }

    @ViewBuilder
    private func logLUTThumbnail(for preset: LogLUTPreset) -> some View {
        if preset.id == LogLUTPreset.originalID, let image = UIImage(named: "FilterLandscape") {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let image = model.logLUTThumbnails[preset.id] {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Circle().fill(Color.white.opacity(0.08))
                if model.logLUTThumbnailLoading.contains(preset.id) {
                    ProgressView().controlSize(.mini).tint(Color.white.opacity(0.75))
                }
            }
        }
    }

    private var logLUTCategories: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(LogLUTCategory.allCases) { category in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { model.selectLogLUTCategory(category) }
                    } label: {
                        Group {
                            if category == .all { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13)) }
                            else if category == .favorites { Image(systemName: "star.fill").font(.system(size: 13)) }
                            else { Text(category.rawValue).rotatingCaptureContent().font(.system(size: 11, weight: .medium)) }
                        }
                        .foregroundStyle(model.logLUTCategory == category ? AppTheme.accentForeground : .white.opacity(0.9))
                        .frame(minWidth: category == .all || category == .favorites ? 38 : 44)
                        .frame(height: 28)
                        .padding(.horizontal, category == .all || category == .favorites ? 0 : 4)
                        .background(model.logLUTCategory == category ? AppTheme.accent : .white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.rawValue + " Log 滤镜")
                    .accessibilityAddTraits(model.logLUTCategory == category ? .isSelected : [])
                }
            }.padding(.horizontal, 14)
        }
    }

    private var logLUTScrollTarget: String? {
        if let selected = model.selectedLogLUTID, model.logLUTOptions.contains(where: { $0.id == selected }) {
            return selected
        }
        return model.logLUTOptions.first?.id
    }

    private var filterCategories: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(FilterCategory.allCases) { category in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { model.selectFilterCategory(category) }
                        } label: {
                            Group {
                                if category == .all { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13)) }
                                else if category == .favorites { Image(systemName: "star.fill").rotatingCaptureContent().font(.system(size: 13)) }
                                else { Text(category.rawValue).rotatingCaptureContent().font(.system(size: 11, weight: .medium)) }
                            }
                            .foregroundStyle(filters.category == category ? AppTheme.accentForeground : .white.opacity(0.9))
                            .frame(minWidth: category == .all || category == .favorites ? 38 : 44).frame(height: 28)
                            .padding(.horizontal, category == .all || category == .favorites ? 0 : 4)
                            .background(filters.category == category ? AppTheme.accent : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }.id(category.id).accessibilityLabel(category.rawValue + "滤镜")
                            .accessibilityAddTraits(filters.category == category ? .isSelected : [])
                    }
                }.padding(.horizontal, 14)
            }
            .onChange(of: filters.category) { _, category in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(category.id, anchor: .center) }
            }
        }
    }

    private var filterCarousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(filters.styles) { film in
                        Button { withAnimation(.easeInOut(duration: 0.18)) { model.style = film } } label: {
                            VStack(spacing: 8) {
                                ZStack {
                                    if let image = filters.thumbnails[film] ?? (film == .original ? UIImage(named: "FilterLandscape") : nil) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else { Circle().fill(.white.opacity(0.08)) }
                                }
                                .frame(width: 48, height: 48).clipShape(Circle())
                                .padding(3)
                                .overlay(Circle().stroke(model.style == film ? AppTheme.accent : .white.opacity(0.12), lineWidth: model.style == film ? 2 : 0.5))
                                .overlay(alignment: .topTrailing) {
                                    if filters.favorites.contains(film) {
                                        Image(systemName: "star.fill").rotatingCaptureContent().font(.system(size: 9)).foregroundStyle(AppTheme.accent)
                                            .padding(3).background(Color.black.opacity(0.65), in: Circle())
                                    }
                                }
                                Text(film.title).rotatingCaptureContent().font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(model.style == film ? AppTheme.accent : .white.opacity(0.85))
                            }.frame(width: 60)
                        }
                        .id(film.id).buttonStyle(.plain).disabled(camera.videoBusy)
                        .accessibilityLabel(film.title + "滤镜")
                        .accessibilityAddTraits(model.style == film ? .isSelected : [])
                    }
                    if filters.styles.isEmpty {
                        Text("还没有收藏，点击下方星标收藏当前滤镜")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).frame(height: 79)
                    }
                }.padding(.horizontal, 14).padding(.vertical, 3)
            }.frame(height: 79)
            .onAppear { proxy.scrollTo(model.style.id, anchor: .center) }
            .task {
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(model.style.id, anchor: .center)
            }
            .onChange(of: model.style) { _, style in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(style.id, anchor: .center) }
            }
            .onChange(of: filters.category) { _, _ in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(model.style.id, anchor: .center) }
            }
        }
    }

    private var filterActions: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { model.toggleFilterFavorite() } label: {
                filterActionIcon(filters.favorites.contains(model.style) ? "star.fill" : "star",
                                 highlighted: filters.favorites.contains(model.style))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(filters.favorites.contains(model.style) ? "取消收藏当前滤镜" : "收藏当前滤镜")
            VStack(alignment: .leading, spacing: 3) {
                Text(model.style.title).rotatingCaptureContent().font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(model.style.subtitle).font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(height: 44, alignment: .center)
            Spacer(minLength: 0)
            Button { withAnimation(AppTheme.popupAnimation) { filters.showStrength.toggle() } } label: {
                filterActionIcon("slider.horizontal.3", highlighted: filters.showStrength)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("调整滤镜参数")
            .accessibilityValue(model.style == .original ? "原片，无基础滤镜浓度" : "\(Int(model.intensity * 100))%")
        }.padding(.horizontal, 10)
    }

    private func filterActionIcon(_ symbol: String, highlighted: Bool) -> some View {
        Image(systemName: symbol).rotatingCaptureContent()
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(highlighted ? AppTheme.accent : .white.opacity(0.85))
            .frame(width: 36, height: 36)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
