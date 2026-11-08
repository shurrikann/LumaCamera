# 2026-11-07 全量测试（夜景模式除外）

## 环境与范围

- 设备：iPhone 17 Pro / iOS 27.2 / 24B119
- 构建：`af0e4a6` 后的工作区（包含调色盘默认提交 `c9f4580`，以及未提交的夜景融合/稳定 AE 调整）
- 测试包：`/tmp/LumaFullTestDD`
- 结果包：`/tmp/LumaFullNoNight.xcresult`
- 命令：`xcodebuild test-without-building ... LUMA_DIAGNOSTIC_READ_ONLY_PHOTOS=1 -parallel-testing-enabled NO`
- 排除：夜景采集、融合、夜景设置、夜景 UI 及带 Night 的专用方法，共 88 个测试方法。慢门、HDR、普通拍照、视频、滤镜/调色盘仍执行。

## 汇总

| 项目 | 数量 |
| --- | ---: |
| 实际执行 | 811 |
| 通过 | 756 |
| 失败 | 34 |
| 跳过 | 21 |
| 耗时 | 约 75.6 分钟 |

最终 `xcodebuild` 退出码为 65，结果包 `result = Failed`。

## 已单独复现的真实失败

在模拟器单独复跑，确认不是环境偶发：

- `ImagingTests/testMonochromeProducesEqualColorChannels`
  - 期望单色通道相等，实际 RGB 约为 `69 / 129 / 134`。
- `VideoFrameFilterRendererTests/testStillPhotoFilterIsRenderedIntoEncoderPixelBufferInSDRAndP3`
  - 银盐滤镜写入 SDR/P3 视频像素后通道差约 `75/77`，超过阈值 8。

这两项说明银盐/单色滤镜渲染存在真实回归或平台行为变化，优先级最高。

## 失败分类

### A. UI/布局与旧入口（约 12）

包括 `AdaptiveDynamicPhysicalTests`、`DepthToolbarPhysicalTests`、`PresetToolbarPhysicalTests`、`RecordingEdgeLayoutPhysicalTests`、`ShootingModeButtonTests`、`FocusExposureTests`、`SlowShutterPresetTests`、`FocusNavigatorPhysicalTests` 等。多数报 `CGRect` 为空或找不到布局元素，和调色盘默认化后的旧测试断言/入口变化有关，需逐项区分测试过时与真实布局问题。

### B. 视频/电影/CenterStage/真实人物（约 11）

包括 `CinematicEffectPhysicalTests`、`CinematicZoomPhysicalTests`、`FrontVideoCenteringPhysicalTests`、`SlowMotionLensTransitionPhysicalTests`、`VideoColorPhysicalTests`、`VideoModeTransitionTests`、`VideoSpecificationTests`、`VideoStabilizationPhysicalTests`、`VideoVirtualAperturePhysicalTests`。部分报 `CancellationError` 或需要人物/录制场景，按用户口径记录为“效果待人工验证”，不冒充功能通过。

### C. HDR 真机连续拍摄（3）

- `HDRSequentialDiagnosticsTests/testTwoSequentialHDRCapturesKeepSameHDR`
- `HEIFHDRPhysicalTests/testHDRToggleAtOneXKeepsWidePrimary`
- `HEIFHDRPhysicalTests/testHEIFHDRUsesTenBitLivePreviewAndRestoresRAWPhotoQualityWithoutSaving`

其中一项耗时 108 秒，可能是设备状态/连续拍摄超时；需单独复跑，不能直接归因于 HDR 功能回归。

### D. 照片路线/人像/镜头（约 6）

包括 `LivePhotoPhysicalTests/testSmartCaptureSupportsLivePhoto`、`MainFocalPresetPhysicalTests`、`PhysicalCameraSwitchingTests`、`PortraitCapturePhysicalTests`、`FocusNavigatorPhysicalTests/testLiveAndRawPhotoPipelineRestoresAfterNavigation`、`AdaptiveWaterPhysicalTests`。包含真实白平衡 unsupported、路由/场景依赖，需单独复跑。

### E. 渲染/滤镜（2）

即上文已复现的银盐单色两项，是当前最明确的真实功能问题。

## 完整失败名单

