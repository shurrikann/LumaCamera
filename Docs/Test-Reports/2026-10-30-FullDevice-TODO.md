# 2026-10-30 真机全量问题清单

736项：641通过、82失败、13跳过。以下每项对应一个失败方法，保留运行顺序、日志证据和定向测试入口。本轮未修改代码或重跑失败项。

[总报告](2026-10-30-FullDevice.md) · [全部状态、断言和指标](2026-10-30-FullDevice-results.json)

## 优先排查

1. IOSurface内存分配失败、像素缓冲创建失败及视频虚拟光圈期间的宿主异常退出。
2. 连续运行的照片回调/解码编码失败、慢门逐帧合并失败。
3. 失败保存队列累积至4张后阻止后续拍摄，补齐测试清理与迟到回调归属核对。
4. 实际50/60/120fps视频文件帧率不达标。
5. 人像切换后HEIF Pro回落、设置记忆、自动取景重复触发及布局断言。


## 逐项记录

### FULL-20261030-001

**AdaptiveWaterComposerTests/testHandheldAlignmentPreservesStaticDetailAndRejectsUnrelatedFrame**

- [x] P2 · 帧筛选；2026-11-01专项真机通过。全量顺序第12项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 0.481 秒。

- 定向入口：`LumaCameraTests/AdaptiveWaterComposerTests/testHandheldAlignmentPreservesStaticDetailAndRejectsUnrelatedFrame`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L538。

- L559：`XCTAssertEqual failed: ("5") is not equal to ("4")`

- L560：`XCTAssertEqual failed: ("0") is not equal to ("1")`

- 源码位置：[AdaptiveWaterComposerTests.swift:83](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/AdaptiveWaterComposerTests.swift:83)。



### FULL-20261030-002

2026-11-01：本项定向真机通过，关联共12方法全部通过；[修复、指标和边界](2026-11-01-Other-Six-Fixes.md)。以下原失败记录保留。

**AutomaticLensStabilityPhysicalTests/testAutomaticModeUsesSystemVirtualCameraCandidatesAndWheelRetainsFullRange**

- [x] P1 · 会话／路由恢复；待定位。全量顺序第25项。

- 耗时 8.468 秒。

- 定向入口：`LumaCameraTests/AutomaticLensStabilityPhysicalTests/testAutomaticModeUsesSystemVirtualCameraCandidatesAndWheelRetainsFullRange`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L599。

- L621：`XCTAssertTrue failed`

- L623：`XCTAssertNotNil failed`

- L644：`XCTAssertEqualWithAccuracy failed: ("1.0") is not equal to ("0.5") +/- ("0.01")`

- L649：`XCTAssertEqualWithAccuracy failed: ("1.0") is not equal to ("2.0") +/- ("0.01")`

- L652：`XCTAssertEqualWithAccuracy failed: ("1.0") is not equal to ("4.0") +/- ("0.01")`

- 原始共45条断言/异常，去重后8类；完整证据见JSON。

- 源码位置：[AutomaticLensStabilityPhysicalTests.swift:130](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/AutomaticLensStabilityPhysicalTests.swift:130)。



### FULL-20261030-003

**AutomaticWhiteBalanceExposureTests/testAutomaticWhiteBalanceRemainsAutomaticDuringManualISOSweep**

- [ ] P2 · 曝光／白平衡／锁定恢复；待定位。全量顺序第29项。

- 耗时 9.531 秒。

- 定向入口：`LumaCameraTests/AutomaticWhiteBalanceExposureTests/testAutomaticWhiteBalanceRemainsAutomaticDuringManualISOSweep`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L832。

- L871：`XCTAssertEqualWithAccuracy failed: ("6655.2001953125") is not equal to ("7680.0") +/- ("153.6")`

- 源码位置：[AutomaticWhiteBalanceExposureTests.swift:51](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/AutomaticWhiteBalanceExposureTests.swift:51)。



### FULL-20261030-004

**BasicVideoPhysicalTests/testRepeatedVideoRecordingsAndPhotoModeReturn**

- [x] P2 · 录音期间触感许可；2026-11-01专项真机通过。全量顺序第34项。

- 最新验证：[视频六项专项](2026-11-01-Video-Six-Fixes.md)，最终三批9方法全通过，包含真实人物横竖录像；原失败日志保留。

- 耗时 8.615 秒。

- 定向入口：`LumaCameraTests/BasicVideoPhysicalTests/testRepeatedVideoRecordingsAndPhotoModeReturn`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L1005。

- L1044：`XCTAssertTrue failed`

- 源码位置：[BasicVideoPhysicalTests.swift:247](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/BasicVideoPhysicalTests.swift:247)。



### FULL-20261030-005

**BurstCapturePipelineTests/testHeldBurstShutterOnDeviceStopsCleanlyWithoutSavingToPhotos**

- [ ] P2 · 拍摄／交互状态；待定位。全量顺序第40项。

- 耗时 6.313 秒。

- 定向入口：`LumaCameraTests/BurstCapturePipelineTests/testHeldBurstShutterOnDeviceStopsCleanlyWithoutSavingToPhotos`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L1093。

- L1115：`XCTAssertTrue failed`

- L1117：`XCTAssertGreaterThan failed: ("0") is not greater than ("0") - Each held shutter interval should capture at least one frame`

- 原始共3条断言/异常，去重后2类；完整证据见JSON。

- 源码位置：[BurstCapturePipelineTests.swift:189](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/BurstCapturePipelineTests.swift:189)。



### FULL-20261030-006

**CameraFocalButtonTests/testHostedFocalStripHitTargetsAfterRepeatedSelections**

- [ ] P1 · 实际文件像素；待定位。全量顺序第52项。

- 耗时 22.057 秒。

- 定向入口：`LumaCameraTests/CameraFocalButtonTests/testHostedFocalStripHitTargetsAfterRepeatedSelections`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L1288。

- L1316：`XCTAssertGreaterThan failed: ("7527168") is not greater than ("40000000")`

- 源码位置：[CameraFocalButtonTests.swift:71](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/CameraFocalButtonTests.swift:71)。



### FULL-20261030-007

**CapturePreferencesTests/testFrontMirrorPreferenceAndRealHDRCaptureMetadataWithoutSaving**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第113项。

- 耗时 32.093 秒。

- 定向入口：`LumaCameraTests/CapturePreferencesTests/testFrontMirrorPreferenceAndRealHDRCaptureMetadataWithoutSaving`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L2208。

- L2245：`Asynchronous wait failed: Exceeded timeout of 30 seconds, with unfulfilled expectations: "HDR temporary diagnostic capture".`

- L2246：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 当前镜头不支持 RAW，请选择其他格式。`

- 源码位置：[CapturePreferencesTests.swift:208](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/CapturePreferencesTests.swift:208)。



### FULL-20261030-008

**CapturePreferencesTests/testRAWAttributionAndLocationOffUseCaptureMetadataWithoutSaving**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第118项。

- 耗时 31.351 秒。

- 定向入口：`LumaCameraTests/CapturePreferencesTests/testRAWAttributionAndLocationOffUseCaptureMetadataWithoutSaving`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L2260。

- L2282：`Asynchronous wait failed: Exceeded timeout of 30 seconds, with unfulfilled expectations: "RAW attribution diagnostic".`

- L2283：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 当前镜头不支持 RAW，请选择其他格式。`

