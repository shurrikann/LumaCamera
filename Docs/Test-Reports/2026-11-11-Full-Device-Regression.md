# 2026-11-11 全量真机回归

设备：iPhone 17 Pro（iPhone18,1），iOS 27.2.1，Debug 构建。
代码：`2b23736` 加本轮未提交的慢动作帧率恢复修正（见文末）。
命令：

```bash
xcodebuild test -project LumaCamera.xcodeproj -scheme LumaCamera \
  -destination 'platform=iOS,id=00008150-001934280220401C' \
  -derivedDataPath /tmp/LumaFullRegressionDD -parallel-testing-enabled NO
```

测试范围：`LumaCameraTests` 全量套件。人像、电影等需要真实主体的项目只覆盖功能可用性和稳定性，不评价虚化/成片质量。

## 结果边界

真机全量套件在 `VideoSpecificationTests` 处被测试运行器提前终止，没有自然结束，也没有最终 XCTest 汇总。已执行：

```text
768 passed
51 failed
```

因此不能写成“全量真机通过”。为补齐后续视频/变焦套件，又单独运行了：

```text
42 passed
8 failed
```

模拟器全量套件完成：

```text
698 tests
50 skipped
423 assertion failures
30 unexpected
```

模拟器包含大量不适用于物理相机的测试，且部分失败是连续运行状态污染；两个环境的失败项都已记录，不据此直接判定产品回归。

## 功能覆盖结论

通过的代表性物理套件：

```text
PortraitCapturePhysicalTests
PortraitDepthControlTests
PortraitOptimizationPhysicalTests
NightAdaptiveCapturePhysicalTests
NightCapturePhysicalTests
NightPhotoMergerTests
DualCaptureCompatibilityTests
DualCaptureExpansionTests
DualCaptureLandscapeTests
DualCapturePhysicalTests
DualCaptureZoomPhysicalTests
CinematicMainFrameDeliveryTests
SlowMotionPhotoReturnZoomTests
VideoWhiteBalancePhysicalTests
ZoomDialDetentTests
ZoomThrottleTests
ZoomWheelReopenPhysicalTests
```

电影：主相机出帧稳定性和返回照片正常；电影变焦物理套件失败，见问题 2。人像：物理捕获、深度工具栏基础路径和优化套件通过，但连续 UI 时序套件失败，见问题 5。

## 关键问题

### 1. 随机子模块切换触发未捕获的 AVFoundation 异常（高，崩溃风险）

失败位置：

```text
SubmodeSwitchingPhysicalTests.testDualFrontMainKeepsFrontVideoCenteringEntry
SubmodeSwitchingPhysicalTests.testUnorderedPhotoVideoAndSubmodeSwitching
SubmodeSwitchingPhysicalTests.testVideoSubmodesCanSwitchRandomly
```

系统异常：

```text
*** -[AVCaptureDevice setActiveVideoMinFrameDuration:] Unsupported frame duration
```

当前设置在 `CameraEngine.configureVideoFormat` 里直接写入目标帧周期，未先校验 `activeFormat.videoSupportedFrameRateRanges`。这是潜在闪退，不只是断言失败。相关代码约 `CameraEngine.swift:2624`。

### 2. 电影变焦入口失败（高）

`CinematicZoomPhysicalTests.testFixedButtonsWheelRangeActualCinematicRouteAndRecovery` 单独复测仍失败：

```text
cinematicVideoEnabled = false
cinematicVideoCaptureActive = false
focal lenses = [0.5, 1, 2, 4, 8]
manual parameters = shutter/iso/ev/focus/wb/tint
zoom range = 0.5...40
```

电影没有进入，后续断言自然全部失败。不是虚化质量验收，是入口/路由可用性问题。

### 3. 慢动作后台恢复后的帧周期/录制失败（高）

`SlowMotionLensTransitionPhysicalTests` 单独复测失败：

```text
期望 240 fps 的曝光上限/帧周期，实际为 30 fps 档
快门范围断言失败
随后“视频暂时无法开始录制”
```

本轮曾清掉慢动作 `captureFrameRate` 以修复返回照片，但发现它会破坏“视频中退后台再回来”的慢动作状态，已撤回该清理。仍需处理后台恢复路径。

### 4. 延时摄影输出不符合预期（中）

`BasicVideoPhysicalTests.testTimeLapseRecordingCreatesSparseSilentMovie` 失败：

```text
仍有音轨
帧数 66，期望 3
片段约 2.276s，期望 0.45s 以下
```

不是测试时间误差，是延时成片的帧/音轨策略与断言不一致。

### 5. 景深工具栏 4 秒计时不稳定（中）

`DepthToolbarPhysicalTests` 失败：

```text
拖动持有时提前收起
最后一次操作后计时被提前结束
首次采样 2.517s，期望 >=3.9s
topSpacing 用例缺少 depthControlPopup 布局帧
```

深度工具栏的自动收起计时在连续 UI 操作下不可靠，且布局帧在部分比例下未发布。

### 6. 其他真机失败套件

```text
FocusNavigatorPhysicalTests
FrontSubmodeFramingPhysicalTests
FrontVideoStateMatrixTests
FrontWideAspectReturnPhysicalTests
HDRSequentialDiagnosticsTests
HEIFProMeteringScopeTests
IndependentNightCaptureTests
Lens48MPAuditTests
LivePhotoPlaybackPhysicalTests
PhotoCaptureTimeoutPhysicalTests
PhysicalCameraSwitchingTests
PopupAppearanceAndOrientationTests
PresetToolbarPhysicalTests
RecordingEdgeLayoutPhysicalTests
ShootingModeButtonTests
SilentShutterPhysicalTests
SlowShutterPresetTests
SlowShutterSequencePhysicalTests
VideoCodecPhysicalTests
VideoMacroIndicatorTests
VideoModeTransitionTests
VideoOverlayLayoutTests
VideoSelectionCompatibilityTests
VideoSpecificationTests
VideoStabilizationPhysicalTests
VirtualAperturePhysicalTests
```

这些未逐项隔离归因；不能直接判定全部是产品回归，也不能写成通过。其中电影/慢动作/子模块相关优先级最高。

### 7. 测试本身过期或环境依赖

```text
CameraFilmProfileTests：期望 46，当前 255；旧 LUT 数量断言未更新。
FilmColorLUTTests：参考坐标颜色最大差异约 10，software=true/false 都失败；与当前色彩管理/参考值不一致，需确认基线。
CameraViewModelTests / CaptureStatePersistenceTests / CompactFilterDialTests：
  在模拟器和真机都失败，原因是未启动相机时 setCaptureKind(.video) 被 !camera.ready 守卫拦截；
  这是测试前置条件问题，不是本次相机物理回归。
```

## 未覆盖

- 需要真实人物的电影浅景深/焦点转换视觉质量；`CinematicEffectPhysicalTests` 因场景未检出主体被 skip。
- 人像虚化质量、主体边缘、发丝细节。
- 外接存储 RAW/RAW HQ 端到端。
- 相册中每张照片/视频的人工视觉抽查；自动化覆盖保存、方向、详情和编辑元数据。
- 全量真机没有自然跑完；视频/相册之后的部分套件依靠补充运行和模拟器结果，不能宣称“所有真机测试通过”。

## 本轮代码变化

只撤回了一个会造成慢动作后台恢复回归的清理：

```text
不再在 setVideoMode(false) 时清空 requestedVideoSettings.captureFrameRate
```

没有修复上述功能问题；报告仅记录。