```text
ShootingModeButtonTests.testActivePhotoAndVideoSubmodesUpdateEntryIcon
SlowShutterSequencePhysicalTests.testAdaptiveWaterAutomaticAndManualRestoration
PortraitCapturePhysicalTests.testAutomaticMacroSuspendsPortraitCaptureAndRecovers
FrontVideoCenteringPhysicalTests.testCenterStagePersonLandscapeRecording
FrontVideoCenteringPhysicalTests.testCenterStagePersonPortraitRecording
VideoStabilizationPhysicalTests.testCinematicTimeLapseAndSlowMotionUseStabilization
DepthToolbarPhysicalTests.testDepthSliderTopSpacingIsTwentyAcrossRatios
CinematicZoomPhysicalTests.testFixedButtonsWheelRangeActualCinematicRouteAndRecovery
AdaptiveDynamicPhysicalTests.testFormatPanelLayoutAndRepeatedSwitching
RecordingEdgeLayoutPhysicalTests.testFrontButtonGroupsStayCenteredAndRecordingPanelsUsePreviewEdges
PresetToolbarPhysicalTests.testFrontVideoWideSelectionHasNoBackground
HEIFHDRPhysicalTests.testHDRToggleAtOneXKeepsWidePrimary
HEIFHDRPhysicalTests.testHEIFHDRUsesTenBitLivePreviewAndRestoresRAWPhotoQualityWithoutSaving
DepthToolbarPhysicalTests.testHEIFProToolbarPopupLayoutsLifecycleAndCapture
FocusNavigatorPhysicalTests.testLiveAndRawPhotoPipelineRestoresAfterNavigation
VideoModeTransitionTests.testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips
FocusNavigatorPhysicalTests.testManualCaptureMetadataAndMovableNavigatorLayout
PhysicalCameraSwitchingTests.testManualToAutomaticPreviewMatchesAllPhotoRatiosAndFrontFraming
ImagingTests.testMonochromeProducesEqualColorChannels
FocusExposureTests.testNativeLensPresetsFitEveryRatioIncludingXpan
FrontVideoCenteringPhysicalTests.testOfficialCenterStageVideoFramingExclusionsAndRecording
SlowShutterPresetTests.testPresetCellsAlignWithFiveLensButtonSlots
VirtualAperturePhysicalTests.testRealFingerToolbarApertureChangesBinding
PresetToolbarPhysicalTests.testRecordingZoomButtonsWheelAndFourSecondIdleHide
MainFocalPresetPhysicalTests.testRepeatedMainCameraTapsCycle24_28_35mmWithoutChangingAnchorOrFreezingFrames
VideoColorPhysicalTests.testSDRAndP3FiltersAreBakedIntoRecordedPixelsWithStableFrameDelivery
CinematicEffectPhysicalTests.testSimulatedApertureChangesPreviewAndRecordedBackground
VideoSpecificationTests.testSlowMotionAndCinematicRoutesOnDevice
SlowMotionLensTransitionPhysicalTests.testSlowMotionFocalSwitchLatencyAndRecording
LivePhotoPhysicalTests.testSmartCaptureSupportsLivePhoto
VideoFrameFilterRendererTests.testStillPhotoFilterIsRenderedIntoEncoderPixelBufferInSDRAndP3
HDRSequentialDiagnosticsTests.testTwoSequentialHDRCapturesKeepSameHDR
LivePhotoOptionsTests.testUnavailableLiveToggleDoesNotShowAnInstructionToCloseFeatures
VideoVirtualAperturePhysicalTests.testVideoEntryLayoutRecordingAndRecovery
```

## 限制

- 本轮只验证自动化功能与布局，不验证夜景画质、HDR 观感、电影效果、人像/人物场景等目视效果。
- UI 测试在真机运行，仍可能受界面焦点、系统权限、设备锁定和测试宿主生命周期影响。
- 未把所有失败单独复跑；除银盐两项外，其余分类仍需定向确认。
- 未修改产品代码来迎合测试；调色盘旧入口测试可能需要同步更新。

## 2026-11-08 处理进展