- 源码位置：[CapturePreferencesTests.swift:159](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/CapturePreferencesTests.swift:159)。



### FULL-20261030-009

**CaptureStatePersistenceTests/testAllCaptureChoicesAndManualFlagsSurviveModelRecreation**

- [ ] P2 · 设置记忆／格式兼容；待定位。全量顺序第126项。

- 耗时 0.204 秒。

- 定向入口：`LumaCameraTests/CaptureStatePersistenceTests/testAllCaptureChoicesAndManualFlagsSurviveModelRecreation`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L2362。

- L2377：`XCTAssertTrue failed`

- 源码位置：[CaptureStatePersistenceTests.swift:134](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/CaptureStatePersistenceTests.swift:134)。



### FULL-20261030-010

**DepthToolbarPhysicalTests/testHEIFProToolbarPopupLayoutsLifecycleAndCapture**

- [ ] P2 · 设置记忆／格式兼容；待定位。全量顺序第148项。

- 耗时 44.331 秒。

- 定向入口：`LumaCameraTests/DepthToolbarPhysicalTests/testHEIFProToolbarPopupLayoutsLifecycleAndCapture`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L2968。

- L2990：`XCTAssertEqual failed: ("heif") is not equal to ("heifPro")`

- L3027：`XCTAssertTrue failed`

- 原始共6条断言/异常，去重后2类；完整证据见JSON。

- 源码位置：[DepthToolbarPhysicalTests.swift:34](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/DepthToolbarPhysicalTests.swift:34)。



### FULL-20261030-011

**DualCapturePhysicalTests/testEngineDualCaptureRecordingSwapAndOrdinaryRecovery**

- [x] P2 · 双摄相关修正及原方法真机回归通过。全量顺序第162项。

- 耗时 18.664 秒。

- 定向入口：`LumaCameraTests/DualCapturePhysicalTests/testEngineDualCaptureRecordingSwapAndOrdinaryRecovery`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L4920。

- L4953：`XCTAssertTrue failed`

- L5014：`XCTAssertFalse failed - 小窗与声音/容量HUD重叠`

- 原始共4条断言/异常，去重后2类；完整证据见JSON。

- 源码位置：[DualCapturePhysicalTests.swift:242](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/DualCapturePhysicalTests.swift:242)。



- 2026-11-01：双摄专项14方法全通过，25规格真实录制/解码；迟到错误和普通规格恢复修正，入口/HUD按完整页面及最新布局检查。原始失败证据保留。[验证](2026-11-01-DualCapture-Recovery.md)。

### FULL-20261030-012

**DualCapturePhysicalTests/testInactiveDualCaptureEntryIsVisibleInsideLensRegion**

- [x] P2 · 双摄相关修正及原方法真机回归通过。全量顺序第163项。

- 耗时 1.886 秒。

- 定向入口：`LumaCameraTests/DualCapturePhysicalTests/testInactiveDualCaptureEntryIsVisibleInsideLensRegion`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L5041。

- L5067：`XCTUnwrap failed: expected non-nil value of type "CGRect"`

- 源码位置：[DualCapturePhysicalTests.swift:188](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/DualCapturePhysicalTests.swift:188)。



- 2026-11-01：双摄专项14方法全通过，25规格真实录制/解码；迟到错误和普通规格恢复修正，入口/HUD按完整页面及最新布局检查。原始失败证据保留。[验证](2026-11-01-DualCapture-Recovery.md)。

### FULL-20261030-013

**FilterEditorPhysicalTests/testRepeatedFilterEditingResetsAndFormatChangesStayBoundedAndRecover**

- [ ] P2 · 滤镜编辑压力／宿主内存；待定位。全量顺序第178项。

- 耗时 33.119 秒。

- 定向入口：`LumaCameraTests/FilterEditorPhysicalTests/testRepeatedFilterEditingResetsAndFormatChangesStayBoundedAndRecover`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L5313。

- L5335：`XCTAssertLessThan failed: ("654840624") is not less than ("643895992") - Memory retained after closing the editor`

- 源码位置：[FilterEditorPhysicalTests.swift:130](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FilterEditorPhysicalTests.swift:130)。



### FULL-20261030-014

**FocusNavigatorPhysicalTests/testLiveAndRawPhotoPipelineRestoresAfterNavigation**

- [x] P1 · 会话／路由恢复；2026-11-01专项真机通过。全量顺序第212项。

- 最新验证：[长焦导航专项](2026-11-01-FocusNavigator-Fixes.md)，最终13项全通过；原失败日志保留。

- 耗时 30.371 秒。

- 定向入口：`LumaCameraTests/FocusNavigatorPhysicalTests/testLiveAndRawPhotoPipelineRestoresAfterNavigation`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L5610。

- L5632：`failed - 8倍 `

- L5633：`failed: caught error: "CancellationError()"`

- 源码位置：[FocusNavigatorPhysicalTests.swift:169](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FocusNavigatorPhysicalTests.swift:169)。



### FULL-20261030-015

**FocusNavigatorPhysicalTests/testManualCaptureMetadataAndMovableNavigatorLayout**

- [x] P1 · 会话／路由恢复；2026-11-01专项真机通过。全量顺序第213项。

- 最新验证：[长焦导航专项](2026-11-01-FocusNavigator-Fixes.md)，最终13项全通过；原失败日志保留。

- 耗时 20.956 秒。

- 定向入口：`LumaCameraTests/FocusNavigatorPhysicalTests/testManualCaptureMetadataAndMovableNavigatorLayout`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L5635。

- L5776：`failed - 导航 `

- L5781：`failed: caught error: "InvalidTransition { `

- 源码位置：[FocusNavigatorPhysicalTests.swift:95](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FocusNavigatorPhysicalTests.swift:95)。



### FULL-20261030-016

**FocusNavigatorPhysicalTests/testPhotoNavigatorThresholdCaptureAndVideoExit**

- [x] P1 · 会话／路由恢复；2026-11-01专项真机通过。全量顺序第214项。

- 最新验证：[长焦导航专项](2026-11-01-FocusNavigator-Fixes.md)，最终13项全通过；原失败日志保留。

- 耗时 19.295 秒。

- 定向入口：`LumaCameraTests/FocusNavigatorPhysicalTests/testPhotoNavigatorThresholdCaptureAndVideoExit`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L5786。

- L5817：`failed - 照片8倍导航 reason=nil message=nil state=["frames": "0", "session": "true", "pressureCost": "-1.0", "active": "false", "renderSeconds": "0.0", "hardwareCost": "-1.0", "zoom": "12.800000190734863"]`

- L5818：`failed: caught error: "CancellationError()"`

- 源码位置：[FocusNavigatorPhysicalTests.swift:40](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FocusNavigatorPhysicalTests.swift:40)。



### FULL-20261030-017

**FrontVideoCenteringPhysicalTests/testCenterStagePersonLandscapeRecording**

- [x] P1 · 会话／路由恢复；2026-11-01专项真机通过。全量顺序第228项。

- 最新验证：[视频六项专项](2026-11-01-Video-Six-Fixes.md)，最终三批9方法全通过，包含真实人物横竖录像；原失败日志保留。

- 耗时 21.271 秒。

- 定向入口：`LumaCameraTests/FrontVideoCenteringPhysicalTests/testCenterStagePersonLandscapeRecording`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L6203。

