import SwiftUI

/// Reserve the rotated content's actual bounds so the HUD stays inside the preview.
struct VideoRecordingHUD: View {
    let capacity: RecordingCapacity.Info?
    let showsAudio: Bool
    let left: Float
    let right: Float
    @Environment(\.captureControlsLandscape) private var landscape
    @State private var contentSize = CGSize.zero

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let capacity { RecordingCapacityPanel(info: capacity) }
            if showsAudio { StereoAudioMeter(left: left, right: right) }
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
        .rotatingCaptureContent()
        .frame(width: contentSize == .zero ? nil : landscape ? contentSize.height : contentSize.width,
               height: contentSize == .zero ? nil : landscape ? contentSize.width : contentSize.height)
    }
}