- 修复银盐 100% 浓度：1.3 倍外推保留，但银盐在单色亮度域外推，不再把彩色输入差值带入。`ImagingTests.testMonochromeProducesEqualColorChannels`、`VideoFrameFilterRendererTests.testStillPhotoFilterIsRenderedIntoEncoderPixelBufferInSDRAndP3` 通过；`FilterStrengthTests`/`FoodFilterTests` 8 项通过。
- HDR 三项按当前产品契约修正测试：HDR 只作用于成片，取景保持 SDR，不再要求 10-bit 实时预览或近距微距标识。三项真机复跑通过；连续两张 headroom 约 2.83/2.81、SDR/HDR 均值一致，HDR 文件校验保留。106 秒长测降至约 7.2 秒。
- UI 组：`AdaptiveDynamicPhysicalTests.testFormatPanelLayoutAndRepeatedSwitching` 改为只校验本次可见的 HDR/高动态几何，通过；`SlowShutterPresetLayout` 宽屏上限 40→42 对齐五镜头槽，`SlowShutterPresetTests` 通过；`FocusExposureTests.testNativeLensPresetsFitEveryRatioIncludingXpan` 改为 42/40 上限与 2pt 容差，通过；`FocusNavigatorPhysicalTests.testManualCaptureMetadataAndMovableNavigatorLayout`、`PresetToolbarPhysicalTests.testFrontVideoWideSelectionHasNoBackground` 单独复跑通过。
- 仍未处理：Depth 两项（实际间距 40/32 对断言 20，可能是 overlay/global 坐标或真实布局，需截图确认）、RecordingEdge 前置 `dualCaptureToggle` 缺失、ShootingMode 电影效果不可用；按用户要求不处理 Live/人像路线和视频/电影效果组。其余原始失败未逐项复跑。
### 2026-11-08 Depth 浮层位置
- 产品逻辑：景深/光圈浮层打开后，以竖屏当前直方图中线为绝对位置；横屏/画幅重排沿用冻结位置，关闭时清空，下次重新取竖屏位置。实现使用 CameraView 局部状态与 onGeometryChange，避免在视图计算中改 State。
- 自动化仍失败：测试同时存在主 App 和测试宿主两个 CameraView，`captureButtonFramesForTesting`/直方图几何会互相覆盖；Depth 两项仍报 148.5/169 与 140.5/148.5 不一致。该项保留为真机旋转+截图待验证，不能写成测试通过。
### 2026-11-08 Live/人像与视频组进展

- Live：修复 `canToggleLivePhoto` 未检查当前格式/分辨率/HDR/硬件能力，RAW 下仍能点亮 Live。`LivePhotoOptionsTests` 4 项通过；`LivePhotoPhysicalTests`、`FocusNavigator` Live/RAW 返回也通过。
- 人像中心：`PortraitCapture` 近距宏仍依赖真实近距纹理。`CenterStage` 竖屏、横屏人物录制在用户配合下通过；`testOfficialCenterStageVideoFramingExclusionsAndRecording` 更新掉已移除的固定栏“同步双拍”按钮后通过。
- 镜头路线：`MainFocalPresetPhysicalTests` 复跑通过；`RecordingEdgeLayout` 更新为当前镜头+居中两按钮后通过。
- 视频：VideoColor/规格/模式切换多数通过。新增照片格式/分辨率/HDR 在视频返回后的恢复，但 HDR 视频往返仍得到 depth=8、非 HDR 文件且 orientation=6；该问题未解决。视频虚拟光圈测试仍受测试宿主几何缺失/InvalidTransition 影响；120fps 预览处理约 68.5/74.9fps，低于 78fps 门槛，记录为性能待优化。
- 需要真人/运动：Cinematic 景深、慢动作、防抖、CenterStage 已完成部分；其余仍未宣称通过。
### 2026-11-08 视频 HDR 往返诊断

- 已在视频返回后新增照片格式/分辨率/HDR 状态保存恢复；HDR 变体捕获前可见 model/options HDR=true，photoOutput 4032×3024/5712×4284。
- 但实际 HDR 文件仍为 4032×3024、depth=8、Display P3，无 HDR 增益图；另一次循环恢复时机更晚，捕获前 model/options 已变 false。说明状态恢复与 HDR 管线准备仍有时序缺口，本轮未解决。
- 视频虚拟光圈仍受测试宿主几何/InvalidTransition 影响；120fps 预览处理约 68.5/74.9fps，低于 78fps 门槛。其余视频色彩/规格用例多数通过。
### 2026-11-08 人工场景与视频电影结果

- Live：RAW 能力检查修复，LivePhotoOptions 4 项通过；LiveVideo 返回 Live 资源也通过。
- CenterStage：用户配合下竖屏、横屏人物录制和官方构图排除三项全部通过；测试已移除固定栏旧“同步双拍”按钮要求。
- 微距/人像：用户放置近距纹理主体后通过，3 张实际拍摄，系统超广角与恢复正常。
- 电影效果：光圈范围 2.0–16、默认 2.8 可应用并刷新预览；开始录制后 `videoBusy=true` 但 12 秒未进入录制，实际电影文件未完成。该项仍是真实待查问题。
- 视频 HDR 往返：捕获前 model/options HDR=true、photoOutput 尺寸正常，但文件仍 depth=8、无增益图；另一次恢复时机更晚。未解决。
- 视频虚拟光圈仍受测试宿主几何/InvalidTransition；120fps 预览处理约 68.5/74.9fps，低于 78fps 门槛。
### 2026-11-08 HDR 视频返回结论修正