- L6227：`failed - 真实手持方向 前置照片宽高比切换失败：Operation Interrupted`

- L6228：`failed: caught error: "CancellationError()"`

- 源码位置：[FrontVideoCenteringPhysicalTests.swift:43](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FrontVideoCenteringPhysicalTests.swift:43)。



### FULL-20261030-018

**FrontVideoCenteringPhysicalTests/testCenterStagePersonPortraitRecording**

- [x] P1 · 会话／路由恢复；2026-11-01专项真机通过。全量顺序第229项。

- 最新验证：[视频六项专项](2026-11-01-Video-Six-Fixes.md)，最终三批9方法全通过，包含真实人物横竖录像；原失败日志保留。

- 耗时 22.949 秒。

- 定向入口：`LumaCameraTests/FrontVideoCenteringPhysicalTests/testCenterStagePersonPortraitRecording`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L6230。

- L6256：`failed - 开始录制 前置照片宽高比切换失败：Operation Interrupted`

- L6257：`failed: caught error: "CancellationError()"`

- 源码位置：[FrontVideoCenteringPhysicalTests.swift:43](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FrontVideoCenteringPhysicalTests.swift:43)。



### FULL-20261030-019

**FrontVideoCenteringPhysicalTests/testOfficialCenterStageVideoFramingExclusionsAndRecording**

- [x] P1 · 会话／路由恢复；2026-11-01专项真机通过。全量顺序第230项。

- 最新验证：[视频六项专项](2026-11-01-Video-Six-Fixes.md)，最终三批9方法全通过，包含真实人物横竖录像；原失败日志保留。

- 耗时 39.077 秒。

- 定向入口：`LumaCameraTests/FrontVideoCenteringPhysicalTests/testOfficialCenterStageVideoFramingExclusionsAndRecording`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L6259。

- L6892：`XCTAssertTrue failed - 相机会话产生运行错误，即使后来自动恢复也不能忽略：["AVFoundationErrorDomain/-11819: Cannot Complete Action"]`

- 源码位置：[FrontVideoCenteringPhysicalTests.swift:156](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FrontVideoCenteringPhysicalTests.swift:156)。



### FULL-20261030-020

**HEIFHDRPhysicalTests/testHEIFHDRUsesTenBitLivePreviewAndRestoresRAWPhotoQualityWithoutSaving**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第276项。

- 耗时 37.795 秒。

- 定向入口：`LumaCameraTests/HEIFHDRPhysicalTests/testHEIFHDRUsesTenBitLivePreviewAndRestoresRAWPhotoQualityWithoutSaving`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L7497。

- L7813：`Asynchronous wait failed: Exceeded timeout of 35 seconds, with unfulfilled expectations: "HEIF HDR full-quality still".`

- L7814：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 照片处理失败：无法编码所选照片格式。`

- 源码位置：[HEIFHDRPhysicalTests.swift:40](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/HEIFHDRPhysicalTests.swift:40)。



### FULL-20261030-021

**Lens48MPAuditTests/test35mmCropHighResolutionAcrossAutomaticAndManualRoutes**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第300项。

- 耗时 50.657 秒。

- 定向入口：`LumaCameraTests/Lens48MPAuditTests/test35mmCropHighResolutionAcrossAutomaticAndManualRoutes`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L8294。

- L14897：`failed - 35mm成片 照片处理失败：无法编码所选照片格式。`

- L14898：`failed: caught error: "CancellationError()"`

- 源码位置：[Lens48MPAuditTests.swift:34](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/Lens48MPAuditTests.swift:34)。



### FULL-20261030-022

**Lens48MPAuditTests/testEveryPhysicalLensAndCropRouteHighResolutionFiles**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第301项。

- 耗时 35.478 秒。

- 定向入口：`LumaCameraTests/Lens48MPAuditTests/testEveryPhysicalLensAndCropRouteHighResolutionFiles`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L14900。

- L15087：`failed - 成片 0.5× JPG 照片处理失败：无法编码所选照片格式。`

- L15088：`failed: caught error: "CancellationError()"`

- 源码位置：[Lens48MPAuditTests.swift:109](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/Lens48MPAuditTests.swift:109)。



### FULL-20261030-023

**LivePhotoEditorTests/testExistingLiveRendersCopyAndReplacementWithoutSavingToLibrary**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第304项。

- 耗时 1.055 秒。

- 定向入口：`LumaCameraTests/LivePhotoEditorTests/testExistingLiveRendersCopyAndReplacementWithoutSavingToLibrary`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L15210。

- L15580：`failed: caught error: "Error Domain=com.apple.PhotosFormats Code=5 "(null)""`

- 源码位置：[LivePhotoEditorTests.swift:109](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Library/LivePhotoEditorTests.swift:109)。



### FULL-20261030-024

**ManualAutoRecoveryPhysicalTests/testLongExposureAutoReturnKeepsLocksCapturesAndCancellation**

- [ ] P2 · 曝光／白平衡／锁定恢复；待定位。全量顺序第325项。

- 耗时 15.363 秒。

- 定向入口：`LumaCameraTests/ManualAutoRecoveryPhysicalTests/testLongExposureAutoReturnKeepsLocksCapturesAndCancellation`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L16267。

- L16289：`XCTAssertEqualWithAccuracy failed: ("2.3217773") is not equal to ("2.1308594") +/- ("0.02")`

- L16290：`XCTAssertEqualWithAccuracy failed: ("1.833252") is not equal to ("1.7299805") +/- ("0.02")`

- 源码位置：[ManualAutoRecoveryPhysicalTests.swift:126](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/ManualAutoRecoveryPhysicalTests.swift:126)。



### FULL-20261030-025

**NightAdaptiveCapturePhysicalTests/testActualSceneMeasurementAndMotionDecision**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第339项。

- 耗时 46.972 秒。

- 定向入口：`LumaCameraTests/NightAdaptiveCapturePhysicalTests/testActualSceneMeasurementAndMotionDecision`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L16632。

- L16910：`Asynchronous wait failed: Exceeded timeout of 45 seconds, with unfulfilled expectations: "Adaptive night completes once".`

- L16911：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 照片处理失败：无法编码所选照片格式。`

- 源码位置：[NightAdaptiveCapturePhysicalTests.swift:462](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/NightAdaptiveCapturePhysicalTests.swift:462)。



### FULL-20261030-026

**NightAdaptiveCapturePhysicalTests/testAutomaticNightUsesPlannedExposureAndRepeatedCaptureReleasesTasks**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第340项。

- 耗时 45.547 秒。

- 定向入口：`LumaCameraTests/NightAdaptiveCapturePhysicalTests/testAutomaticNightUsesPlannedExposureAndRepeatedCaptureReleasesTasks`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L16913。

- L17165：`Asynchronous wait failed: Exceeded timeout of 45 seconds, with unfulfilled expectations: "Adaptive night completes once".`

- L17166：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 照片处理失败：无法编码所选照片格式。`

- 源码位置：[NightAdaptiveCapturePhysicalTests.swift:462](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/NightAdaptiveCapturePhysicalTests.swift:462)。



### FULL-20261030-027

**NightAdaptiveCapturePhysicalTests/testManualNightCancelAndReturnRetainsMExposure**

- [x] P1 · 夜景取消与重复完成已修复，专项真机回归通过。全量顺序第341项。

- 耗时 47.255 秒。

- 定向入口：`LumaCameraTests/NightAdaptiveCapturePhysicalTests/testManualNightCancelAndReturnRetainsMExposure`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L17168。

- L17460：`Asynchronous wait failed: Exceeded timeout of 45 seconds, with unfulfilled expectations: "Adaptive night completes once".`

- L17461：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 照片处理失败：无法编码所选照片格式。`

