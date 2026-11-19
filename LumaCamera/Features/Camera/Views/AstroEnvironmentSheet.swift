import MapKit
import SwiftUI

enum AstroEnvironmentLayer: String, CaseIterable, Identifiable {
    case pollution = "光污染"
    case cloud = "云层"
    case combined = "叠加"
    var id: String { rawValue }
    var includesClouds: Bool { self != .pollution }
    var includesPollution: Bool { self != .cloud }
}

struct AstroForecastSelection {
    var siteID: UUID?
    var mapCenter: CLLocationCoordinate2D?

    mutating func updateCenter(_ coordinate: CLLocationCoordinate2D?, afterPan: Bool = false) {
        mapCenter = coordinate
        if afterPan { siteID = nil }
    }

    func point(sites: [AstroPlannedSite], location: PhotoLocation?) -> AstroForecastPoint? {
        let site = sites.first { $0.id == siteID }
        return (site?.coordinate ?? mapCenter ?? location?.coordinate).flatMap(AstroForecastPoint.init)
    }
}

struct AstroEnvironmentSheet: View {
    let recoveryCount: Int
    let onClose: () -> Void
    let onRecovery: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var locationService: CaptureLocationService?
    @State private var location: PhotoLocation?
    @State private var detent: PresentationDetent = .medium
    @State private var recenterToken = UUID()
    @State private var layer: AstroEnvironmentLayer = .pollution
    @State private var cloudRegion: AstroCloudRegion?
    private let cloudStore = AstroCloudForecastStore.shared
    @State private var cloudRetry = 0
    @State private var cloudZoomToken = UUID()
    @State private var forecastIndex = 0.0
    private let forecastStore = AstroForecastStore.shared
    @State private var forecastRetry = 0
    @State private var forecastSelection = AstroForecastSelection()
    @State private var plannedSites = AstroPlannedSite.restore()
    @State private var revealedSiteID: UUID?
    @State private var pollutionBands: [LightPollutionPoint: LightPollutionLegend.Band?] = [:]
    private let lightPollution: any LightPollutionSource = LightPollutionSources.current

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        AstroNightLightsMap(location: location, locationService: locationService, source: lightPollution,
                                                recenterToken: recenterToken, sites: plannedSites,
                                                layer: layer, cloudFrame: selectedCloudFrame, cloudZoomToken: cloudZoomToken,
                                                cloudFocus: selectedSite?.coordinate ?? location?.coordinate,
                                                onRegionChange: { cloudRegion = $0 },
                                                onCenterChange: { forecastSelection.updateCenter($0) },
                                                onPan: { forecastSelection.updateCenter($0, afterPan: true) },
                                                onSelectSite: { forecastSelection.siteID = $0 })
                            .frame(height: detent == .large ? 360 : 250)
                            .overlay(alignment: .topLeading) {
                                Text(layer.includesPollution
                                     ? "\(lightPollution.metadata.name) · \(lightPollution.metadata.year) · \(lightPollution.metadata.license)"
                                     : "总云量预报")
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                                    .foregroundStyle(.white.opacity(0.88))
                                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                                    .contentTransition(.opacity)
                                    .animation(reduceMotion ? .easeOut(duration: 0.08) : AppTheme.popupAnimation, value: layer)
                                    .padding(10)
                                    .allowsHitTesting(false)
                            }
                            .overlay(alignment: .topTrailing) {
                                if layer.includesClouds { cloudStatus.padding(10) }
                            }
                            .overlay(alignment: .bottomLeading) {
                                Button {
                                    guard location != nil else { return }
                                    forecastSelection.updateCenter(nil, afterPan: true)
                                    recenterToken = UUID()
                                } label: {
                                    Image(systemName: "location.fill")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(location == nil ? .white.opacity(0.45) : .white)
                                        .frame(width: 44, height: 44)
                                        .background(.black.opacity(0.70), in: Circle())
                                        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.7))
                                }
                                .buttonStyle(.plain)
                                .disabled(location == nil)
                                .padding(10)
                                .accessibilityLabel("回到当前位置")
                                .accessibilityIdentifier("astro.environment.recenter")
                            }
                            .overlay {
                                Image(systemName: "mappin")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundStyle(AppTheme.accent)
                                    .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
                                    .offset(y: -15)
                                    .allowsHitTesting(false)
                            }
                            .clipShape(.rect(cornerRadius: 16))

                        layerSelector
                        VStack(alignment: .leading, spacing: 8) {
                            if layer.includesPollution, let legend = lightPollution.legend {
                                pollutionLegend(legend).transition(.opacity)
                            }
                            if layer.includesClouds { cloudLegend.transition(.opacity) }
                        }
                        .animation(reduceMotion ? .easeOut(duration: 0.08) : AppTheme.popupAnimation, value: layer)
                        recommendedSection
                        timeCard
                        conditionsCard
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.bottom, geometry.safeAreaInsets.bottom + 8, for: .scrollContent)
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground { PopupGlassBackground(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)) }
        .environment(\.captureControlAngle, 0)
        .onAppear {
            let service = CaptureLocationService(tracksHeading: true)
            service.onLocationChange = { location = $0 }
            locationService = service
            service.setActive(scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in locationService?.setActive(phase == .active) }
        .onChange(of: forecastPoint) { _, _ in forecastIndex = 0 }
        .task(id: ForecastRequest(point: scenePhase == .active ? forecastPoint : nil, attempt: forecastRetry)) {
            guard scenePhase == .active, let forecastPoint else { return }
            await forecastStore.refreshWhileVisible(forecastPoint)
        }
        .task(id: CloudRequest(region: scenePhase == .active && layer.includesClouds ? cloudRegion : nil,
                               attempt: cloudRetry)) {
            guard scenePhase == .active, layer.includesClouds, let cloudRegion else { return }
            await cloudStore.refresh(cloudRegion)
        }
        .task(id: pollutionPoints) {
            let points = pollutionPoints
            let retained = pollutionBands.filter { points.contains($0.key) }
            let missing = points.subtracting(retained.keys)
            guard !missing.isEmpty || pollutionBands.count != retained.count else { return }
            let source = lightPollution
            let resolved = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: missing.map { ($0, source.band(at: $0)) })
            }.value
            guard !Task.isCancelled else { return }
            pollutionBands = retained.merging(resolved) { _, new in new }
        }
        .onDisappear {
            locationService?.setActive(false)
            locationService?.onLocationChange = nil
            locationService = nil
        }
    }

    private var layerSelector: some View {
        Picker("图层", selection: $layer) {
            ForEach(AstroEnvironmentLayer.allCases) { value in
                Text(value.rawValue).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .tint(AppTheme.accent)
        .accessibilityLabel("环境图层")
    }

    private struct CloudRequest: Equatable {
        let region: AstroCloudRegion?
        let attempt: Int
    }

    private var cloudGrid: AstroCloudGrid? { cloudStore.grid(for: cloudRegion) }
    private var selectedCloudFrame: AstroCloudFrame? { cloudGrid?.frame(at: selectedDate) }

    @ViewBuilder private var cloudStatus: some View {
        if let summary = selectedCloudFrame?.coverageSummary {
            Text("区域云量 " + percent(summary.mean) + (summary.isPartial ? " · 局部缺测" : ""))
                .font(.caption2).padding(6).background(.black.opacity(0.75), in: Capsule())
                .accessibilityIdentifier("astro.environment.cloud.coverage")
        } else if cloudRegion == nil {
            Button("放大查看云量") { cloudZoomToken = UUID() }
                .font(.caption2).buttonStyle(.bordered)
        } else if cloudStore.failedRegion == cloudRegion {
            if cloudStore.isUnconfigured {
                Text("暂无云量来源").font(.caption2).padding(6).background(.black.opacity(0.75), in: Capsule())
            } else {
                Button("重试云量") { cloudRetry += 1 }
                    .font(.caption2)
                    .buttonStyle(.bordered)
            }
        } else if cloudGrid == nil {
            ProgressView().controlSize(.small)
                .accessibilityLabel("正在加载云量预报")
        } else {
            Text("该时刻暂无云量").font(.caption2).padding(6).background(.black.opacity(0.75), in: Capsule())
        }
    }

    private func pollutionLegend(_ legend: LightPollutionLegend) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(legend.title)
            HStack(spacing: 0) {
                ForEach(legend.bands) { band in
                    Rectangle().fill(Color(red: Double(band.red) / 255,
                        green: Double(band.green) / 255, blue: Double(band.blue) / 255))
                }
            }
            .frame(height: 7)
            .clipShape(Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
            HStack {
                Text(legend.bands.first?.range ?? "")
                Spacer()
                Text(legend.bands.last?.range ?? "")
            }
            .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("光污染色阶，\(legend.title)")
        .accessibilityValue(legend.bands.map(\.range).joined(separator: "，"))
        .accessibilityIdentifier("astro.environment.pollution.legend")
    }

    private var cloudLegend: some View {
        HStack(spacing: 5) {
            Text("0%")
            Capsule().fill(LinearGradient(colors: [0.0, 20, 40, 60, 80, 100].map { coverage in
                Color(red: 0.75, green: 0.92, blue: 1).opacity(AstroCloudFrame.displayOpacity(for: coverage))
            }, startPoint: .leading, endPoint: .trailing))
                .frame(width: 52, height: 6)
            Text("100%")
            Spacer()
            Link("云量预报 · Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("astro.environment.cloud.legend")
    }

    private struct ForecastRequest: Equatable {
        let point: AstroForecastPoint?
        let attempt: Int
    }

    private var selectedSite: AstroPlannedSite? { plannedSites.first { $0.id == forecastSelection.siteID } }
    private var mapCenter: CLLocationCoordinate2D? { forecastSelection.mapCenter }
    private var activeCoordinate: CLLocationCoordinate2D? { selectedSite?.coordinate ?? mapCenter ?? location?.coordinate }
    private var pollutionPoints: Set<LightPollutionPoint> {
        var points = Set(plannedSites.map { LightPollutionPoint($0.coordinate) })
        if let activeCoordinate { points.insert(LightPollutionPoint(activeCoordinate)) }
        return points
    }
    private var forecastPoint: AstroForecastPoint? {
        forecastSelection.point(sites: plannedSites, location: location)
    }
    private var forecast: AstroForecast? { forecastStore.forecast(at: forecastPoint) }
    private var forecastBase: Date {
        forecast?.hours.first?.date ?? cloudGrid?.firstForecastHour ?? Date()
    }
    private var selectedDate: Date { forecastBase.addingTimeInterval(forecastIndex * 3600) }
    private var selectedHour: AstroForecastHour? { forecast?.hours.first { $0.date == selectedDate } }
    private var forecastLocationLabel: String {
        if let selectedSite { return selectedSite.name }
        if let mapCenter, AstroForecastPoint(mapCenter) != location.flatMap({ AstroForecastPoint($0.coordinate) }) {
            return "地图中心"
        }
        return "当前位置"
    }

    private var timeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(forecastLocationLabel + " · " + forecastLabel)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 14)
                .padding(.top, 14)
            GeometryReader { proxy in
                ZStack {
                    AstroTimeRuler(hour: $forecastIndex, maxHour: 47, tint: AppTheme.accent)
                        .frame(width: proxy.size.width * 0.75)
                        .frame(maxWidth: .infinity, alignment: .center)
                    HStack(alignment: .center) {
                        VStack(spacing: 1) {
                            Text(forecastBaseDate).font(.system(size: 8, weight: .medium, design: .monospaced))
                            Text(forecastBaseTime).font(.system(size: 8, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.55))
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(forecastEndDate).font(.system(size: 8, weight: .medium, design: .monospaced))
                            Text(forecastEndTime).font(.system(size: 8, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 2)
                }
            }
            .frame(height: 46)
            if let forecast {
                AstroCloudCurve(hours: forecast.hours, selectedHour: Int(forecastIndex))
                    .frame(height: 38)
                    .padding(.horizontal, 14)
                    .accessibilityLabel("未来 48 小时总云量曲线")
                HStack {
                    Text("总云量 \(percent(selectedHour?.cloud))")
                    Spacer()
                    Link(forecast.sourceName, destination: forecast.sourceURL)
                }
                .font(.caption2)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            } else {
                forecastStatus
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func dateText(_ date: Date, _ format: Date.FormatStyle, zone: TimeZone? = nil) -> String {
        var format = format
        format.timeZone = zone ?? forecast?.timeZone ?? .current
        return date.formatted(format)
    }

    private var forecastLabel: String {
        dateText(selectedDate, .dateTime.month().day().hour(.twoDigits(amPM: .omitted)))
    }

    private var forecastBaseDate: String { dateText(forecastBase, .dateTime.month().day()) }
    private var forecastBaseTime: String { dateText(forecastBase, .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
    private var forecastEndDate: String { dateText(forecastBase.addingTimeInterval(47 * 3600), .dateTime.month().day()) }
    private var forecastEndTime: String {
        dateText(forecastBase.addingTimeInterval(47 * 3600), .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private var forecastStatus: some View {
        HStack(spacing: 8) {
            if forecastPoint == nil {
                Text("等待定位，或在地图上放大查看")
            } else if forecastStore.failedPoint == forecastPoint {
                Text(forecastStore.isUnconfigured ? "此版本未配置天气服务" : "暂时无法加载天气")
                if !forecastStore.isUnconfigured {
                    Button("重试") { forecastRetry += 1 }.tint(AppTheme.accent)
                }
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("正在获取 48 小时预报")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var conditionsCard: some View {
        let hour = selectedHour
        let sky = hour.flatMap { hour in forecastPoint.map { AstroSkyPosition(at: hour.date, point: $0) } }
        return VStack(alignment: .leading, spacing: 10) {
            Text("环境数据").font(.system(size: 12, weight: .semibold))
            dataRow("Bortle / SQM", "—")
            dataRow("总云量", percent(hour?.cloud))
            dataRow("低 / 中 / 高云", [hour?.lowCloud, hour?.middleCloud, hour?.highCloud].map(percent).joined(separator: " / "))
            dataRow("能见度", number(hour?.visibility.map { $0 / 1000 }, suffix: " km", digits: 1))
            dataRow("月光", sky.map { ($0.moonAltitude > 0 ? "月亮在地平线上 · " : "月亮在地平线下 · ") + percent($0.illuminatedFraction * 100) } ?? "—")
            dataRow("湿度 / 露点", percent(hour?.humidity) + " / " + number(hour?.dewPoint, suffix: "°C", digits: 1))
            dataRow("风速 / 阵风", number(hour?.wind, suffix: " km/h") + " / " + number(hour?.gust, suffix: " km/h"))
            if let direction = hour?.windDirection, (0...360).contains(direction) {
                dataRow("风向", ["北", "东北", "东", "东南", "南", "西南", "西", "西北"][Int((direction / 45).rounded()) % 8] + "风")
            }
            if hour?.dewRisk == true { dataRow("结露风险", "气温接近露点") }
            if (hour?.gust ?? 0) >= 30 { dataRow("风力提示", "阵风较强") }
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func number(_ value: Double?, suffix: String, digits: Int = 0) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits))) + suffix
    }

    private func percent(_ value: Double?) -> String { number(value, suffix: "%") }

    private func recommendation(at coordinate: CLLocationCoordinate2D?, forecast: AstroForecast?) -> String? {
        guard let coordinate, let point = AstroForecastPoint(coordinate) else { return nil }
        guard let resolved = pollutionBands[LightPollutionPoint(coordinate)] else { return nil }
        let sky = AstroDarkSkySuitability(band: resolved)
        if sky == .severe { return "光污染严重，未来 48 小时不推荐拍摄银河或暗弱星空" }
        guard let forecast else { return nil }
        let windows = forecast.windows(at: point, after: Date(), lightPollution: resolved)
        guard !windows.isEmpty else { return "未来 48 小时暂无合适窗口" }
        let style = Date.FormatStyle.dateTime.month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        let times = windows.map { window in
            dateText(window.start, style, zone: forecast.timeZone) + " – " + dateText(window.end, style, zone: forecast.timeZone)
        }.joined(separator: "\n")
        if sky == .unknown { return "光污染未知 · 仅按天气估算\n" + times }
        if sky == .high { return "光污染偏强 · 拍摄条件有限\n" + times }
        return times
    }

    private func dataRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("推荐拍摄窗口").font(.system(size: 12, weight: .semibold))
                    Text(plannedSites.isEmpty ? "移动地图，把中心针对准机位后设为机位（最多 3 个）" : "已设置 \(plannedSites.count)/3 个机位")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(plannedSites.count >= 3 ? "已达 3 个" : "设为机位") { addPlannedSite() }
                    .buttonStyle(.borderedProminent).tint(AppTheme.accent)
                    .font(.system(size: 11, weight: .medium))
                    .disabled((mapCenter ?? location?.coordinate) == nil || plannedSites.count >= 3)
            }
            if forecastPoint != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(forecastLocationLabel)
                        if let coordinate = activeCoordinate {
                            Text(String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    if let coordinate = activeCoordinate,
                       let band = pollutionBands[LightPollutionPoint(coordinate)] ?? nil {
                        Text("人工天光约为自然天光的 \(band.range)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let text = recommendation(at: activeCoordinate, forecast: forecast) {
                        Text(text).font(.caption2).foregroundStyle(AppTheme.accent)
                            .accessibilityIdentifier("astro.environment.recommendation")
                    } else {
                        forecastStatus
                    }
                }
            }
            if !plannedSites.isEmpty {
                Divider().overlay(.white.opacity(0.12))
                if #available(iOS 27, *) {
                    VStack(spacing: 10) {
                        ForEach(plannedSites) { site in
                            plannedSiteRow(site)
                                .swipeActions(allowsFullSwipe: false) {
                                    Button(role: .destructive) { deletePlannedSite(site) } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    .accessibilityIdentifier("astro.environment.site.delete.\(site.slot)")
                                } onPresentationChanged: { _ in }
                                .transition(.opacity)
                        }
                    }
                    .swipeActionsContainer()
                } else {
                    ForEach(plannedSites) { site in
                        AstroSiteSwipeRow(revealed: revealedSiteID == site.id, deleteLabel: "删除\(site.name)",
                                          onReveal: { revealedSiteID = $0 ? site.id : nil },
                                          onDelete: { deletePlannedSite(site) }) {
                            plannedSiteRow(site)
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func plannedSiteRow(_ site: AstroPlannedSite) -> some View {
        let point = AstroForecastPoint(site.coordinate)
        return HStack(alignment: .center, spacing: 10) {
            Button {
                forecastSelection.siteID = forecastSelection.siteID == site.id ? nil : site.id
                forecastIndex = 0
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(site.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(forecastSelection.siteID == site.id ? AppTheme.accent : .white)
                    Text(site.coordinateText).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                    if forecastSelection.siteID != site.id {
                        Text(recommendation(at: site.coordinate, forecast: forecastStore.forecast(at: point)) ?? "轻点查看预报")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("astro.environment.site.select.\(site.slot)")
            .accessibilityAddTraits(forecastSelection.siteID == site.id ? .isSelected : [])
            Button("导航") { openNavigation(to: site) }
                .buttonStyle(.bordered).font(.system(size: 10, weight: .medium))
                .accessibilityLabel("导航到 \(site.name)")
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func deletePlannedSite(_ site: AstroPlannedSite) {
        withAnimation(.easeOut(duration: reduceMotion ? 0.08 : 0.16)) {
            if revealedSiteID == site.id { revealedSiteID = nil }
            if forecastSelection.siteID == site.id { forecastSelection.siteID = nil }
            plannedSites.removeAll { $0.id == site.id }
        }
        AstroPlannedSite.save(plannedSites)
    }

    private func addPlannedSite() {
        guard let coordinate = mapCenter ?? location?.coordinate,
              let slot = AstroPlannedSite.availableSlot(in: plannedSites) else { return }
        let site = AstroPlannedSite(slot: slot, coordinate: coordinate)
        plannedSites.append(site)
        AstroPlannedSite.save(plannedSites)
        forecastSelection.siteID = site.id
    }

    private func openNavigation(to site: AstroPlannedSite) {
        let placemark = MKPlacemark(coordinate: site.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = site.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(location?.addressText ?? location?.watermarkText ?? "未获取当前位置")
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .accessibilityIdentifier("astro.environment.location")
                if let location, location.addressText != nil {
                    Text(location.coordinateText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            TimelineView(.everyMinute) { timeline in
                VStack(alignment: .trailing, spacing: 2) {
                    Text(timeline.date, format: .dateTime.year().month().day())
                        .font(.subheadline.weight(.medium))
                    Text(timeline.date, format: .dateTime.hour().minute())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .accessibilityIdentifier("astro.environment.time")
            }
        }
    }
}

struct AstroNightLightsMap: UIViewRepresentable {
    let location: PhotoLocation?
    let locationService: CaptureLocationService?
    let source: any LightPollutionSource
    let recenterToken: UUID
    let sites: [AstroPlannedSite]
    let layer: AstroEnvironmentLayer
    let cloudFrame: AstroCloudFrame?
    let cloudZoomToken: UUID
    let cloudFocus: CLLocationCoordinate2D?
    let onRegionChange: (AstroCloudRegion?) -> Void
    let onCenterChange: (CLLocationCoordinate2D?) -> Void
    let onPan: (CLLocationCoordinate2D?) -> Void
    let onSelectSite: (UUID) -> Void
    func makeCoordinator() -> Coordinator {
        Coordinator(source: source, onCenterChange: onCenterChange, onPan: onPan, onSelectSite: onSelectSite,
                    onRegionChange: onRegionChange)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.accessibilityIdentifier = "astro.environment.map"
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.traitOverrides.accessibilityContrast = .high
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.setVisibleMapRect(.world, animated: false)
        context.coordinator.observePanning(on: map)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.updateCloudViewport(for: layer, zoomToken: cloudZoomToken, focus: cloudFocus, on: map)
        coordinator.updateLayers(layer, cloudFrame: cloudFrame, on: map)
        coordinator.observeHeading(from: locationService, on: map)
        coordinator.syncSites(sites, on: map)
        guard let location else {
            if map.annotations.contains(where: { $0 === coordinator.marker }) {
                map.removeAnnotation(coordinator.marker)
            }
            return
        }
        if coordinator.marker.coordinate.latitude != location.latitude || coordinator.marker.coordinate.longitude != location.longitude {
            coordinator.marker.coordinate = location.coordinate
        }
        if !map.annotations.contains(where: { $0 === coordinator.marker }) { map.addAnnotation(coordinator.marker) }
        if coordinator.lastRecenterToken != recenterToken {
            coordinator.lastRecenterToken = recenterToken
            coordinator.centeredOnLocation = true
            map.setRegion(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 120_000, longitudinalMeters: 120_000), animated: true)
            DispatchQueue.main.async { coordinator.refreshOverlays(on: map) }
            return
        }
        guard !coordinator.centeredOnLocation else { return }
        coordinator.centeredOnLocation = true
        map.setRegion(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 120_000, longitudinalMeters: 120_000), animated: false)
        DispatchQueue.main.async { coordinator.refreshOverlays(on: map) }
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.observeHeading(from: nil, on: map)
        coordinator.stopOverlayUpdates()
        coordinator.cancelCloudRender()
        map.delegate = nil
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        let marker = MKPointAnnotation()
        var centeredOnLocation = false
        var lastRecenterToken: UUID?
        private let source: any LightPollutionSource
        private var lastOverlayRect: MKMapRect?
        private let onCenterChange: (CLLocationCoordinate2D?) -> Void
        private let onPan: (CLLocationCoordinate2D?) -> Void
        private let onSelectSite: (UUID) -> Void
        private let onRegionChange: (AstroCloudRegion?) -> Void
        private var siteAnnotations: [UUID: AstroSiteAnnotation] = [:]
        private weak var headingService: CaptureLocationService?
        private var heading: CLLocationDirection?
        private var layer: AstroEnvironmentLayer = .pollution
        private var cloudOverlay: AstroCloudOverlay?
        private struct CloudFrameKey: Equatable {
            let gridID: UUID
            let date: Date
        }

        private var cloudFrameKey: CloudFrameKey?
        private var cloudRenderTask: Task<Void, Never>?
        private var rasterGridID: UUID?
        private let cloudRasters = NSCache<NSDate, CGImage>()
        private var lastCloudZoomToken: UUID?
        private var requestedCloudRegion: AstroCloudRegion?

        init(source: any LightPollutionSource, onCenterChange: @escaping (CLLocationCoordinate2D?) -> Void,
             onPan: @escaping (CLLocationCoordinate2D?) -> Void = { _ in },
             onSelectSite: @escaping (UUID) -> Void = { _ in },
             onRegionChange: @escaping (AstroCloudRegion?) -> Void = { _ in }) {
            self.source = source
            self.onCenterChange = onCenterChange
            self.onPan = onPan
            self.onSelectSite = onSelectSite
            self.onRegionChange = onRegionChange
            cloudRasters.countLimit = 12
        }

        func updateCloudViewport(for mode: AstroEnvironmentLayer, zoomToken: UUID,
                                 focus: CLLocationCoordinate2D?, on map: MKMapView) {
            let zoomRequested = lastCloudZoomToken.map { $0 != zoomToken } ?? false
            lastCloudZoomToken = zoomToken
            guard mode.includesClouds, !layer.includesClouds || zoomRequested else { return }
            DispatchQueue.main.async { [weak self, weak map] in
                guard let self, let map, self.layer.includesClouds else { return }
                if let region = self.cloudRegion(for: map.visibleMapRect) {
                    self.onRegionChange(region)
                } else if let coordinate = zoomRequested ? map.centerCoordinate : focus {
                    map.setRegion(.init(center: coordinate, latitudinalMeters: 160_000, longitudinalMeters: 160_000),
                                  animated: true)
                }
            }
        }

        private func cloudRegion(for rect: MKMapRect) -> AstroCloudRegion? {
            let next = AstroCloudRegion(rect)
            if let requestedCloudRegion, let next,
               requestedCloudRegion.mapRect.width <= next.mapRect.width * 1.5,
               requestedCloudRegion.mapRect.contains(rect) { return requestedCloudRegion }
            requestedCloudRegion = next
            return next
        }

        func updateLayers(_ mode: AstroEnvironmentLayer, cloudFrame: AstroCloudFrame?, on map: MKMapView) {
            if mode.includesPollution != layer.includesPollution {
                layer = mode
                if mode.includesPollution {
                    refreshOverlays(on: map)
                } else {
                    stopOverlayUpdates()
                    map.removeOverlays(map.overlays.compactMap { $0 as? LightPollutionImageOverlay })
                    addedKeys.removeAll()
                    lastOverlayRect = nil
                }
            }
            layer = mode
            guard mode.includesClouds, let cloudFrame else {
                cancelCloudRender()
                if let cloudOverlay { map.removeOverlay(cloudOverlay) }
                cloudOverlay = nil
                return
            }
            if let cloudOverlay, let renderer = map.renderer(for: cloudOverlay), renderer.alpha != cloudsAlpha {
                renderer.alpha = cloudsAlpha
                renderer.setNeedsDisplay()
            }

            let key = CloudFrameKey(gridID: cloudFrame.gridID, date: cloudFrame.date)
            guard cloudFrameKey != key else { return }
            cancelCloudRender()
            cloudFrameKey = key
            if rasterGridID != key.gridID {
                cloudRasters.removeAllObjects()
                rasterGridID = key.gridID
            }
            let cacheKey = key.date as NSDate
            if let cached = cloudRasters.object(forKey: cacheKey) {
                applyCloudRaster(cached, region: cloudFrame.region, on: map)
                return
            }
            cloudRenderTask = Task { @MainActor [weak self, weak map] in
                // Coalesce rapid ruler updates while keeping the last raster on screen.
                try? await Task.sleep(for: .milliseconds(35))
                guard !Task.isCancelled else { return }
                let image = await Task.detached(priority: .userInitiated) { cloudFrame.makeImage() }.value
                guard !Task.isCancelled, let self, let map, self.cloudFrameKey == key else { return }
                self.cloudRenderTask = nil
                guard let image else { return }
                self.cloudRasters.setObject(image, forKey: cacheKey)
                self.applyCloudRaster(image, region: cloudFrame.region, on: map)
            }
        }

        private func applyCloudRaster(_ image: CGImage, region: AstroCloudRegion, on map: MKMapView) {
            if let cloudOverlay, cloudOverlay.region == region {
                cloudOverlay.setImage(image)
                map.renderer(for: cloudOverlay)?.setNeedsDisplay()
            } else {
                if let cloudOverlay { map.removeOverlay(cloudOverlay) }
                let overlay = AstroCloudOverlay(region: region, image: image)
                cloudOverlay = overlay
                map.addOverlay(overlay, level: .aboveRoads)
            }
        }

        func cancelCloudRender() {
            cloudRenderTask?.cancel()
            cloudRenderTask = nil
            cloudFrameKey = nil
        }

        private var cloudsAlpha: CGFloat { layer == .combined ? 0.70 : 0.90 }

        func stopOverlayUpdates() {
            generation += 1
        }

        func observePanning(on map: MKMapView) {
            let observer = UIPanGestureRecognizer(target: self, action: #selector(observeMapPan(_:)))
            observer.maximumNumberOfTouches = 1
            observer.cancelsTouchesInView = false
            observer.delegate = self
            map.addGestureRecognizer(observer)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let map = gestureRecognizer.view, let otherView = otherGestureRecognizer.view else { return false }
            return otherView === map || otherView.isDescendant(of: map)
        }

        @objc private func observeMapPan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended, let map = gesture.view as? MKMapView else { return }
            finishMapPan(on: map)
        }

        func finishMapPan(on map: MKMapView) {
            onPan(forecastCenter(of: map))
            for annotation in map.selectedAnnotations { map.deselectAnnotation(annotation, animated: false) }
        }

        private func forecastCenter(of map: MKMapView) -> CLLocationCoordinate2D? {
            map.visibleMapRect.width < MKMapRect.world.width * 0.15 ? map.centerCoordinate : nil
        }

        func observeHeading(from service: CaptureLocationService?, on map: MKMapView) {
            guard headingService !== service else { return }
            headingService?.onHeadingChange = nil
            headingService = service
            setHeading(service?.heading, on: map)
            service?.onHeadingChange = { [weak self, weak map] value in
                guard let self, let map else { return }
                self.setHeading(value, on: map)
            }
        }

        func setHeading(_ value: CLLocationDirection?, on map: MKMapView) {
            // Preserve the last valid bearing through a temporary compass outage or annotation reuse.
            guard let value else { return }
            heading = value
            (map.view(for: marker) as? AstroLocationAnnotationView)?.setHeading(value, animated: true)
        }

        func syncSites(_ sites: [AstroPlannedSite], on map: MKMapView) {
            let ids = Set(sites.map(\.id))
            let stale = siteAnnotations.filter { !ids.contains($0.key) }
            if !stale.isEmpty {
                map.removeAnnotations(stale.values.map { $0 })
                stale.keys.forEach { siteAnnotations.removeValue(forKey: $0) }
            }
            for site in sites where siteAnnotations[site.id] == nil {
                let annotation = AstroSiteAnnotation(site: site)
                siteAnnotations[site.id] = annotation
                map.addAnnotation(annotation)
            }
        }

        private var addedKeys = Set<String>()
        private var generation = 0

        func refreshOverlays(on map: MKMapView) {
            let visible = map.visibleMapRect
            // At continental/world zoom avoid requesting every cell at once.
            guard layer.includesPollution, visible.width < MKMapRect.world.width * 0.15 else { return }
            let expanded = visible.insetBy(dx: -visible.width * 0.25, dy: -visible.height * 0.25)
            if let last = lastOverlayRect, last.contains(visible) { return }
            lastOverlayRect = expanded
            let pending = source.overlays(in: expanded)
                .compactMap { $0 as? LightPollutionImageOverlay }
                .filter { !addedKeys.contains($0.id) }
                .sorted {
                    $0.boundingMapRect.intersects(visible) && !$1.boundingMapRect.intersects(visible)
                }
            guard !pending.isEmpty else { return }
            generation += 1
            let token = generation
            // Add in small batches so panning stays responsive and the layer
            // appears progressively instead of blocking on all visible cells.
            Task { @MainActor [weak self, weak map] in
                guard let self, let map else { return }
                for start in stride(from: 0, to: pending.count, by: 4) {
                    guard self.generation == token else { return }
                    let batch = Array(pending[start..<min(start + 4, pending.count)])
                    let fresh = batch.filter { !self.addedKeys.contains($0.id) }
                    guard !fresh.isEmpty else { continue }
                    self.addedKeys.formUnion(fresh.map(\.id))
                    if self.cloudOverlay == nil {
                        map.addOverlays(fresh, level: .aboveRoads)
                    } else {
                        for cell in fresh { map.insertOverlay(cell, at: 0, level: .aboveRoads) }
                    }
                    await Task.yield()
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let center = forecastCenter(of: mapView)
            let region = cloudRegion(for: mapView.visibleMapRect)
            DispatchQueue.main.async {
                self.onCenterChange(center)
                self.onRegionChange(region)
            }
            refreshOverlays(on: mapView)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let site = view.annotation as? AstroSiteAnnotation else { return }
            onSelectSite(site.site.id)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation is AstroSiteAnnotation {
                let identifier = "astro.planned.site"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.glyphImage = UIImage(systemName: "camera.fill")
                view.markerTintColor = UIColor(AppTheme.accent)
                view.displayPriority = .required
                return view
            }
            if annotation === marker {
                let identifier = "astro.current.location"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? AstroLocationAnnotationView
                    ?? AstroLocationAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.setHeading(heading, animated: false)
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if overlay is AstroCloudOverlay {
                let renderer = AstroCloudOverlayRenderer(overlay: overlay)
                renderer.alpha = cloudsAlpha
                return renderer
            }
            guard let cell = overlay as? LightPollutionImageOverlay else { return MKOverlayRenderer(overlay: overlay) }
            return LightPollutionOverlayRenderer(cell)
        }
    }
}

struct AstroPlannedSite: Identifiable, Codable {
    private static let defaultsKey = "astro.environment.plannedSites"
    let id: UUID
    let slot: Int
    private let latitude: Double
    private let longitude: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    init(slot: Int, coordinate: CLLocationCoordinate2D) {
        id = UUID()
        self.slot = slot
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    static func restore(from defaults: UserDefaults = .standard) -> [Self] {
        guard let data = defaults.data(forKey: defaultsKey),
              let sites = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        var slots = Set<Int>()
        return sites.filter { (1...3).contains($0.slot) && CLLocationCoordinate2DIsValid($0.coordinate)
            && slots.insert($0.slot).inserted }
    }

    static func save(_ sites: [Self], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(sites) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
    var name: String { "机位 \(slot)" }
    static func availableSlot(in sites: [Self]) -> Int? {
        (1...3).first { slot in !sites.contains { $0.slot == slot } }
    }
    var coordinateText: String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
}

final class AstroSiteAnnotation: NSObject, MKAnnotation {
    let site: AstroPlannedSite
    var coordinate: CLLocationCoordinate2D { site.coordinate }
    var title: String? { site.name }
    init(site: AstroPlannedSite) { self.site = site }
}

final class AstroLocationAnnotationView: MKAnnotationView {
    let arrow = UIImageView(image: UIImage(systemName: "location.north.fill",
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))?
        .withRenderingMode(.alwaysTemplate))
    private var heading: CLLocationDirection?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        backgroundColor = .systemBlue
        layer.cornerRadius = 14
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.white.cgColor
        displayPriority = .required
        collisionMode = .circle
        accessibilityLabel = "当前位置"
        arrow.frame = bounds.insetBy(dx: 6, dy: 6)
        arrow.contentMode = .scaleAspectFit
        arrow.tintColor = .white
        addSubview(arrow)
    }

    required init?(coder: NSCoder) { nil }

    func setHeading(_ value: CLLocationDirection?, animated: Bool) {
        let hadHeading = heading != nil
        heading = value
        // Point up until the first bearing arrives. Style is independent of sensor availability.
        let transform = CGAffineTransform(rotationAngle: CGFloat((value ?? 0) * .pi / 180))
        if animated, hadHeading, value != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                self.arrow.transform = transform
            }
        } else {
            arrow.layer.removeAllAnimations()
            arrow.transform = transform
        }
    }
}

private struct AstroSiteSwipeRow<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let revealed: Bool
    let deleteLabel: String
    let onReveal: (Bool) -> Void
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .offset(x: revealed ? -64 : 0)
            .overlay(alignment: .trailing) {
                if revealed {
                    Button(role: .destructive, action: onDelete) {
                        Label("删除", systemImage: "trash")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 44)
                            .background(.red, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(deleteLabel)
                    .transition(.opacity)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(AstroSiteSwipeGesture(direction: .left) { onReveal(true) })
            .gesture(AstroSiteSwipeGesture(direction: .right) { if revealed { onReveal(false) } })
            .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.17), value: revealed)
            .accessibilityAction(named: Text(deleteLabel), onDelete)
    }
}

private struct AstroSiteSwipeGesture: UIGestureRecognizerRepresentable {
    let direction: UISwipeGestureRecognizer.Direction
    let action: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UISwipeGestureRecognizer {
        let gesture = UISwipeGestureRecognizer()
        gesture.direction = direction
        gesture.delegate = context.coordinator
        return gesture
    }

    func handleUIGestureRecognizerAction(_ recognizer: UISwipeGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action() }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer.view is UIScrollView
        }
    }
}

private struct AstroCloudCurve: View {
    let hours: [AstroForecastHour]
    let selectedHour: Int

    var body: some View {
        Canvas { context, size in
            guard let firstDate = hours.first?.date else { return }
            let step = size.width / 47
            var line = Path()
            var previousHour: Int?
            for hour in hours {
                guard let cloud = hour.cloud else { continue }
                let index = Int(hour.date.timeIntervalSince(firstDate) / 3600)
                guard (0...47).contains(index) else { continue }
                let position = CGPoint(x: CGFloat(index) * step, y: (1 - min(100, max(0, cloud)) / 100) * size.height)
                if previousHour == index - 1 {
                    line.addLine(to: position)
                } else {
                    line.move(to: position)
                }
                previousHour = index
            }
            context.stroke(line, with: .color(AppTheme.accent), lineWidth: 1.5)
            let x = CGFloat(selectedHour) * step
            var selection = Path()
            selection.move(to: CGPoint(x: x, y: 0))
            selection.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(selection, with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
    }
}
