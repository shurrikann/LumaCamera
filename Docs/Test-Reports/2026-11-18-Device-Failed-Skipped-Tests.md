# 2026-11-18 真机失败/跳过用例复测

## 2026-11-19 归因复核

134 项是计划范围。压缩原始日志中能逐项数到 122 个测试结果，84 通过、26 失败、12 跳过。其余 12 项在该日志中没有对应的完成记录。另一个压缩日志包含针对其中 3 个失败的独立复跑，三项都通过。

报告列出的 13 项视频相关失败具有共同的前置条件问题。用例直接调用 `setCaptureKind(.video)` 后立刻读结果，有的甚至从未启动相机。当前代码会在相机就绪后才执行切换。视频 HUD 那次记录到的仍是相机的照片画幅，录制控件用例也读到了照片 A/M 控件。这批断言需要先验证实际进入了视频，再校验各自的规格、持久化与布局行为。原始失败记录保留。

| 原先未归因的用例 | 当前判断和证据 |
| --- | --- |
| 星空自动 ISO | 旧日志中目标约 ISO 57，设备实际约 ISO 57，成片 EXIF 按源 RAW 数据记录为 50 或 64。实测最大差约 0.19 EV。复跑三次目标和设备读数均为 54，EXIF 均为 50，拍摄时长与文件均为 0.5 秒，本轮断言通过。应继续区分目标、传感器读数和文件记录值。 |
| 星空参数弹窗遮挡 | 复跑仍在打开用于遮挡检查的弹窗前失败。用例按 UIKit 命中视图的父级寻找 `AVCaptureVideoPreviewLayer`，该扫描未返回任何可用起点，因此原断言无法判断弹窗是否透传。 |
| 滤镜列表与收藏 | 收藏恢复及列表一致性断言没有失败。唯一失败是把总数写死为 46，当前产品有 252 个导入条目和 3 个内建选项，共 255 个。 |
| M9 参考色 | 旧测试仍以导入表的原始字节作为 sRGB 屏幕输出期望，当前 SDR 色表显式使用 Rec.709，输出经过色彩管理。CPU 与 GPU 复现相同偏差。当前资源及管理色彩测试通过，其中包含 M9 的样本；原先偏差最大的色块没有逐一做新的参照转换。 |
| M 挡 ISO/快门 | 原批次确实有一次手动设置后设备仍回报约 ISO 687、0.030005 秒，随后两组手动值正确。原失败读的是设备取景参数，M 挡当段未拍文件；该条不能证明 M 挡文件 EXIF 错误。复跑原测试第一组读回 ISO 99.98、0.016659 秒。另一次独立真机成片测试读到设定的 ISO 100/1 秒及 ISO 200/0.25 秒。仍需防范 A→M 首次调整的偶发时序。 |
| HEIF Pro 测光范围 | 原始日志是切向视频时仍读到 global/spot，代码和用例均说明相机未就绪时仍留在照片。真机另测全局测光实际产生补偿，切普通格式后清零，回 HEIF Pro 恢复已选方式，点测光也通过。归入旧前置条件。 |
| 48MP 固定焦段入口 | 原用例及复跑均在切 M 挡和选择 48MP **之前**，寻找常规照片界面的 UIKit 按钮时中断。真机另测 0.5×、1×、4× 四次切换均选中且就绪。独立成片测试验证 6 种格式，JPEG/HEIF/TIFF/HEIF Pro/RAW+JPEG 主文件为 6000×8000，DNG 为 8064×6048。尚未用正确的 UI 测试工具复验全部画幅和每颗镜头的成片。 |
| 前置录制变焦 | 现行普通前置视频使用固定超广角，前置焦段切换和常规变焦轮有明确门禁。旧用例仍要求按钮可选、变焦轮能改变倍率，按现规则会失败。复跑实际生成可解码的 55 帧视频，取景路线稳定。 |
| 前置视频广角按钮背景 | 旧用例要求在普通前置视频中互切两档，其前提已失效。复跑在等待前置时中断，未走到背景断言。独立现行路线用例验证前置照片标准取景进入视频后硬件使用固定超广角，退出视频恢复照片取景倍率；旧用例的等待超时不能等同于黑屏。 |
| 虚拟光圈 | 唯一失败是照片详情仍期待“虚拟光圈”，当前文案为“星芒”。射线能量、均匀区域、微小高光及 EXIF 数值解析均通过。 |

12 个跳过中，8 个需要显式诊断配置或现场配合，2 个慢门用例未获得所需的实时采集路线，1 个因当前镜头未声明 Open Gate，另 1 个是已被现行 Rec.709 测试替代的旧色表用例。跳过不计入通过。定向复跑使用 iPhone 17 Pro / iOS 27.2.1，测试产物未写入系统相册。

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