- 源码位置：[NightAdaptiveCapturePhysicalTests.swift:462](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/NightAdaptiveCapturePhysicalTests.swift:462)。



- 2026-10-30：NightCancel专项17项全通过，覆盖A/M采集及合成取消、快速返回与重拍；原始全量失败记录保留。[验证](2026-10-30-Night-Cancellation.md)。

### FULL-20261030-028

**NightAdaptiveCapturePhysicalTests/testManualNightPreservesRequestedExposureAndRangesAcrossBatches**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第342项。

- 耗时 46.376 秒。

- 定向入口：`LumaCameraTests/NightAdaptiveCapturePhysicalTests/testManualNightPreservesRequestedExposureAndRangesAcrossBatches`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L17463。

- L18143：`Asynchronous wait failed: Exceeded timeout of 45 seconds, with unfulfilled expectations: "Adaptive night completes once".`

- L18144：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 照片处理失败：无法编码所选照片格式。`

- 源码位置：[NightAdaptiveCapturePhysicalTests.swift:462](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/NightAdaptiveCapturePhysicalTests.swift:462)。



### FULL-20261030-029

**NightAdaptiveCapturePhysicalTests/testMotionStopsAppendingAndCancelThenReturnCanCaptureAgain**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第344项。

- 耗时 45.535 秒。

- 定向入口：`LumaCameraTests/NightAdaptiveCapturePhysicalTests/testMotionStopsAppendingAndCancelThenReturnCanCaptureAgain`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L18207。

- L18476：`Asynchronous wait failed: Exceeded timeout of 45 seconds, with unfulfilled expectations: "Adaptive night completes once".`

- L18477：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 照片处理失败：无法编码所选照片格式。`

- 源码位置：[NightAdaptiveCapturePhysicalTests.swift:462](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/NightAdaptiveCapturePhysicalTests.swift:462)。



### FULL-20261030-030

**NightAdaptiveCapturePhysicalTests/testNightPreviewRevealMetadataAndCancellationOnPhysicalCamera**

- [x] P1 · 夜景取消与重复完成已修复，专项真机回归通过。全量顺序第346项。

- 耗时 46.276 秒。

- 定向入口：`LumaCameraTests/NightAdaptiveCapturePhysicalTests/testNightPreviewRevealMetadataAndCancellationOnPhysicalCamera`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L18516。

- L21461：`Asynchronous wait failed: Exceeded timeout of 45 seconds, with unfulfilled expectations: "Adaptive night completes once".`

- L21462：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 照片处理失败：无法编码所选照片格式。`

- 源码位置：[NightAdaptiveCapturePhysicalTests.swift:462](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/NightAdaptiveCapturePhysicalTests.swift:462)。



- 2026-10-30：NightCancel专项17项全通过，覆盖A/M采集及合成取消、快速返回与重拍；原始全量失败记录保留。[验证](2026-10-30-Night-Cancellation.md)。

### FULL-20261030-031

**NightAdaptiveCapturePhysicalTests/testNightSupportsMModeAutomaticExposureAndAMSwitching**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第347项。

- 耗时 45.622 秒。

- 定向入口：`LumaCameraTests/NightAdaptiveCapturePhysicalTests/testNightSupportsMModeAutomaticExposureAndAMSwitching`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L21472。

- L21876：`Asynchronous wait failed: Exceeded timeout of 45 seconds, with unfulfilled expectations: "Adaptive night completes once".`

- L21877：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 照片处理失败：无法编码所选照片格式。`

- 源码位置：[NightAdaptiveCapturePhysicalTests.swift:462](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/NightAdaptiveCapturePhysicalTests.swift:462)。



### FULL-20261030-032

**NightAdaptiveCapturePhysicalTests/testThreeSixNineFrameBatchesAndActualFileInformation**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第348项。

- 耗时 46.409 秒。

- 定向入口：`LumaCameraTests/NightAdaptiveCapturePhysicalTests/testThreeSixNineFrameBatchesAndActualFileInformation`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L21879。

- L22250：`Asynchronous wait failed: Exceeded timeout of 45 seconds, with unfulfilled expectations: "Adaptive night completes once".`

- L22251：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 照片处理失败：无法编码所选照片格式。`

- 源码位置：[NightAdaptiveCapturePhysicalTests.swift:462](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/NightAdaptiveCapturePhysicalTests.swift:462)。



### FULL-20261030-033

**NightCapturePhysicalTests/testThreeNightCapturesCompleteInMemoryAndReportHonestMergeState**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第355项。

- 耗时 45.721 秒。

- 定向入口：`LumaCameraTests/NightCapturePhysicalTests/testThreeNightCapturesCompleteInMemoryAndReportHonestMergeState`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L22314。

- L22656：`Asynchronous wait failed: Exceeded timeout of 45 seconds, with unfulfilled expectations: "Night bracket 1 completes".`

- L22657：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - Night capture returned no photo`

- 源码位置：[NightCapturePhysicalTests.swift:123](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/NightCapturePhysicalTests.swift:123)。



### FULL-20261030-034

2026-10-30修复回归：该方法已通过，见[第一组记录](2026-10-30-Priority-Fixes.md)。

**PhotoCaptureTimeoutPhysicalTests/testMissingPortraitFinalReleasesOrderedResultsAndVideoCanRecord**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第391项。

- 耗时 19.204 秒。

- 定向入口：`LumaCameraTests/PhotoCaptureTimeoutPhysicalTests/testMissingPortraitFinalReleasesOrderedResultsAndVideoCanRecord`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L22858。

- L24241：`failed - 恢复后 HEIF 照片未交付`

- L24242：`failed: caught error: "Error Domain=PhotoTimeoutTest Code=1 "恢复后 HEIF 照片未交付" UserInfo={NSLocalizedDescription=恢复后 HEIF 照片未交付}"`

- 源码位置：[PhotoCaptureTimeoutPhysicalTests.swift:16](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PhotoCaptureTimeoutPhysicalTests.swift:16)。



### FULL-20261030-035

2026-11-01：本项定向真机通过，关联共12方法全部通过；[修复、指标和边界](2026-11-01-Other-Six-Fixes.md)。以下原失败记录保留。

**PortraitCapturePhysicalTests/testAutomaticMacroSuspendsPortraitCaptureAndRecovers**

- [x] P2 · 微距现场条件；待定位。全量顺序第488项。

- 耗时 9.020 秒。

- 定向入口：`LumaCameraTests/PortraitCapturePhysicalTests/testAutomaticMacroSuspendsPortraitCaptureAndRecovers`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L26293。

- L26316：`XCTAssertTrue failed - 近距回归必须观察到系统主动选择超广角；请保持近处有纹理主体`

- 源码位置：[PortraitCapturePhysicalTests.swift:223](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitCapturePhysicalTests.swift:223)。



### FULL-20261030-036

**PortraitCapturePhysicalTests/testPortraitProcessedAndProRAWCapturesWithoutSaving**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第490项。

