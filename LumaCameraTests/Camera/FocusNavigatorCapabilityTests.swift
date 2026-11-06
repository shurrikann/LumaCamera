import XCTest
import AVFoundation
@testable import LumaCamera

final class FocusNavigatorCapabilityTests: XCTestCase {
    #if !targetEnvironment(simulator)
    @MainActor func testWideAndTelephotoNavigationCaptureCapabilities() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let wasActive = model.camera.ready
        model.setCameraActive(false)
        try await Task.sleep(for: .milliseconds(600))
        defer { if wasActive { model.setCameraActive(true) } }
        let result = await Task.detached(priority:.userInitiated) { () -> String in
            guard AVCaptureMultiCamSession.isMultiCamSupported,
                  let wide = AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back),
                  let tele = AVCaptureDevice.default(.builtInTelephotoCamera,for:.video,position:.back) else { return "unsupported" }
            let session = AVCaptureMultiCamSession(), photo = AVCapturePhotoOutput()
            let wideOutput = AVCaptureVideoDataOutput(), teleOutput = AVCaptureVideoDataOutput()
            let originalWide = wide.activeFormat, originalTele = tele.activeFormat
            defer {
                session.stopRunning()
                for (device,format) in [(wide,originalWide),(tele,originalTele)] {
                    if (try? device.lockForConfiguration()) != nil { device.activeFormat = format; device.unlockForConfiguration() }
                }
            }
            do {
                session.beginConfiguration()
                for device in [tele,wide] {
                    guard let format = device.formats.filter({ $0.isMultiCamSupported }).sorted(by: { a,b in
                        if a.isHighestPhotoQualitySupported != b.isHighestPhotoQualitySupported { return a.isHighestPhotoQualitySupported }
                        let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription), db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                        return Int64(da.width)*Int64(da.height) < Int64(db.width)*Int64(db.height)
                    }).first else { session.commitConfiguration(); return "no format" }
                    try device.lockForConfiguration(); device.activeFormat = format; device.unlockForConfiguration()
                    let input = try AVCaptureDeviceInput(device:device)
                    guard session.canAddInput(input) else { session.commitConfiguration(); return "no input" }
                    session.addInputWithNoConnections(input)
                    let output = device == tele ? teleOutput : wideOutput
                    guard session.canAddOutput(output) else { session.commitConfiguration(); return "no video output" }
                    session.addOutputWithNoConnections(output)
                    let port = input.ports.first { $0.mediaType == .video }!
                    let connection = AVCaptureConnection(inputPorts:[port],output:output)
                    guard session.canAddConnection(connection) else { session.commitConfiguration(); return "no video connection" }
                    session.addConnection(connection)
                    if device == tele {
                        guard session.canAddOutput(photo) else { session.commitConfiguration(); return "no photo output" }
                        session.addOutputWithNoConnections(photo)
                        let connection = AVCaptureConnection(inputPorts:[port],output:photo)
                        guard session.canAddConnection(connection) else { session.commitConfiguration(); return "no photo connection" }
                        session.addConnection(connection)
                        if let dimension = format.supportedMaxPhotoDimensions.last { photo.maxPhotoDimensions = dimension }
                        if photo.isAppleProRAWSupported { photo.isAppleProRAWEnabled = true }
                    }
                }
                session.commitConfiguration()
                let values:[String:Any] = ["cost":session.hardwareCost,"pressure":session.systemPressureCost,"proRAW":photo.isAppleProRAWSupported,"rawTypes":photo.availableRawPhotoPixelFormatTypes,"live":photo.isLivePhotoCaptureSupported,"telePhoto":tele.activeFormat.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" },"teleHighestQuality":tele.activeFormat.isHighestPhotoQualitySupported]
                return String(data:try JSONSerialization.data(withJSONObject:values,options:.sortedKeys),encoding:.utf8)!
            } catch { return error.localizedDescription }
        }.value
        print("FOCUS-NAVIGATION-CAPABILITIES \(result)")
    }

    @MainActor func testVideoOnlyLowResolutionMultiCamPressureCandidates() async throws {
        let model = try XCTUnwrap(AppDependencies.runningAppCameraModel)
        let wasActive = model.camera.ready
        model.setCameraActive(false)
        try await Task.sleep(for: .milliseconds(600))
        defer { if wasActive { model.setCameraActive(true) } }

        let result = await Task.detached(priority: .userInitiated) { () -> String in
            guard AVCaptureMultiCamSession.isMultiCamSupported else { return "unsupported" }
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                mediaType: .video,
                position: .back
            )
            let devices = discovery.devices
            let pairs: [(AVCaptureDevice.DeviceType, AVCaptureDevice.DeviceType)] = [
                (.builtInUltraWideCamera, .builtInWideAngleCamera),
                (.builtInWideAngleCamera, .builtInTelephotoCamera),
                (.builtInUltraWideCamera, .builtInTelephotoCamera)
            ]
            var results: [[String: Any]] = []

            for pair in pairs {
                guard let first = devices.first(where: { $0.deviceType == pair.0 }),
                      let second = devices.first(where: { $0.deviceType == pair.1 }) else { continue }
                let selected = [first, second].compactMap { device -> (AVCaptureDevice, AVCaptureDevice.Format)? in
                    let formats = device.formats.filter { format in
                        format.isMultiCamSupported && format.videoSupportedFrameRateRanges.contains {
                            $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
                        }
                    }.sorted {
                        let lhs = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                        let rhs = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                        return Int64(lhs.width) * Int64(lhs.height) < Int64(rhs.width) * Int64(rhs.height)
                    }
                    guard let format = formats.first else { return nil }
                    return (device, format)
                }
                guard selected.count == 2 else { continue }

                let session = AVCaptureMultiCamSession()
                let outputs = selected.map { _ in AVCaptureVideoDataOutput() }
                var originalFormats: [(AVCaptureDevice, AVCaptureDevice.Format)] = []
                var failure: String?
                session.beginConfiguration()
                for (index, (device, format)) in selected.enumerated() {
                    originalFormats.append((device, device.activeFormat))
                    var configurationLocked = false
                    do {
                        try device.lockForConfiguration()
                        configurationLocked = true
                        device.activeFormat = format
                        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                        device.unlockForConfiguration()
                        configurationLocked = false
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else { throw NSError(domain: "FocusAssistProbe", code: 1) }
                        session.addInputWithNoConnections(input)
                        let output = outputs[index]
                        guard session.canAddOutput(output) else { throw NSError(domain: "FocusAssistProbe", code: 2) }
                        session.addOutputWithNoConnections(output)
                        guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
                            throw NSError(domain: "FocusAssistProbe", code: 3)
                        }
                        let connection = AVCaptureConnection(inputPorts: [port], output: output)
                        guard session.canAddConnection(connection) else { throw NSError(domain: "FocusAssistProbe", code: 4) }
                        session.addConnection(connection)
                    } catch {
                        if configurationLocked { device.unlockForConfiguration() }
                        failure = error.localizedDescription
                        break
                    }
                }
                session.commitConfiguration()

                let dimensions = selected.map { _, format -> String in
                    let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return "\(size.width)x\(size.height)"
                }
                results.append([
                    "pair": "\(pair.0.rawValue)+\(pair.1.rawValue)",
                    "dimensions": dimensions,
                    "hardwareCost": session.hardwareCost,
                    "systemPressureCost": session.systemPressureCost,
                    "configurationError": failure as Any? ?? NSNull()
                ])

                session.beginConfiguration()
                for output in outputs { session.removeOutput(output) }
                for input in session.inputs { session.removeInput(input) }
                session.commitConfiguration()
                for (device, format) in originalFormats {
                    if (try? device.lockForConfiguration()) != nil {
                        device.activeFormat = format
                        device.unlockForConfiguration()
                    }
                }
            }
            return String(data: try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), encoding: .utf8)!
        }.value
        print("FOCUS-NAVIGATION-VIDEO-ONLY-CANDIDATES \(result)")
    }
    #endif
}