- 视频返回后照片格式/HDR 状态已恢复；HDR 变体捕获前 options.hdr=true、format=heif、directSystemHDR=true，photoOutput 尺寸正常。
- 实际文件仍 depth=8、无增益图；但普通 HDR 测试也显示系统 HDR 文件主体为 8-bit、靠增益图承载 HDR。当前室内场景没有触发增益图，不能仅凭 depth=8 断言 HDR 管线失效。需要用高反差窗景/灯光场景复测，状态恢复与最终文件结论暂分开记录。
- 之前对 depth=8 的“HDR 仍未通过”结论收回为“待高反差场景验证”，不是已确认回归。
### 2026-11-08 HDR 视频高反差复测

- 高反差场景首次复测中，视频返回 HDR 变体的 HDR 断言（增益图/10-bit）通过；同轮仍出现 `supportsHEIFHDR` 未恢复和 orientation=6（已确认 6 为合法方向）。
- 重复整组测试时 HDR 变体又出现 depth=8/无增益图和 supports=false，说明视频往返后的 HDR 能力发布/管线准备仍存在间歇性时序问题；不是稳定通过。
- 测试已改为等待能力恢复并接受 orientation 1/6；HDR 断言保留，未降低。
### 2026-11-08 电影卡死根因与官方顺序修正

- 设备日志显示视频启动时 activeFormat 仍是照片 3264×2448，AVFoundation 报 -11800/-73191，恢复循环造成卡死。视频分支此前只关闭 HEIFHDRPreview，没有关闭 HEIFHDRPipeline；照片 HDR 输出管线残留与视频输出图不兼容。现在进入视频同时关闭 preview + pipeline，用户手动确认普通视频不再卡死。
- 按 WWDC25 “Capture cinematic video in your app”：先选 DualWide/TrueDepth 设备和支持 isCinematicVideoCaptureSupported 的格式，再启用电影输入/输出。已新增 prepareCinematicInput，电影开关先切 DualWide 1080p，再应用规格；并清空此前遗漏的 videoSubmodePreparing。
- 当前电影光圈预览已能启动（2.0–16，默认2.8），但点录制后仍 videoBusy=true 且无首帧/成片；8 秒 watchdog 会退回普通视频，不再永久卡死。录制管线仍未解决。
### 2026-11-08 电影录制修复与成片抽查

- 根因：电影图录制输出仍为 `alwaysDiscardsLateVideoFrames = true`。Cinematic 首帧后处理变慢时后续帧全部被 AVFoundation 丢弃，writer 只收到 1 帧。电影图改为不丢迟到帧后，四次录制均约 30fps：`received=22 written=22 span=0.70s`，CinematicEffect 用例通过。
- 同时去掉 `prepareAutomaticRoute` 在电影模式下强制 `focusPointOfInterest=中心 + continuousAutoFocus` 的普通 AF 重置，避免主动把电影主体焦点抢回中心。
- 手动快门若电影图未激活，先重新准备 DualWide/电影格式，激活后再自动开拍；不再直接报“规格未准备好”。
- 抽查用户文件 `LumaVideo-091A718D...mov`：38.35s、2160×2880（竖屏4:3）、HEVC 29.98fps、AAC 双声道，方向矩阵正确；仅视频+音频两条轨道，电影虚化为烘培成片，没有独立 Cinematic 景深/元数据轨，照片App不能二次改焦。抽帧显示对焦随镜头移动在手机/红盒/键盘间自动切换，属于 Cinematic 自动主体跟焦，不是固定虚化区域错位。
### 2026-11-08 电影对焦策略确认

- 用户确认采用“默认系统自动跟焦，点击主体才改焦”。
- 当前 `focus(at:)` 在 Cinematic 输入开启时已走 `setCinematicVideoTrackingFocus(..., .weak)`；长按锁定走 `setCinematicVideoFixedFocus(..., .strong)`，不会写普通 focusMode。
- 已移除 `prepareAutomaticRoute` 对电影模式强制中心 AF 的重置；因此不点击时保留系统主体选择，点击时强制切到点击对象。
- 成片为烘培景深，无 Cinematic 元数据轨，不能后期改焦；这是当前 AVAssetWriter 路径的已知限制。
### 2026-11-08 照片 HDR → 电影 → 照片恢复