- 耗时 59.574 秒。

- 定向入口：`LumaCameraTests/PortraitCapturePhysicalTests/testPortraitProcessedAndProRAWCapturesWithoutSaving`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L26342。

- L27219：`Asynchronous wait failed: Exceeded timeout of 55 seconds, with unfulfilled expectations: "Portrait capture: HEIF 48MP portrait matte #1".`

- L27220：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 照片处理失败：无法编码所选照片格式。`

- 源码位置：[PortraitCapturePhysicalTests.swift:346](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitCapturePhysicalTests.swift:346)。



### FULL-20261030-037

**PortraitOptimizationPhysicalTests/testFrontPortraitContinuousAdjustmentAndCapture**

- [ ] P1 · 照片回调／解码编码；待定位。全量顺序第502项。

- 耗时 8.659 秒。

- 定向入口：`LumaCameraTests/PortraitOptimizationPhysicalTests/testFrontPortraitContinuousAdjustmentAndCapture`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L27265。

- L27288：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 照片处理失败：无法编码所选照片格式。`

- 源码位置：[PortraitOptimizationPhysicalTests.swift:245](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitOptimizationPhysicalTests.swift:245)。



### FULL-20261030-038

**PortraitOptimizationPhysicalTests/testManualMainHEIFPortraitCanBeEnabledAndCaptured**

- [ ] P1 · 连续测试未保存队列／拍摄受阻；待定位。全量顺序第503项。

- 耗时 1.902 秒。

- 定向入口：`LumaCameraTests/PortraitOptimizationPhysicalTests/testManualMainHEIFPortraitCanBeEnabledAndCaptured`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L27290。

- L27314：`XCTAssertNil failed: "有 2 张照片未保存，可重试保存。"`

- L27315：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 有 2 张照片未保存，可重试保存。`

- 源码位置：[PortraitOptimizationPhysicalTests.swift:50](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitOptimizationPhysicalTests.swift:50)。



### FULL-20261030-039

2026-11-01：本项定向真机通过，关联共12方法全部通过；[修复、指标和边界](2026-11-01-Other-Six-Fixes.md)。以下原失败记录保留。

**PortraitOptimizationPhysicalTests/testRearPortraitContinuousAdjustmentAndCapture**

- [x] P1 · 连续测试未保存队列／拍摄受阻；待定位。全量顺序第504项。

- 耗时 8.327 秒。

- 定向入口：`LumaCameraTests/PortraitOptimizationPhysicalTests/testRearPortraitContinuousAdjustmentAndCapture`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L27317。

- L27341：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 有 3 张照片未保存，可重试保存。`

- 源码位置：[PortraitOptimizationPhysicalTests.swift:245](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitOptimizationPhysicalTests.swift:245)。



### FULL-20261030-040

**PortraitOptimizationPhysicalTests/testRearPortraitSameFrameReference**

- [ ] P1 · 连续测试未保存队列／拍摄受阻；待定位。全量顺序第505项。

- 耗时 2.034 秒。

- 定向入口：`LumaCameraTests/PortraitOptimizationPhysicalTests/testRearPortraitSameFrameReference`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L27343。

- L27366：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 有 4 张照片未保存，可重试保存。`

- 源码位置：[PortraitOptimizationPhysicalTests.swift:153](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitOptimizationPhysicalTests.swift:153)。



### FULL-20261030-041

**PreviewExposureAssistPhysicalTests/testOrdinarySmoothPreviewLongAndShortExposureFiles**

- [ ] P1 · 连续测试未保存队列／拍摄受阻；待定位。全量顺序第509项。

- 耗时 31.363 秒。

- 定向入口：`LumaCameraTests/PreviewExposureAssistPhysicalTests/testOrdinarySmoothPreviewLongAndShortExposureFiles`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L27401。

- L27439：`Asynchronous wait failed: Exceeded timeout of 30 seconds, with unfulfilled expectations: "普通曝光成片".`

- L27440：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 有 4 张照片未保存，可重试保存。`

- 源码位置：[PreviewExposureAssistPhysicalTests.swift:60](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:60)。



### FULL-20261030-042

**PreviewExposureAssistPhysicalTests/testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure**

- [ ] P1 · 连续测试未保存队列／拍摄受阻；待定位。全量顺序第510项。

- 耗时 35.629 秒。

- 定向入口：`LumaCameraTests/PreviewExposureAssistPhysicalTests/testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L27442。

- L27465：`Asynchronous wait failed: Exceeded timeout of 30 seconds, with unfulfilled expectations: "automatic slow-shutter preview still capture".`

- L27466：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 有 4 张照片未保存，可重试保存。`

- 源码位置：[PreviewExposureAssistPhysicalTests.swift:295](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:295)。



### FULL-20261030-043

**PreviewExposureAssistPhysicalTests/testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles**

- [ ] P1 · 连续测试未保存队列／拍摄受阻；待定位。全量顺序第511项。

- 耗时 42.058 秒。

- 定向入口：`LumaCameraTests/PreviewExposureAssistPhysicalTests/testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L27468。

- L27491：`Asynchronous wait failed: Exceeded timeout of 30 seconds, with unfulfilled expectations: "manual exposure photo with smooth preview".`

- L27492：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 有 4 张照片未保存，可重试保存。`

- 源码位置：[PreviewExposureAssistPhysicalTests.swift:454](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:454)。



### FULL-20261030-044

**ProToneCapturePhysicalTests/testAllProTonesAreUsedByActualHDRHEIFProCaptureWithoutSaving**

- [ ] P1 · 连续测试未保存队列／拍摄受阻；待定位。全量顺序第520项。

- 耗时 35.794 秒。

- 定向入口：`LumaCameraTests/ProToneCapturePhysicalTests/testAllProTonesAreUsedByActualHDRHEIFProCaptureWithoutSaving`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L28386。

- L28430：`Asynchronous wait failed: Exceeded timeout of 35 seconds, with unfulfilled expectations: "HDR HEIF Pro 自然影调".`

- L28431：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 有 4 张照片未保存，可重试保存。`

- 源码位置：[ProToneCapturePhysicalTests.swift:39](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/ProToneCapturePhysicalTests.swift:39)。



### FULL-20261030-045

**RecordingEdgeLayoutPhysicalTests/testRealRecordingUsesEdgePositionsAndStopsCleanly**

- [ ] P1 · 会话／路由恢复；待定位。全量顺序第528项。

- 耗时 15.587 秒。

- 定向入口：`LumaCameraTests/RecordingEdgeLayoutPhysicalTests/testRealRecordingUsesEdgePositionsAndStopsCleanly`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L29796。

- L29832：`failed - 启动 相机暂时无法恢复，请点击重试重新连接。`

- L29833：`failed: caught error: "CancellationError()"`

- 源码位置：[RecordingEdgeLayoutPhysicalTests.swift:124](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/RecordingEdgeLayoutPhysicalTests.swift:124)。



### FULL-20261030-046

**ShootingModeButtonTests/testActivePhotoAndVideoSubmodesUpdateEntryIcon**

- [ ] P1 · 会话／路由恢复；待定位。全量顺序第529项。

- 耗时 20.309 秒。

- 定向入口：`LumaCameraTests/ShootingModeButtonTests/testActivePhotoAndVideoSubmodesUpdateEntryIcon`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L29838。

- L29863：`failed - Expected camera.fill, actual camera.fill, message=相机暂时无法恢复，请点击重试重新连接。`

- L29864：`failed: caught error: "CancellationError()"`

- 源码位置：[ShootingModeButtonTests.swift:58](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/ShootingModeButtonTests.swift:58)。



### FULL-20261030-047

**SilentShutterPhysicalTests/testNativeShutterSuppressionAcrossFormatsAndLiveWithoutSaving**

- [ ] P2 · 拍摄／交互状态；待定位。全量顺序第531项。

- 耗时 76.838 秒。

- 定向入口：`LumaCameraTests/SilentShutterPhysicalTests/testNativeShutterSuppressionAcrossFormatsAndLiveWithoutSaving`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L30192。

- L30217：`XCTAssertTrue failed`

- L30218：`XCTAssertEqual failed: ("0") is not equal to ("1") - Capture must be accepted before waiting for completion`

- L30219：`Asynchronous wait failed: Exceeded timeout of 45 seconds, with unfulfilled expectations: "Shutter sound capture JPG".`

- L30220：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机暂时无法恢复，请点击重试重新连接。`

