# 2026-10-30 全量问题按优先级修复

## 第一组：资源所有权与拍摄终结

已实现：Imaging.ownedCGImage将跨帧/跨队列保存的渲染输出复制为独立像素，保留位深、色域及HDR headroom/平均光级；相机预览、成片预览、慢门检查点、RAW/编辑预览接入。PhotoEncoder结束后清理当前CIContext缓存。每个快门请求固定完成回调，按快门顺序交付成功或nil失败，避免迟到结果落入后来替换的回调；默认App失败通知保留上一张成功缩略图。DEBUG只读诊断相册的reset会清除上一测试的临时失败保存队列，正式用户失败照片与重试上限保持。

Apple SDK CIContext.h明确deferred:false立即渲染，clearCaches释放临时缓存；CGImage.h定义iOS18 HDR headroom及iOS26平均光级复制API。本轮据此保留像素/色彩元数据；原IOSurface异常退出是否完全解决由后续长序列回归核对。

真机iPhone17Pro/iOS27.2：`/tmp/LumaCamera-PriorityFix-Core.log`，36项0失败/0跳过、46.080秒。包含新增SDR/P3/半浮点HDR像素及元数据一致性、120次900×675渲染（四轮各保留30张后释放，中位1.05ms/最大4.29ms，非显示FPS）、请求回调替换与失败恰好一次、三项超时/迟到/退出恢复、四项手持慢门和20项编码参数检查。相册诊断隔离6项亦通过，未写系统相册。

原失败FULL-20261030-034与FULL-20261030-050对应方法本批通过。其他原失败方法按后续批次更新，原全量证据保留。


## 第一轮原失败复验与后续定向复验

第一轮 `/tmp/LumaCamera-PriorityFix-Replay1.xcresult` 共91个方法：61通过、30失败；其中原82个失败方法52通过、30失败，另外9项为新增或关联回归。此为该轮快照，不代表当前30项均未改动。该轮仍出现慢门长序列宿主退出与夜景取消后的重复完成回调，资源稳定性尚未关闭。

后续实现将RGBA8/RGBA16检查点直接渲染到自有内存，RGBAh保持像素及HDR属性复制；慢门逐帧检查点后清理CI缓存。显式取消不交付nil完成回调，真实错误仍通知一次。手持慢门配准采用320×240细节与稳定区域相关性复核。诊断基线清理弹窗/错误状态，焦段点击夹具恢复真实可点击窗口；M挡保存测试按当前48MP自动曝光契约拆分。

`/tmp/LumaCamera-PriorityFix-Quick2.xcresult`：18个方法中17通过、1失败（流水不相关帧剔除），后继续修正。

`/tmp/LumaCamera-PriorityFix-Quick3.xcresult`：iPhone17Pro/iOS27.2，8个方法7通过、1失败（重复录像，2处断言），测试执行46.798秒。流水5源帧接受4/剔除1，静态区域误差0、普通平均误差114.94（合成纹理指标，不代表自然场景画质）；焦段点击反复选择及两张6000×8000实际文件通过；8倍导航进入、拍照及切视频恢复方法通过（进入0.610秒）；M挡慢门切换通过。像素/HDR属性一致性通过；900×675自有像素渲染120次，4轮各保留30张，中位0.588ms、最大1.255ms，非显示FPS、非应用内存测量。诊断媒体不写系统相册。

最新补测没有重新覆盖全部30项；夜景取消、星轨完整长序列、其余导航/视频/双摄等仍待复验，人物/微距4项待真实场景。尚未完成最终Release与全量回归。

### 第一轮剩余30个方法（历史快照）