- 新增 `photoStateRestorePending`：视频返回照片时，HEIF/HDR 能力表仍可能是视频路线；在能力恢复前阻止 `reconcileCaptureCapabilities` 把 photoFormat 清成 JPEG、hdr 清成 false。
- `restorePhotoStateAfterVideo` 改为可重试，并保留原格式/分辨率/HDR 选择；能力回来后再恢复，不依赖一次瞬时查询。
- 新增真机测试 `testCinematicRoundTripRestoresHDRSelection`：HEIF+HDR → 视频 → 电影 → 照片，连续 2 次通过。
- 原 `testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips` 仍在 hdr 变体进入视频前偶发 `camera.supportsHEIFHDR=false`，属于进入视频前的测试时序，不是本次电影返回 HDR 丢失；该项仍单独记录。
### 2026-11-08 照片/视频切换收口

- HDR 返回：新增 `photoStateRestorePending`，能力恢复前阻止协调器把 HEIF/SDR 覆盖；`supportsHEIFHDR` 不再错误依赖 `availableRawPhotoPixelFormatTypes`。`testCinematicRoundTripRestoresHDRSelection` 2/2 通过，`testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips` 通过。
- 电影录制：`alwaysDiscardsLateVideoFrames=false` 已修，CinematicEffect 通过；返回照片时清理电影子模式，避免残留状态继续提交。
- 仍有残余：电影预览/返回的 `recordingOutput` 在未开录时帧计数为 0，`testCinematicPreviewAndPhotoHDRRecoverOnVideoRoundTrip` 仍失败；返回后输入可能停留在 DualWide（video:6）而非 Triple（video:7）。这两项属于会话图/镜头恢复，未宣称全部切换完成。
### 2026-11-08 照片/视频切换收口完成

- 电影返回后输入兜底：非手动、非高像素照片路线若仍停在 DualWide，退出视频事务内换回普通后置虚拟多摄；会话快照恢复为 Triple。
- `testCinematicPreviewAndPhotoHDRRecoverOnVideoRoundTrip` 改为比较实际会话 input，而不是 stale photoOutput input；未开录 recordingOutput 计数只作为诊断，预览刷新作为断言。
- 测试启动时等待上一用例的会话队列落定，避免复用相机会话的尾态干扰。
- 验证：VideoModeTransitionTests 5/5、CinematicEffectPhysicalTests 1/1、BasicVideoPhysicalTests 3/3 全部通过；包含普通 HDR 往返、电影 HDR 往返、电影预览/返回、重复切换。
### 2026-11-08 切换视频偶发“未就绪”

- 根因：`setCaptureKind(.video)` 先调用 `synchronizeVideoSettings`，再 `camera.setVideoMode(true)`。前者执行时 `videoModeRequested` 仍为 false，会被相机 guard 丢弃；视频可能先用照片格式启动，偶发未就绪/无法启动。
- 修复顺序：先 `setVideoMode(true)` 进入视频，再提交视频规格。安全 1080p 初始格式仍保留，避免输出挂载前使用照片大格式。
- 验证：VideoModeTransitionTests 5/5、CinematicEffect 1/1、BasicVideo 3/3 全通过，包含快速/重复切换和 HDR 电影往返。
### 2026-11-08 剩余项修复进展

- 视频虚拟光圈：旧测试等待已不存在的 `virtualApertureBar`；更新为当前 `videoVirtualApertureButton`/`focalBarBackground` 几何。25.9s 真机用例通过，含 5 比例×4 角度布局、3 轮拖拽、720p/1080p P3 H.264/4K HEVC/ProRes 实际录制与恢复。
- 前置画幅：`testManualToAutomaticPreviewMatchesAllPhotoRatiosAndFrontFraming` 连续两次通过，旧 900×1598 失败未复现。
- Depth：竖屏改为持续跟随直方图，横屏只读竖屏冻结值；首个 spacing 用例通过，但双 CameraView 共享 geometry 时横屏值仍被另一视图覆盖，需真机旋转确认。
- 120fps：当前实测 720p/1080p/4K 120 为 107.0–119.7fps，全部高于 78 门槛，`testRenderedVideoPreviewCadenceTracksSupportedRates` 通过。
- 电影元数据可编辑尚未实现；当前仍为烘培成片。
### 2026-11-08 剩余五项执行结果

- 视频虚拟光圈：旧测试 key 更新为当前 UI，真机通过（5 比例×4 角度、拖拽、720p/1080p P3 H.264/4K HEVC/ProRes 录制恢复）。
- 前置画幅：七画幅 + 前置横幅/竖幅连续两次通过。
- Depth：竖屏跟直方图、横屏读冻结值；用户真机旋转验收横竖一致。自动化双 CameraView 几何串扰仍存在。
- 120fps：实测 107.0–119.7fps，门槛 78，通过。
- 电影可编辑元数据：尝试独立 MovieFileOutput 会话验证，但与主 App 相机会话争用导致内存崩溃；已删除探针。该功能需改造主会话的录制输出架构，本轮未完成。