- 源码位置：[SilentShutterPhysicalTests.swift:37](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SilentShutterPhysicalTests.swift:37)。



### FULL-20261030-048

**SilentShutterPhysicalTests/testNightBatchesUseSilentPreferenceAndReleaseCaptureTasks**

- [ ] P2 · 拍摄／交互状态；待定位。全量顺序第532项。

- 耗时 53.622 秒。

- 定向入口：`LumaCameraTests/SilentShutterPhysicalTests/testNightBatchesUseSilentPreferenceAndReleaseCaptureTasks`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L30222。

- L30247：`Asynchronous wait failed: Exceeded timeout of 40 seconds, with unfulfilled expectations: "静音夜景真实6帧".`

- L30248：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机暂时无法恢复，请点击重试重新连接。`

- 源码位置：[SilentShutterPhysicalTests.swift:102](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SilentShutterPhysicalTests.swift:102)。



### FULL-20261030-049

**SlowMotionLensTransitionPhysicalTests/testSlowMotionFocalSwitchLatencyAndRecording**

- [ ] P1 · 会话／路由恢复；待定位。全量顺序第533项。

- 耗时 62.599 秒。

- 定向入口：`LumaCameraTests/SlowMotionLensTransitionPhysicalTests/testSlowMotionFocalSwitchLatencyAndRecording`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L30253。

- L31173：`XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:8:1.5855") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:5:1.0000")`

- L31174：`XCTAssertNotEqual failed: ("Optional(5E2A7E3D-5903-4717-A1CA-D3FE3BA09D86)") is equal to ("Optional(5E2A7E3D-5903-4717-A1CA-D3FE3BA09D86)")`

- L31175：`failed: caught error: "CancellationError()"`

- 源码位置：[SlowMotionLensTransitionPhysicalTests.swift:98](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowMotionLensTransitionPhysicalTests.swift:98)。



### FULL-20261030-050

2026-10-30修复回归：该方法已通过，见[第一组记录](2026-10-30-Priority-Fixes.md)。

**SlowShutterHandheldTests/testAccumulationPreviewUsesRealBlendAndDoesNotMutateFullResolutionResult**

- [ ] P1 · 慢门合成／累积预览；待定位。全量顺序第540项。

- 耗时 0.334 秒。

- 定向入口：`LumaCameraTests/SlowShutterHandheldTests/testAccumulationPreviewUsesRealBlendAndDoesNotMutateFullResolutionResult`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31198。

- L31203：`XCTAssertTrue failed`

- L31204：`XCTAssertEqualWithAccuracy failed: ("0.0") is not equal to ("900.0") +/- ("1.0")`

- 原始共13条断言/异常，去重后2类；完整证据见JSON。

- 源码位置：[SlowShutterHandheldTests.swift:108](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterHandheldTests.swift:108)。



### FULL-20261030-051

**SlowShutterPresetTests/testMKeepsSlowModeButClearsAndHidesPreset**

- [ ] P2 · 设置记忆／格式兼容；待定位。全量顺序第547项。

- 耗时 0.662 秒。

- 定向入口：`LumaCameraTests/SlowShutterPresetTests/testMKeepsSlowModeButClearsAndHidesPreset`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31319。

- L31349：`XCTAssertTrue failed`

- L31350：`XCTAssertEqual failed: ("nil") is not equal to ("Optional(LumaCamera.SlowShutterPreset.lightTrails)")`

- L31352：`XCTAssertEqual failed: ("auto") is not equal to ("manual")`

- 原始共6条断言/异常，去重后3类；完整证据见JSON。

- 源码位置：[SlowShutterPresetTests.swift:112](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterPresetTests.swift:112)。



### FULL-20261030-052

**SlowShutterSequencePhysicalTests/testAdaptiveOtherPresetsAutomaticFullSequences**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第563项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 11.094 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testAdaptiveOtherPresetsAutomaticFullSequences`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31488。

- L31522：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L31524：`failed - 慢门逐帧合并失败。`

- L31525：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-053

**SlowShutterSequencePhysicalTests/testAdaptiveOtherPresetsManualEarlyFinishAndCancellation**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第564项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 21.354 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testAdaptiveOtherPresetsManualEarlyFinishAndCancellation`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31527。

- L31560：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L31562：`failed - 慢门逐帧合并失败。`

- L31563：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-054

**SlowShutterSequencePhysicalTests/testAdaptiveStarTrailsFullDuration**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第565项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 19.692 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testAdaptiveStarTrailsFullDuration`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31565。

- L31598：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L31600：`failed - 慢门逐帧合并失败。`

- L31601：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-055

**SlowShutterSequencePhysicalTests/testAdaptiveWaterAutomaticAndManualRestoration**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第566项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 19.639 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testAdaptiveWaterAutomaticAndManualRestoration`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31603。

- L31651：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L31653：`failed - 慢门逐帧合并失败。`

- L31662：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-056

**SlowShutterSequencePhysicalTests/testAdaptiveWaterEarlyFinishCancelAndRestart**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第567项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 30.693 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testAdaptiveWaterEarlyFinishCancelAndRestart`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31664。

- L31696：`failed - 流水首帧未到达; message=慢门逐帧合并失败。 progress=nil`

- L31697：`failed: caught error: "CancellationError()"`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:686](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:686)。



### FULL-20261030-057

**SlowShutterSequencePhysicalTests/testAdaptiveWaterSceneExposureWithJPEG**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第568项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 19.478 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testAdaptiveWaterSceneExposureWithJPEG`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31699。

- L31733：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L31735：`failed - 慢门逐帧合并失败。`

- L31736：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-058

**SlowShutterSequencePhysicalTests/testAutomaticLightTrailsAndWaterCompleteOrRejectUnsafeExposure**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第569项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 19.619 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testAutomaticLightTrailsAndWaterCompleteOrRejectUnsafeExposure`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31738。

- L31772：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L31774：`failed - 慢门逐帧合并失败。`

- L31775：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-059

**SlowShutterSequencePhysicalTests/testAutomaticNewPresetsPreserveModeAndValidateMeteredExposure**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第570项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 19.621 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testAutomaticNewPresetsPreserveModeAndValidateMeteredExposure`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31777。

- L31810：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L31812：`failed - 慢门逐帧合并失败。`

- L31813：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-060

**SlowShutterSequencePhysicalTests/testAutomaticSequencesWithMeteredExposureCompensation**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第571项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 22.791 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testAutomaticSequencesWithMeteredExposureCompensation`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31815。

