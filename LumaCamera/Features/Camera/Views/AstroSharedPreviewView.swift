import AVFoundation
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// Step 1 of the shared-session integration: star mode uses the main
/// CameraEngine preview and route without starting another capture session.
struct AstroSharedPreviewView: View {
    @ObservedObject var camera: CameraEngine
    let onSelectMode: (CameraViewModel.TopLevelMode) -> Void
    @State private var mode: AstroCaptureMode = .photo
    @State private var environmentPresented = false
    @State private var frameCount = 10
    @State private var exposure: AstroPhotoExposure = .s1
    @State private var trailDuration = 30

    var body: some View {
        GeometryReader { geometry in
            let ratio: FrameRatio = mode == .timelapse ? .wide : .standard
            let preview = CameraPreviewLayout.frame(in: geometry.size, ratio: ratio)
            ZStack {
                Color.black.ignoresSafeArea()
                Group {
                    if let result = camera.astroPhotoResult {
                        Image(uiImage: result).resizable().scaledToFill()
                    } else if let image = camera.preview {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: preview.width, height: preview.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.16), lineWidth: 0.5))
                .position(x: preview.midX, y: preview.midY)

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
            }
        }
        .sheet(isPresented: $environmentPresented) {
            NavigationStack {
                VStack(spacing: 12) {
                    Image(systemName: "map").font(.system(size: 32))
                    Text("光污染与云层信息待接入").font(.headline)
                    Text("该入口只做界面占位，不显示伪造数据。").font(.caption).foregroundStyle(.secondary)
                }
                .navigationTitle("星空环境")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { environmentPresented = false } } }
            }
            .presentationDetents([.medium])
        }
    }

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 1) {
                    Text("HEIF").font(.system(size: 10, weight: .semibold))
                    Text(mode == .timelapse ? "4K" : "12MP").font(.system(size: 8)).opacity(0.7)
                }.frame(maxWidth: .infinity)
                Text(mode == .timelapse ? "16:9" : "4:3").font(.system(size: 10, weight: .semibold)).frame(maxWidth: .infinity)
                Text("—").font(.system(size: 12)).opacity(0.35).frame(maxWidth: .infinity)
                Text("—").font(.system(size: 12)).opacity(0.35).frame(maxWidth: .infinity)
                Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 48)
            }
            .foregroundStyle(.white)
            .frame(height: 32)
            HStack(spacing: 5) {
                Capsule().fill(.white.opacity(0.32)).frame(width: 22, height: 3)
                Circle().fill(.white.opacity(0.18)).frame(width: 3, height: 3)
            }.frame(height: 7)
        }.background(.black)
    }

    private var bottomBar: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                if mode == .photo {
                    Picker("帧数", selection: $frameCount) {
                        ForEach([10, 30, 60], id: \.self) { Text("\($0)帧").tag($0) }
                    }.pickerStyle(.menu).tint(.white)
                    Picker("曝光", selection: $exposure) {
                        ForEach(AstroPhotoExposure.allCases) { Text($0.rawValue + "s").tag($0) }
                    }.pickerStyle(.menu).tint(.white)
                } else if mode == .trails {
                    Picker("时长", selection: $trailDuration) {
                        ForEach([5, 10, 15, 30, 60, 120], id: \.self) { Text("\($0)秒").tag($0) }
                    }.pickerStyle(.menu).tint(.white)
                } else {
                    Text("延时接入中").font(.system(size: 10, weight: .semibold))
                }
                Spacer(minLength: 0)
                Text(camera.astroPhotoStatus.isEmpty ? "RAW 多帧" : camera.astroPhotoStatus)
                    .font(.system(size: 9)).lineLimit(1).opacity(0.65)
            }
            .disabled(camera.astroPhotoBusy)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14).frame(height: 46)
            .modifier(GlassSurface(radius: 23, previewOverlay: true))
            HStack(spacing: 0) {
                Text("相册").font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .frame(width: 52, height: 52).modifier(GlassSurface(radius: 26))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                ModeSwitchButton(current: .astro, size: 52) { onSelectMode($0) }
                    .allowsHitTesting(!camera.astroPhotoBusy)
                Spacer(minLength: 0)
                Button { photoAction() } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(0.85), lineWidth: 3).frame(width: 76, height: 76)
                        Circle().fill(camera.astroPhotoBusy ? Color.red.opacity(0.8) : Color.white).frame(width: 66, height: 66)
                        if camera.astroPhotoBusy {
                            RoundedRectangle(cornerRadius: 7).fill(.white).frame(width: 24, height: 24)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(mode == .timelapse)
                .accessibilityLabel(camera.astroPhotoBusy ? "取消星空拍摄" : mode == .trails ? "开始星轨" : "开始星空照片")
                Spacer(minLength: 0)
                Menu {
                    ForEach(AstroCaptureMode.allCases) { value in
                        Button(value.rawValue) { mode = value }
                    }
                } label: {
                    Text(mode == .photo ? "照片" : mode == .trails ? "星轨" : "延时")
                        .font(.system(size: 8, weight: .medium)).frame(width: 52, height: 52)
                        .modifier(GlassSurface(radius: 26))
                }
                Spacer(minLength: 0)
                Button { environmentPresented = true } label: {
                    Text("环境").font(.system(size: 8, weight: .medium)).frame(width: 52, height: 52)
                        .modifier(GlassSurface(radius: 26))
                }.buttonStyle(.plain)
            }
            .frame(height: 78)
            if camera.astroPhotoResult != nil {
                HStack(spacing: 12) {
                    Button("保存到相册") { saveAstroPhoto() }
                        .buttonStyle(.borderedProminent).tint(AppTheme.accent)
                    Button("重拍") { camera.cancelAstroPhotoStack() }
                        .buttonStyle(.bordered).tint(.white)
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 28)
    }

    private func photoAction() {
        if camera.astroPhotoBusy {
            camera.cancelAstroPhotoStack()
        } else {
            if mode == .trails {
                camera.beginAstroPhotoStack(frameCount: trailDuration, exposureSeconds: 1, blend: .lighten)
            } else {
                camera.beginAstroPhotoStack(frameCount: frameCount, exposureSeconds: exposure.seconds)
            }
        }
    }

    private func saveAstroPhoto() {
        guard let image = camera.astroPhotoResult, let cg = image.cgImage else { return }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, [
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Luma 12MP RAW star photo"]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        let encoded = data as Data
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: encoded, options: nil)
        }
    }
}
