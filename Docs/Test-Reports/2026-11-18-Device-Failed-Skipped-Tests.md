# 2026-11-18 真机失败/跳过用例复测

## 环境

```text
设备：iPhone 17 Pro
系统：iOS 27.2.1
UDID：00008150-001934280220401C
测试范围：上一轮模拟器失败与跳过共 134 项
执行方式：xcodebuild test，串行
```

原始日志：

```text
Assets/2026-11-18-Device-Tests/LumaDeviceFailedTests.log.gz
Assets/2026-11-18-Device-Tests/LumaDeviceIsolatedRerun.log.gz
```

## 汇总

```text
134 项
通过：84
失败：26
跳过：12
```

失败中 3 项已修复并单独复跑通过：

```text
AstroSharedRawStackPhysicalTests
- testSharedSessionLightenTrails
- testSharedSessionRawStackProduces12MP
原因：前序镜头残留，测试未固定后置主广角
修复：测试开始前选择后置 1x 主广角
复跑：4032×3024，10/30/60 帧通过

SlowShutterPresetTests
- testSlowShutterAllowsSwitchingRearLenses
原因：userSwitchFrameID 在虚拟多摄路径可为空
修复：校验 selectedLens/ready/慢门状态和预设保持
复跑：通过
```

剩余 23 项。

## 明确为旧测试前置条件（13）

共同原因：模型未启动相机/未等待模式切换时直接调用 `setCaptureKind(.video)`。当前实现会等待 `camera.ready`，因此测试仍停在照片模式。

```text
CameraViewModelTests
- testVideoModeReturnsToPhotoRatioAndRememberedManualSettings

CaptureStatePersistenceTests
- testAllCaptureChoicesAndManualFlagsSurviveModelRecreation
- testDisabledUsesRequestedPhotoAndVideoDefaultsAndRetainsPreferences
- testIndependentVideoModePersistsWhilePhotoIsSelected
- testPhotoManualExposureSurvivesVideoClampAndModelRecreation

VideoWorkflowTests
- testCinematicResolutionAndFrameRateCanBeSelectedAsApplePairs
- testPhotoFilterLookAndEditsAreAvailableOnlyForSDRAndP3Video
- testTimeLapsePresetsSchedulerAndModeStability
- testVideoSubmodeSwitchesAreExclusiveAndKeepOnlySupportedSettings

CompactFilterDialTests
- testAllParametersStayReachableAndVideoRetainsSavedEditorStyle

VideoOverlayLayoutTests
- testHUDAndHistogramStayInsideEveryVideoRatioAndFrameRatePopupFits

VideoMacroIndicatorTests
- testRecordingControlsKeepPositionsAcrossRatiosAndRotation

VideoSelectionCompatibilityTests
- testPresetsUseExactCaptureRateAndCinematicZoomRange
```

这些不直接代表用户可见回归；需要把测试改为启动相机并等待视频模式生效后复跑。

## 尚未归因（10）

```text
AstroFiveFixesPhysicalTests
- testAutoISOMeteringLocksCaptureShutterAndEV
  症状：自动 ISO 目标约 57，实际 50/64，超出约 1/3 档容差

AstroModeHandoffPhysicalTests
- testParameterPanelOccludesPreviewAndShutterControlsCapture
  症状：找不到可命中的预览点，遮挡断言未完成

CameraFilmProfileTests
- testImportedCatalogAndFavoritesSurviveReload
  症状：读取值 255，期望 46

FilmColorLUTTests
- testM9ReferencePNGCoordinatesSurviveConversionAndColourManagement
  症状：多个参考色偏约 10 个色阶

GlobalMeteringPhysicalTests
- testDeviceBiasReadoutAndCapturedEXIF
  症状：M 挡设置 ISO 100 / 1/60，实际读回约 ISO 687 / 1/30

HEIFProMeteringScopeTests
- testOnlyPhotoHEIFProUsesSelectedMeteringAndRetainsSelection
  症状：选择 global/spot，实际仍为 system

HighResolutionFixedFocalTests
- testFixed48MPRoutesFilesAndAdaptiveStripAcrossModesAndRatios
  症状：找不到对应焦段的 48MP UIButton

PresetToolbarPhysicalTests
- testFrontRecordingZoomChangesHardwareAndDecodes
- testFrontVideoWideSelectionHasNoBackground
  症状：前置广角/录制切镜失败或状态不一致

VirtualApertureTests
- testContinuousRangeHighlightRaysAndUniformAreas
  症状：连续光圈高光射线/均匀区域断言失败
```

## 可能的使用影响

```text
P0 M 挡 ISO/快门可能被自动测光覆盖，实际曝光与 EXIF 不一致
P0 某些镜头/画幅下 48MP 入口可能缺失
P0 前置视频广角或录制变焦可能失败/黑屏

P1 HEIF Pro 全局/点测光可能不生效
P1 胶片 LUT/导入配置颜色偏差
P1 虚拟光圈高光形状异常

P2 星空自动 ISO 约 1/3 档偏差
P2 星空参数面板遮挡无法确认
P2 视频 HUD 未显示或位置异常
```

## 限制

- 上述 10 项尚未逐项手测，不能仅凭测试断言确认全部用户可见。
- 13 项旧测试未改写为通过，仍是红灯。
- 测试使用独立测试进程，未写入用户系统相册。