- L31849：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L31851：`failed - 慢门逐帧合并失败。`

- L31852：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-061

**SlowShutterSequencePhysicalTests/testEarlyFinishCancellationAndRepeatedSelectionRecover**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第572项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 42.492 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testEarlyFinishCancellationAndRepeatedSelectionRecover`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31854。

- L31932：`failed - 首帧未返回; message=慢门逐帧合并失败。 progress=nil`

- L31933：`failed: caught error: "CancellationError()"`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:686](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:686)。



### FULL-20261030-062

**SlowShutterSequencePhysicalTests/testGenericManualDurationAndInfiniteCancellation**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第573项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 39.470 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testGenericManualDurationAndInfiniteCancellation`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31935。

- L31981：`failed - M挡通用合成没有出片; message=慢门逐帧合并失败。 progress=nil`

- L31982：`failed: caught error: "CancellationError()"`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:686](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:686)。



### FULL-20261030-063

**SlowShutterSequencePhysicalTests/testManualBracketSpeedComparisonAndRepeatedCapture**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第574项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 12.723 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testManualBracketSpeedComparisonAndRepeatedCapture`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L31984。

- L32050：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L32052：`failed - 慢门逐帧合并失败。`

- L32053：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-064

**SlowShutterSequencePhysicalTests/testManualLightTrailsAndWaterCompleteWithMetadata**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第575项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 21.406 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testManualLightTrailsAndWaterCompleteWithMetadata`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L32055。

- L32088：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L32090：`failed - 慢门逐帧合并失败。`

- L32091：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-065

**SlowShutterSequencePhysicalTests/testManualMotionBlurCompletesWithShortSourceExposures**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第576项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 21.305 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testManualMotionBlurCompletesWithShortSourceExposures`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L32093。

- L32126：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L32128：`failed - 慢门逐帧合并失败。`

- L32129：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-066

**SlowShutterSequencePhysicalTests/testPanningLatencyWithAndWithoutPreviewAssist**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第577项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 21.419 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testPanningLatencyWithAndWithoutPreviewAssist`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L32131。

- L32164：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L32166：`failed - 慢门逐帧合并失败。`

- L32167：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-067

**SlowShutterSequencePhysicalTests/testRealAccumulationPreviewAndCancelOnPhysicalViewfinder**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第578项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 19.849 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testRealAccumulationPreviewAndCancelOnPhysicalViewfinder`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L32169。

- L32655：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L32657：`failed - 慢门逐帧合并失败。`

- L32678：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-068

**SlowShutterSequencePhysicalTests/testSingleFramePresetsCaptureRequestedExposureWithoutStartingSequence**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第579项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 21.365 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testSingleFramePresetsCaptureRequestedExposureWithoutStartingSequence`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L32680。

- L32713：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L32715：`failed - 慢门逐帧合并失败。`

- L32716：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-069

**SlowShutterSequencePhysicalTests/testSlowShutterPreviewAndFallbackResumeRepeatedly**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第580项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 40.394 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testSlowShutterPreviewAndFallbackResumeRepeatedly`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L32718。

- L32750：`failed - 慢门预览回归未完成; message=慢门逐帧合并失败。 progress=nil`

- L32751：`failed: caught error: "CancellationError()"`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:686](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:686)。



### FULL-20261030-070

**SlowShutterSequencePhysicalTests/testStarTrailsEarlyFinishCancellationAndRepeatedSelection**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第581项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 63.312 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testStarTrailsEarlyFinishCancellationAndRepeatedSelection`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L32753。

- L32785：`failed - 星轨首批帧未完成; message=慢门逐帧合并失败。 progress=nil`

- L32786：`failed: caught error: "CancellationError()"`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:686](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:686)。



### FULL-20261030-071

**SlowShutterSequencePhysicalTests/testStarTrailsFull120FrameStreamingSequence**

- [x] P1 · 慢门合成／累积预览；2026-11-01专项真机通过。全量顺序第582项。

- 最新验证：[慢门专项](2026-11-01-SlowShutter-Fixes.md)，最终45项43通过/2旧夹具跳过；原失败日志保留。

- 耗时 21.285 秒。

- 定向入口：`LumaCameraTests/SlowShutterSequencePhysicalTests/testStarTrailsFull120FrameStreamingSequence`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L32788。

- L32821：`XCTAssertGreaterThanOrEqual failed: ("0") is less than ("2") - 完整序列应显示真实中间合成`

- L32823：`failed - 慢门逐帧合并失败。`

- L32824：`failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""`

- 源码位置：[SlowShutterSequencePhysicalTests.swift:579](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterSequencePhysicalTests.swift:579)。



### FULL-20261030-072

2026-11-01：本项定向真机通过，关联共12方法全部通过；[修复、指标和边界](2026-11-01-Other-Six-Fixes.md)。以下原失败记录保留。

**Smart48CompatibilityTests/test48MPSmartFramingHDRAndNightBoundaries**

- [x] P2 · 智拍状态／重复取景；待定位。全量顺序第588项。

- 耗时 36.230 秒。

- 定向入口：`LumaCameraTests/Smart48CompatibilityTests/test48MPSmartFramingHDRAndNightBoundaries`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L32851。

- L32875：`failed - 48MP出片 `

- L32876：`failed: caught error: "CancellationError()"`

- 源码位置：[Smart48CompatibilityTests.swift:31](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/Smart48CompatibilityTests.swift:31)。



### FULL-20261030-073

2026-11-01：本项定向真机通过，关联共12方法全部通过；[修复、指标和边界](2026-11-01-Other-Six-Fixes.md)。以下原失败记录保留。

**SmartAutoFramingTests/testAutomaticHardwareFramingOnceAndCancelPendingWork**

- [x] P2 · 智拍状态／重复取景；待定位。全量顺序第593项。

- 耗时 4.759 秒。

- 定向入口：`LumaCameraTests/SmartAutoFramingTests/testAutomaticHardwareFramingOnceAndCancelPendingWork`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L32911。

- L32933：`XCTAssertEqual failed: ("2") is not equal to ("1")`

- L32936：`XCTAssertEqual failed: ("3") is not equal to ("2")`

- 原始共4条断言/异常，去重后2类；完整证据见JSON。

- 源码位置：[SmartAutoFramingTests.swift:414](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SmartAutoFramingTests.swift:414)。



### FULL-20261030-074

**SmartAutoFramingTests/testManualSmartFramingFocusExposureAndMoveAwayReturn**

- [ ] P2 · 智拍状态／重复取景；待定位。全量顺序第601项。

- 耗时 32.904 秒。

- 定向入口：`LumaCameraTests/SmartAutoFramingTests/testManualSmartFramingFocusExposureAndMoveAwayReturn`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L33020。

- L33045：`Asynchronous wait failed: Exceeded timeout of 30 seconds, with unfulfilled expectations: "M智拍后真实JPEG".`

- L33046：`XCTUnwrap failed: expected non-nil value of type "Data"`

- 源码位置：[SmartAutoFramingTests.swift:333](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SmartAutoFramingTests.swift:333)。



### FULL-20261030-075