1. `AdaptiveWaterComposerTests/testHandheldAlignmentPreservesStaticDetailAndRejectsUnrelatedFrame()` — 2026-11-01慢门专项真机通过。首轮：XCTAssertEqual failed: ("5") is not equal to ("4")；XCTAssertEqual failed: ("0") is not equal to ("1")
2. `AutomaticLensStabilityPhysicalTests/testAutomaticModeUsesSystemVirtualCameraCandidatesAndWheelRetainsFullRange()` — 2026-11-01其他六项定向真机通过。首轮：XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertNotNil failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertEqualWithAccuracy failed: ("1.0") is not equal to ("0.5") +/- ("0.01")；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；X
3. `BasicVideoPhysicalTests/testRepeatedVideoRecordingsAndPhotoModeReturn()` — 2026-11-01视频六项及关联真机复验通过。首轮：XCTAssertTrue failed - Movie output did not start；XCTUnwrap failed: expected non-nil value of type "URL"
4. `CameraFocalButtonTests/testHostedFocalStripHitTargetsAfterRepeatedSelections()` — Quick3及2026-11-01最终串行组真机通过。首轮：XCTAssertTrue failed - 焦段中心触摸必须交给原生按钮；XCTAssertTrue failed - 焦段中心触摸必须交给原生按钮；XCTAssertTrue failed - 焦段中心触摸必须交给原生按钮；XCTAssertTrue failed - 焦段中心触摸必须交给原生按钮；XCTAssertTrue failed - 焦段中心触摸必须交给原生按钮；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue failed；XCTAssertTrue faile
5. `CaptureStatePersistenceTests/testAllCaptureChoicesAndManualFlagsSurviveModelRecreation()` — Quick2及2026-11-01最终串行组真机通过。首轮：XCTAssertTrue failed
6. `DualCapturePhysicalTests/testEngineDualCaptureRecordingSwapAndOrdinaryRecovery()` — 2026-11-01双摄专项真机通过。首轮：XCTAssertTrue failed - 相机会话产生运行错误，即使后来自动恢复也不能忽略：["AVFoundationErrorDomain/-11819: Cannot Complete Action"]
7. `DualCapturePhysicalTests/testInactiveDualCaptureEntryIsVisibleInsideLensRegion()` — 2026-11-01双摄专项真机通过。首轮：XCTUnwrap failed: expected non-nil value of type "CGRect"
8. `FocusNavigatorPhysicalTests/testLiveAndRawPhotoPipelineRestoresAfterNavigation()` — 2026-11-01导航及关联真机回归通过。首轮：failed - 8倍 ；failed: caught error: "CancellationError()"
9. `FocusNavigatorPhysicalTests/testManualCaptureMetadataAndMovableNavigatorLayout()` — 2026-11-01导航及关联真机回归通过。首轮：failed - 导航 ；failed: caught error: "InvalidTransition {    phase: idle   targetPhase: failed(removedFromContainer) }"
10. `FocusNavigatorPhysicalTests/testPhotoNavigatorThresholdCaptureAndVideoExit()` — 2026-11-01导航及关联真机回归通过。首轮：failed - 照片8倍导航 reason=nil message=nil state=["session": "true", "pressureCost": "-1.0", "zoom": "12.683938026428223", "active": "false", "hardwareCost": "-1.0", "renderSeconds": "0.0", "frames": "0"]；failed: caught error: "CancellationError()"
11. `FrontVideoCenteringPhysicalTests/testCenterStagePersonLandscapeRecording()` — 2026-11-01视频六项及关联真机复验通过。首轮：failed - 真实手持方向 ；failed: caught error: "CancellationError()"
12. `FrontVideoCenteringPhysicalTests/testCenterStagePersonPortraitRecording()` — 2026-11-01视频六项及关联真机复验通过。首轮：failed - 开始录制 ；failed: caught error: "CancellationError()"
13. `NightAdaptiveCapturePhysicalTests/testManualNightCancelAndReturnRetainsMExposure()` — NightCancel专项真机通过。首轮：XCTAssertFalse failed - 取消组不应交付半成品
14. `NightAdaptiveCapturePhysicalTests/testNightPreviewRevealMetadataAndCancellationOnPhysicalCamera()` — NightCancel专项真机通过。首轮：API violation - multiple calls made to -[XCTestExpectation fulfill] for Adaptive night completes once. (NSInternalInconsistencyException)；Crash: LumaCamera
15. `PortraitCapturePhysicalTests/testAutomaticMacroSuspendsPortraitCaptureAndRecovers()` — 2026-11-01其他六项定向真机通过。首轮：XCTAssertTrue failed - 近距回归必须观察到系统主动选择超广角；请保持近处有纹理主体
16. `PortraitOptimizationPhysicalTests/testRearPortraitContinuousAdjustmentAndCapture()` — 2026-11-01其他六项定向真机通过。首轮：XCTAssertGreaterThan failed: ("0") is not greater than ("0") - 需真实人物入镜才能验收人物分割，不能把空背景记为通过
17. `SlowShutterSequencePhysicalTests/testAdaptiveStarTrailsFullDuration()` — 2026-11-01慢门专项真机通过。首轮：XCTAssertGreaterThanOrEqual failed: ("0.3845501249888912") is less than ("0.42") - 预览更新应节流，避免每源帧重绘；failed - 慢门逐帧合并失败。；failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""
18. `SlowShutterSequencePhysicalTests/testAdaptiveWaterAutomaticAndManualRestoration()` — 2026-11-01慢门专项真机通过。首轮：Crash: LumaCamera
19. `SlowShutterSequencePhysicalTests/testAutomaticLightTrailsAndWaterCompleteOrRejectUnsafeExposure()` — 2026-11-01慢门专项真机通过。首轮：XCTAssertGreaterThan failed: ("10112688") is not greater than ("11000000")；XCTAssertGreaterThan failed: ("8964001") is not greater than ("11000000")
20. `SlowShutterSequencePhysicalTests/testAutomaticSequencesWithMeteredExposureCompensation()` — 2026-11-01慢门专项真机通过。首轮：XCTAssertGreaterThan failed: ("10452400") is not greater than ("11000000")
21. `SlowShutterSequencePhysicalTests/testManualBracketSpeedComparisonAndRepeatedCapture()` — 2026-11-01慢门专项真机通过。首轮：XCTAssertGreaterThan failed: ("9720000") is not greater than ("11000000")；XCTAssertGreaterThan failed: ("9435020") is not greater than ("11000000")；XCTAssertGreaterThan failed: ("10452400") is not greater than ("11000000")；XCTAssertGreaterThan failed: ("9618566") is not greater than ("11000000")；XCTAssertGreaterThan failed: ("10745615") is not greater than ("11000000")；XCTAssertGreaterThan failed: ("9943571") is not greater than ("11000000")
22. `SlowShutterSequencePhysicalTests/testManualLightTrailsAndWaterCompleteWithMetadata()` — 2026-11-01慢门专项真机通过。首轮：XCTAssertGreaterThan failed: ("10745615") is not greater than ("11000000")；XCTAssertGreaterThan failed: ("9640065") is not greater than ("11000000")
23. `SlowShutterSequencePhysicalTests/testManualMotionBlurCompletesWithShortSourceExposures()` — 2026-11-01慢门专项真机通过。首轮：XCTAssertGreaterThan failed: ("10934752") is not greater than ("11000000")
24. `SlowShutterSequencePhysicalTests/testStarTrailsFull120FrameStreamingSequence()` — 2026-11-01慢门专项真机通过。首轮：failed - 慢门逐帧合并失败。；failed: caught error: "Error Domain=SlowShutterCaptureFailure Code=1 "(null)""
25. `Smart48CompatibilityTests/test48MPSmartFramingHDRAndNightBoundaries()` — 2026-11-01其他六项定向真机通过。首轮：failed - 48MP出片 照片处理失败：无法编码所选照片格式。；failed: caught error: "CancellationError()"
26. `SmartAutoFramingTests/testAutomaticHardwareFramingOnceAndCancelPendingWork()` — 2026-11-01其他六项定向真机通过。首轮：XCTAssertEqual failed: ("2") is not equal to ("1")；XCTAssertEqual failed: ("2") is not equal to ("1")；XCTAssertEqual failed: ("2") is not equal to ("1")；XCTAssertEqual failed: ("3") is not equal to ("2")
27. `VideoModeTransitionTests/testAutomaticVideoRouteRestoresPhotoFormatAndLensSwitching()` — 2026-11-01视频六项及关联真机复验通过。首轮：XCTAssertTrue failed - 照片处理失败：无法编码所选照片格式。；XCTUnwrap failed: expected non-nil value of type "URL"
28. `VideoModeTransitionTests/testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips()` — 2026-11-01视频六项及关联真机复验通过。首轮：XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 照片处理失败：无法编码所选照片格式。
29. `VideoWhiteBalancePhysicalTests/testVideoWhiteBalanceLockIsOptionalAndRestoredAfterRecording()` — 2026-11-01视频六项及关联真机复验通过。首轮：XCTAssertTrue failed - 拍照失败：The operation could not be completed；XCTAssertLessThan failed: ("4.978838500013808") is not less than ("3.0") - WB preference must not delay recording startup beyond 3 seconds；XCTUnwrap failed: expected non-nil value of type "URL" - Recording completion failed; lock=false
30. `VirtualAperturePhysicalTests/testLensRestrictionsContinuousSliderAndRealPhotoInformation()` — 2026-11-01其他六项定向真机通过。首轮：failed - 固定轨道控件挂载 拍照失败：The operation could not be completed；failed: caught error: "InvalidTransition {    phase: idle   targetPhase: failed(disabled) }"


