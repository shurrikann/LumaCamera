import SwiftUI
import CoreLocation

@MainActor private enum PhotoAddressCache {
    static var titles: [String: String] = [:]
}
struct PhotoLocationTitle: View {
    let location: PhotoLocation
    @State private var address: String?
    var body: some View {
        Text(address ?? location.coordinateText)
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
            .lineLimit(1).truncationMode(.middle)
            .accessibilityLabel("拍摄地址：" + (address ?? location.coordinateText))
            .task(id: location) {
                address = nil
                let key = location.coordinateText
                if let cached = PhotoAddressCache.titles[key] { address = cached; return }
                let geocoder = CLGeocoder()
                await withTaskCancellationHandler {
                    guard let place = try? await geocoder.reverseGeocodeLocation(location.clLocation, preferredLocale: Locale(identifier: "zh_CN")).first,
                          !Task.isCancelled else { return }
                    let title = PhotoAddressPresentation.title(locality: place.locality, sublocality: place.subLocality,
                                                               street: place.thoroughfare, number: place.subThoroughfare, name: place.name)
                    guard !title.isEmpty else { return }
                    if PhotoAddressCache.titles.count >= 100 { PhotoAddressCache.titles.removeAll() }
                    PhotoAddressCache.titles[key] = title
                    address = title
                } onCancel: { geocoder.cancelGeocode() }
            }
    }
}
enum PhotoAddressPresentation {
    static func title(locality: String?, sublocality: String?, street: String?, number: String?, name: String?) -> String {
        var parts: [String] = []
        for part in [locality, sublocality, street, number] {
            if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) }
        }
        if parts.isEmpty, let name { return name }
        return parts.joined(separator: " · ")
    }
}