**VideoColorPhysicalTests/testEveryAvailableColorSpaceRecordsRealTagsAndRestoresPhotos**

- [ ] P2 · 拍摄／交互状态；待定位。全量顺序第648项。

- 耗时 184.204 秒。

- 定向入口：`LumaCameraTests/VideoColorPhysicalTests/testEveryAvailableColorSpaceRecordsRealTagsAndRestoresPhotos`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L33687。

- L33715：`XCTAssertNotNil failed - 前置照片宽高比切换失败：Operation Interrupted`

- L33778：`XCTAssertNotNil failed - Still photo failed after appleLog2`

- 原始共10条断言/异常，去重后2类；完整证据见JSON。

- 源码位置：[VideoColorPhysicalTests.swift:128](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoColorPhysicalTests.swift:128)。



### FULL-20261030-076

**VideoModeTransitionTests/testAutomaticVideoRouteRestoresPhotoFormatAndLensSwitching**

- [x] P1 · 会话／路由恢复；2026-11-01专项真机通过。全量顺序第685项。

- 最新验证：[视频六项专项](2026-11-01-Video-Six-Fixes.md)，最终三批9方法全通过，包含真实人物横竖录像；原失败日志保留。

- 耗时 15.465 秒。

- 定向入口：`LumaCameraTests/VideoModeTransitionTests/testAutomaticVideoRouteRestoresPhotoFormatAndLensSwitching`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L34717。

- L34740：`XCTAssertTrue failed - A-mode video recording did not start`

- L35293：`XCTUnwrap failed: expected non-nil value of type "URL"`

- 源码位置：[VideoModeTransitionTests.swift:67](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:67)。



### FULL-20261030-077

**VideoModeTransitionTests/testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips**

- [x] P1 · 会话／路由恢复；2026-11-01专项真机通过。全量顺序第686项。

- 最新验证：[视频六项专项](2026-11-01-Video-Six-Fixes.md)，最终三批9方法全通过，包含真实人物横竖录像；原失败日志保留。

- 耗时 44.403 秒。

- 定向入口：`LumaCameraTests/VideoModeTransitionTests/testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L35319。

- L35692：`XCTAssertGreaterThan failed: ("186669.3597195417") is not greater than ("186669.79137512503")`

- L35693：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 视频返回后照片未完成`

- 源码位置：[VideoModeTransitionTests.swift:234](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:234)。



### FULL-20261030-078

**VideoSpecificationTests/testAllSupportedVideoSpecificationsWriteMatchingTracks**

- [ ] P1 · 实际视频帧率／规格；待定位。全量顺序第691项。

- 耗时 41.769 秒。

- 定向入口：`LumaCameraTests/VideoSpecificationTests/testAllSupportedVideoSpecificationsWriteMatchingTracks`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L36794。

- L37118：`XCTAssertEqualWithAccuracy failed: ("30.0") is not equal to ("50.0") +/- ("2.5")`

- L37119：`XCTAssertEqualWithAccuracy failed: ("33.333333333333336") is not equal to ("50.0") +/- ("2.5")`

- L37129：`XCTAssertEqualWithAccuracy failed: ("25.714284896850586") is not equal to ("60.0") +/- ("3.0")`

- L37130：`XCTAssertEqualWithAccuracy failed: ("30.0") is not equal to ("60.0") +/- ("3.0")`

- L37146：`XCTAssertEqualWithAccuracy failed: ("43.6363639831543") is not equal to ("120.0") +/- ("6.0")`

- 原始共6条断言/异常，去重后6类；完整证据见JSON。

- 源码位置：[VideoSpecificationTests.swift:867](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:867)。



### FULL-20261030-079

**VideoSpecificationTests/testHighFrameRateAndFrontCameraRestoreSupportedSpecifications**

- [ ] P1 · 实际视频帧率／规格；待定位。全量顺序第693项。

- 耗时 16.150 秒。

- 定向入口：`LumaCameraTests/VideoSpecificationTests/testHighFrameRateAndFrontCameraRestoreSupportedSpecifications`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L37165。

- L37226：`XCTAssertEqualWithAccuracy failed: ("18.947368621826172") is not equal to ("120.0") +/- ("1.0")`

- L37227：`XCTAssertEqualWithAccuracy failed: ("24.0") is not equal to ("120.0") +/- ("6.0")`

- L37232：`failed - 前置新帧: 未就绪`

- L37233：`failed: caught error: "CancellationError()"`

- 源码位置：[VideoSpecificationTests.swift:764](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:764)。



### FULL-20261030-080

**VideoVirtualAperturePhysicalTests/testVideoEntryLayoutRecordingAndRecovery**

- [ ] P1 · 资源分配／宿主异常退出；待定位。全量顺序第702项。

- 宿主异常退出，结果包未记录完成耗时；Xcode随后继续剩余用例。

- 定向入口：`LumaCameraTests/VideoVirtualAperturePhysicalTests/testVideoEntryLayoutRecordingAndRecovery`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L37489。

- L37699：`XCTAssertEqualWithAccuracy failed: ("212.0") is not equal to ("170.0") +/- ("1.0")`

- 原始共20条断言/异常，去重后1类；完整证据见JSON。

- 源码位置：[VideoVirtualAperturePhysicalTests.swift:82](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoVirtualAperturePhysicalTests.swift:82)。



### FULL-20261030-081

**VideoWhiteBalancePhysicalTests/testVideoWhiteBalanceLockIsOptionalAndRestoredAfterRecording**

- [x] P2 · 曝光／白平衡／锁定恢复；2026-11-01专项真机通过。全量顺序第703项。

- 最新验证：[视频六项专项](2026-11-01-Video-Six-Fixes.md)，最终三批9方法全通过，包含真实人物横竖录像；原失败日志保留。

- 耗时 18.863 秒。

- 定向入口：`LumaCameraTests/VideoWhiteBalancePhysicalTests/testVideoWhiteBalanceLockIsOptionalAndRestoredAfterRecording`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L39224。

- L39252：`XCTAssertTrue failed - HEVC recording failed; lock=false`

- L39253：`XCTAssertLessThan failed: ("4.982981583307264") is not less than ("3.0") - WB preference must not delay recording startup beyond 3 seconds`

- L39258：`XCTUnwrap failed: expected non-nil value of type "URL" - Recording completion failed; lock=false`

- 源码位置：[VideoWhiteBalancePhysicalTests.swift:124](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoWhiteBalancePhysicalTests.swift:124)。



### FULL-20261030-082

2026-11-01：本项定向真机通过，关联共12方法全部通过；[修复、指标和边界](2026-11-01-Other-Six-Fixes.md)。以下原失败记录保留。

**VirtualAperturePhysicalTests/testLensRestrictionsContinuousSliderAndRealPhotoInformation**

- [x] P1 · 照片回调／解码编码；待定位。全量顺序第721项。

- 耗时 21.522 秒。

- 定向入口：`LumaCameraTests/VirtualAperturePhysicalTests/testLensRestrictionsContinuousSliderAndRealPhotoInformation`。

- 起始日志：`/tmp/LumaCamera-FullDevice-20261030/run.log` L39567。

- L39950：`failed - 固定轨道控件挂载 `

- L39961：`failed: caught error: "InvalidTransition { `

- 源码位置：[VirtualAperturePhysicalTests.swift:125](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VirtualAperturePhysicalTests.swift:125)。