## 夜景两个剩余项关闭

FULL-027/FULL-030最终17项专项回归全通过；取消后不交付、完成处理不重复，新增A/M采集及后台合成取消/快速返回4轮通过；真实超时仍通知一次，Release通过。[完整验证](2026-10-30-Night-Cancellation.md)。第一轮30项为历史快照，不据此改写原全量结果。


## 双摄剩余项专项完成（2026-11-01）

原FULL-011/FULL-012及关联14方法最终真机全通过；新增修正旧图迟到错误误退新会话及异常退出规格恢复；HUD使用最新坐标验收，25规格真实录制/解码通过。本轮未观察到原-11819，保留历史记录，不把应用回调注入等同系统服务重置。[完整结果](2026-11-01-DualCapture-Recovery.md)。

## 慢门剩余九项专项完成（2026-11-01）

原FULL-001/054/055/058/060/063/064/065/071最终全部通过；45方法43通过、0失败、2旧夹具跳过，35次完整序列均1200万像素，两条完整星轨181/174帧，预览实际发布间隔最短0.502790秒。修正配准画布收窄、跨帧资源保留和预览节流/取消重入；此前自有像素修正已使修复前基线星轨通过，未把原崩溃写成重新复现。Release通过，普通App已恢复；新增源EXIF尺寸字段遗留观察单独记录。[完整结果](2026-11-01-SlowShutter-Fixes.md)。

