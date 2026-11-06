import SwiftUI
import MapKit
import CoreLocation

struct PhotoInfoContent: View {
    let details: PhotoDetails?
    var loading = false
    var isVideo = false
    var body: some View {
        if loading { ProgressView("正在读取照片详情…").padding(24) }
        else if let details {
            let info = PhotoInfoPresentation(details: details, isVideo: isVideo)
            let deviceInfo = VStack(alignment: .leading, spacing: 8) {
                Text(info.camera).font(.system(size: 16, weight: .medium))
                HStack(alignment: .top, spacing: 12) {
                    Text(info.dimensionsAndSize).frame(maxWidth: .infinity, alignment: .leading)
                    Text(info.filename).multilineTextAlignment(.trailing).lineLimit(2)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.infoCard().accessibilityIdentifier("photo.info.device")
            VStack(alignment: .leading, spacing: 10) {
                Text(isVideo ? "视频" : "原图").font(.system(size: 18, weight: .semibold)).padding(.bottom, 2)
                Text(info.dateText).frame(maxWidth: .infinity, alignment: .leading).infoCard()
                if isVideo {
                    deviceInfo
                    PhotoCaptureParameterRow(items: info.parameterItems)
                    locationSection(details)
                } else {
                    locationSection(details)
                    PhotoCaptureParameterRow(items: info.parameterItems)
                    deviceInfo
                }
                if !info.additionalRows.isEmpty {
                    DisclosureGroup("更多拍摄信息") {
                        VStack(spacing: 12) {
                            ForEach(info.additionalRows) { row in
                                HStack(alignment: .top) {
                                    Text(row.title).foregroundStyle(.secondary)
                                    Spacer(minLength: 12)
                                    Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                                }.font(.system(size: 12))
                            }
                        }.padding(.top, 12)
                    }.font(.system(size: 13)).infoCard()
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
        } else { ContentUnavailableView("无法读取详情", systemImage: "info.circle") }
    }

    @ViewBuilder
    private func locationSection(_ details: PhotoDetails) -> some View {
        Group {
            if let location = details.location, location.isValid {
                PhotoLocationMap(location: location)
            } else {
                Label("未记录拍摄位置", systemImage: "location.slash").font(.system(size: 12))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).infoCard()
            }
        }.accessibilityIdentifier("photo.info.location")
    }

}

private struct PhotoCaptureParameterRow: View {
    let items: [PhotoInfoRow]

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(items) { item in
                VStack(spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 8, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text(item.value)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity, minHeight: 32)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.title + "：" + item.value)
                .accessibilityIdentifier("photo.info.parameter.\(item.title)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo.info.parameters")
    }
}

private extension View {
    func infoCard() -> some View {
        self.padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct PhotoLocationMap: View {
    let location: PhotoLocation
    @State private var address: String?
    var body: some View {
        VStack(spacing: 10) {
            Map(initialPosition: .region(MKCoordinateRegion(center: location.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006))), interactionModes: []) {
                Marker("拍摄位置", systemImage: "camera.fill", coordinate: location.coordinate).tint(AppTheme.accent)
            }.mapStyle(.standard(elevation: .flat, emphasis: .muted))
                .frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityLabel("照片拍摄位置地图")
            Text(address ?? location.coordinateText).font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center).textSelection(.enabled)
        }.task(id: location) {
            address = nil
            let geocoder = CLGeocoder()
            await withTaskCancellationHandler {
                if let place = try? await geocoder.reverseGeocodeLocation(location.clLocation).first, !Task.isCancelled {
                    var parts: [String] = []
                    for part in [place.locality ?? place.administrativeArea, place.subLocality, place.name] {
                        if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) }
                    }
                    if !parts.isEmpty { address = parts.joined(separator: "·") }
                }
            } onCancel: { geocoder.cancelGeocode() }
        }
    }
}

/// Overlays the existing photo viewport; it never changes the image or pinch-zoom view's layout.
struct PhotoInfoPanel: View {
    let details: PhotoDetails?
    var loading = false
    var isVideo = false
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Button(action: onClose) {
                Capsule().fill(.white.opacity(0.4)).frame(width: 34, height: 4)
                    .frame(maxWidth: .infinity).frame(height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("收起图片详情")
                .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { drag in
                    if drag.translation.height > 32 { onClose() }
                })
            ScrollView { PhotoInfoContent(details: details, loading: loading, isVideo: isVideo) }
                .scrollBounceBehavior(.basedOnSize)
        }.modifier(PopupSurface(radius: 28, glass: true))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .onTapGesture { } // Consume panel taps so only the uncovered photo dismisses it.
    }
}

struct PhotoInfoView: View {
    let details: PhotoDetails?
    var loading = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { PhotoInfoContent(details: details, loading: loading) }
                .navigationTitle("图片详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
            .presentationBackground { PopupGlassBackground(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)) }.preferredColorScheme(.dark)
    }
}