## 长焦导航专项完成（2026-11-01）

原FULL-014/015/016三项基线已通过；另复现并修正导航内8→16倍后拍照/退出回旧倍率。最终13方法全通过，含原三项、A/M实际文件焦距、28布局/252拖动目标、Live/RAW及导航退出后实录。FULL-004重复录像方法补足实际快门就绪等待后三轮1080p30与前置/拍照恢复通过，未改生产录像。保留新增倍率复现失败及第一轮扩展录像失败；Release通过，普通App已恢复。[验证与指标](2026-11-01-FocusNavigator-Fixes.md)。

## 视频六项专项完成（2026-11-01）

原FULL-004/017/018/076/077/081最终全部通过，关联FULL-019亦通过；三批9个不同方法0失败/0跳过。原两项未启动录像由实际快门就绪等待修正，记录了主线程switch尚未结束的45/65ms准备，生产录制源码与导航专项一致。真实人物横竖各12秒，文件显示方向正确，抽样均6/6人脸；12组白平衡全解码/恢复/取消通过，开拍p50 39.30ms。Live/HDR/M挡六份实际照片、重复录像、快速模式切换与后台恢复通过；Release通过，普通App已恢复。人物跟随平滑/多人和持续热稳未量化，原失败证据保留。[完整记录](2026-11-01-Video-Six-Fixes.md)。

## 其他六项专项完成（2026-11-01）

FULL-002/035/039/072/073/082六个方法全部定向通过；最终4批12个不同方法全通过、0跳过，163.627秒。修正顶部滑条绘制/触摸浮层，真手势160次变化确认；测试累计计数、48MP准备等待与第二相机页生命周期同步修正，保留基线和中间失败。后置真人两张、自动微距三张、EXIF与实际48MP输出通过；Release通过，普通App已恢复。焦段点击与保存设置亦在最终组关联通过。未全量重跑，分割稳定率和长期热稳仍为验收边界。[记录](2026-11-01-Other-Six-Fixes.md)。
