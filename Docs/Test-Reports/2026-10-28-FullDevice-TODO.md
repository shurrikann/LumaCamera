# 2026-10-28 真机全量：独立失败与待确认问题

> **后续修正：12项定向通过，横屏人物效果仍待有效场景验收。** 慢门崩溃、实际曝光、固定视频帧率及HDR尺寸联动等详见[修正报告](2026-10-28-FailureResolution.md)，旧失败证据保留。

> **2026-10-28逐项复验完成：65通过、11断言失败、2崩溃。** 原失败证据保留；独立通过不等于原连续全量根因已修复。详见[复验报告](2026-10-28-FailureRecheck.md)。

本次与2026-10-24及此前待办分开。671项：579通过、78失败、14跳过；未修复、未复测。失败以方法计数；大量后半段失败伴随会话未就绪/无新帧，不能视为78个独立产品缺陷。[测试范围、优先级及性能](2026-10-28-FullDevice.md)。

## 本轮失败方法

### FULL-20261028-001 — AutomaticLensStabilityPhysicalTests/testAutomaticModeUsesSystemVirtualCameraCandidatesAndWheelRetainsFullRange

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 9.364 秒。
- 日志 L543：`XCTAssertTrue failed`
- 日志 L544：`XCTAssertTrue failed`
- 日志 L545：`XCTAssertNotNil failed`
- 日志 L546：`XCTAssertTrue failed`
- 日志 L547：`XCTAssertTrue failed`
- 日志 L548：`XCTAssertTrue failed`
- 日志 L549：`XCTAssertTrue failed`
- 日志 L550：`XCTAssertTrue failed`
- 日志 L551：`XCTAssertTrue failed`
- 日志 L552：`XCTAssertTrue failed`
- 日志 L553：`XCTAssertTrue failed`
- 日志 L554：`XCTAssertTrue failed`
- 日志 L555：`XCTAssertTrue failed`
- 日志 L556：`XCTAssertTrue failed`
- 日志 L557：`XCTAssertTrue failed`
- 日志 L558：`XCTAssertTrue failed`
- 日志 L559：`XCTAssertTrue failed`
- 日志 L560：`XCTAssertTrue failed`
- 日志 L561：`XCTAssertTrue failed`
- 日志 L562：`XCTAssertTrue failed`
- 日志 L563：`XCTAssertTrue failed`
- 日志 L564：`XCTAssertEqual failed: ("[__C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInWideAngleCamera), __C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInUltraWideCamera)]") is not equal to ("[]")`
- 日志 L565：`XCTAssertEqual failed: ("[__C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInUltraWideCamera), __C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInWideAngleCamera)]") is not equal to ("[]")`
- 日志 L566：`XCTAssertEqual failed: ("[__C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInUltraWideCamera), __C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInWideAngleCamera)]") is not equal to ("[]")`
- 日志 L567：`XCTAssertEqual failed: ("[__C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInUltraWideCamera), __C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInWideAngleCamera)]") is not equal to ("[]")`
- 日志 L568：`XCTAssertEqual failed: ("[__C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInUltraWideCamera), __C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInWideAngleCamera)]") is not equal to ("[]")`
- 日志 L569：`XCTAssertEqual failed: ("[__C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInUltraWideCamera), __C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInWideAngleCamera)]") is not equal to ("[]")`
- 日志 L570：`XCTAssertEqual failed: ("[__C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInWideAngleCamera), __C.AVCaptureDeviceType(_rawValue: AVCaptureDeviceTypeBuiltInUltraWideCamera)]") is not equal to ("[]")`
- 日志 L571：`XCTAssertFalse failed`
- 日志 L572：`XCTAssertTrue failed`
- 日志 L573：`XCTAssertTrue failed`
- 日志 L574：`XCTAssertEqual failed: ("0") is not equal to ("1")`
- 日志 L596：`XCTAssertTrue failed`
- 日志 L597：`XCTAssertTrue failed`

### FULL-20261028-002 — AutomaticWhiteBalanceExposureTests/testAutomaticWhiteBalanceRemainsAutomaticDuringManualISOSweep

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 9.315 秒。
- 日志 L830：`XCTAssertEqualWithAccuracy failed: ("6655.2001953125") is not equal to ("7680.0") +/- ("153.6")`

### FULL-20261028-003 — BasicVideoPhysicalTests/testTimeLapseRecordingCreatesSparseSilentMovie

- 后续处理（本轮）：**定向通过**。延时人流预设现为1秒采样，2.2秒正确输出3帧/0.1秒；更新旧4帧断言，并新增两次真实3帧自动停止验收。

- 本轮独立复验：**仍失败/目标前提未满足**。延时短片实际3帧/0.1秒，用例要求至少4帧且大于0.1秒；应先核对启动窗口、采样间隔与测试边界。
- [ ] 未处理/未复测；耗时 3.334 秒。
- 日志 L1001：`XCTAssertGreaterThan failed: ("0.1") is not greater than ("0.1")`
- 日志 L1002：`XCTAssertGreaterThanOrEqual failed: ("3") is less than ("4")`

### FULL-20261028-004 — DualCapturePhysicalTests/testEngineDualCaptureRecordingSwapAndOrdinaryRecovery

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 16.176 秒。
- 日志 L3510：`XCTAssertTrue failed`
- 日志 L3520：`XCTAssertTrue failed`
- 日志 L3531：`XCTAssertTrue failed`
- 日志 L3568：`XCTAssertFalse failed - 小窗与声音/容量HUD重叠`

### FULL-20261028-005 — DualCapturePhysicalTests/testInactiveDualCaptureEntryIsVisibleInsideLensRegion

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 1.586 秒。
- 日志 L3618：`XCTUnwrap failed: expected non-nil value of type "CGRect"`

### FULL-20261028-006 — FilterEditorPhysicalTests/testRepeatedFilterEditingResetsAndFormatChangesStayBoundedAndRecover

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 33.635 秒。
- 日志 L3876：`XCTAssertLessThan failed: ("730075112") is not less than ("693636736") - Unbounded memory growth during edits`

### FULL-20261028-007 — FocusNavigatorPhysicalTests/testLiveAndRawPhotoPipelineRestoresAfterNavigation

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 30.400 秒。
- 日志 L4175：`failed - 8倍 `
- 日志 L4176：`failed: caught error: "CancellationError()"`

### FULL-20261028-008 — FocusNavigatorPhysicalTests/testManualCaptureMetadataAndMovableNavigatorLayout

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.944 秒。
- 日志 L4200：`failed - 导航 `
- 日志 L4201：`failed: caught error: "InvalidTransition { `

### FULL-20261028-009 — FocusNavigatorPhysicalTests/testPhotoNavigatorThresholdCaptureAndVideoExit

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 19.267 秒。
- 日志 L4228：`failed - 照片8倍导航 reason=nil message=nil state=["zoom": "12.800000190734863", "frames": "0", "pressureCost": "-1.0", "session": "true", "renderSeconds": "0.0", "active": "false", "hardwareCost": "-1.0"]`
- 日志 L4229：`failed: caught error: "CancellationError()"`

### FULL-20261028-010 — FrontVideoCenteringPhysicalTests/testCenterStagePersonLandscapeRecording

- 后续处理（本轮）：**横屏方向已通过，人物效果待验收**。用户确认方向锁定开启；关闭后已读到横屏并正确录制1920×1080显示画面。首轮附件手指遮挡，未检出人物；最后状态见本报告。

- 本轮独立复验：**仍失败/目标前提未满足**。两轮均未通过UIDevice横屏姿态前置判断，未录制；用户已配合横拿，姿态读取/测试前提仍待定位，不能判定实际跟随效果。
- [ ] 未处理/未复测；耗时 22.171 秒。
- 日志 L4637：`failed - 真实手持方向 前置照片宽高比切换失败：Operation Interrupted`
- 日志 L4638：`failed: caught error: "CancellationError()"`

### FULL-20261028-011 — FrontVideoCenteringPhysicalTests/testCenterStagePersonPortraitRecording

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 17.589 秒。
- 日志 L4672：`XCTAssertGreaterThan failed: ("0") is not greater than ("0") - 需要实际人物样本，不能将无人物场景算作跟随验收`

### FULL-20261028-012 — NightCapturePhysicalTests/testThreeNightCapturesCompleteInMemoryAndReportHonestMergeState

- 后续处理（本轮）：**定向通过**。原差异为EXIF浮点焦距约7.18e-10mm；以1e-6容差比较实际数字，未放宽缺失字段和融合断言。

- 本轮独立复验：**仍失败/目标前提未满足**。焦距6.764999865652793与6.764999866370901精确相等断言失败，差约7.18e-10mm；照片采集/融合已完成，疑似浮点容差问题。
- [ ] 未处理/未复测；耗时 9.837 秒。
- 日志 L9142：`XCTAssertEqual failed: ("Optional(6.764999865652793)") is not equal to ("Optional(6.764999866370901)")`

### FULL-20261028-013 — PhysicalCameraSwitchingTests/testManualPresetsThenAutomaticModeOnPhysicalCamera

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 22.741 秒。
- 日志 L10121：`XCTAssertFalse failed`
- 日志 L10122：`XCTAssertFalse failed`
- 日志 L10123：`XCTAssertFalse failed`
- 日志 L10124：`XCTAssertFalse failed`
- 日志 L10125：`XCTAssertFalse failed`
- 日志 L10126：`XCTAssertFalse failed`
- 日志 L10127：`XCTAssertFalse failed`
- 日志 L10128：`XCTAssertFalse failed`
- 日志 L10129：`XCTAssertFalse failed`
- 日志 L10130：`XCTAssertFalse failed`
- 日志 L10131：`XCTAssertFalse failed`
- 日志 L10132：`XCTAssertFalse failed`
- 日志 L10133：`XCTAssertFalse failed`
- 日志 L10134：`XCTAssertFalse failed`
- 日志 L10135：`XCTAssertFalse failed`
- 日志 L10136：`XCTAssertFalse failed`
- 日志 L10137：`XCTAssertFalse failed`
- 日志 L10138：`XCTAssertFalse failed`
- 日志 L10139：`XCTAssertFalse failed`
- 日志 L10140：`XCTAssertFalse failed`
- 日志 L10141：`XCTAssertFalse failed`
- 日志 L10142：`XCTAssertFalse failed`
- 日志 L10143：`XCTAssertFalse failed`
- 日志 L10144：`XCTAssertFalse failed`
- 日志 L10145：`XCTAssertFalse failed`
- 日志 L10146：`XCTAssertFalse failed`
- 日志 L10147：`XCTAssertFalse failed`
- 日志 L10148：`XCTAssertFalse failed`
- 日志 L10149：`XCTAssertFalse failed`
- 日志 L10150：`XCTAssertFalse failed`
- 日志 L10151：`XCTAssertFalse failed`
- 日志 L10152：`XCTAssertFalse failed`
- 日志 L10153：`XCTAssertFalse failed`
- 日志 L10154：`XCTAssertFalse failed`
- 日志 L10155：`XCTAssertFalse failed`
- 日志 L10156：`XCTAssertFalse failed`
- 日志 L10157：`XCTAssertFalse failed`
- 日志 L10158：`XCTAssertFalse failed`
- 日志 L10159：`XCTAssertFalse failed`
- 日志 L10160：`XCTAssertFalse failed`
- 日志 L10161：`XCTAssertFalse failed`
- 日志 L10162：`XCTAssertFalse failed`
- 日志 L10163：`XCTAssertFalse failed`
- 日志 L10164：`XCTAssertFalse failed`
- 日志 L10165：`XCTAssertFalse failed`
- 日志 L10166：`XCTAssertFalse failed`
- 日志 L10167：`XCTAssertFalse failed`
- 日志 L10168：`XCTAssertFalse failed`
- 日志 L10169：`XCTAssertFalse failed`
- 日志 L10170：`XCTAssertFalse failed`
- 日志 L10171：`XCTAssertFalse failed`
- 日志 L10172：`XCTAssertFalse failed`
- 日志 L10173：`XCTAssertFalse failed`
- 日志 L10174：`XCTAssertFalse failed`
- 日志 L10175：`XCTAssertFalse failed`
- 日志 L10176：`XCTAssertFalse failed`
- 日志 L10177：`XCTAssertFalse failed`
- 日志 L10178：`XCTAssertFalse failed`
- 日志 L10179：`XCTAssertFalse failed`
- 日志 L10180：`XCTAssertFalse failed`

### FULL-20261028-014 — PortraitCapturePhysicalTests/testAutomaticMacroSuspendsPortraitCaptureAndRecovers

- 后续处理（本轮）：**定向通过**。修正用例仅开引擎未开模型的人像状态前提；通过真实入口后，现场自然超广角微距三次拍摄、人像暂停和恢复通过；未强制镜头。

- 本轮独立复验：**仍失败/目标前提未满足**。用户准备5–10cm纹理物体后仍未观察到系统主供图切超广角；微距暂停人像分支未覆盖，触发条件/路线待定位。
- [ ] 未处理/未复测；耗时 9.550 秒。
- 日志 L10386：`XCTAssertTrue failed - 近距回归必须观察到系统主动选择超广角；请保持近处有纹理主体`

### FULL-20261028-015 — PortraitOptimizationPhysicalTests/testFrontPortraitContinuousAdjustmentAndCapture

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 11.509 秒。
- 日志 L10645：`XCTAssertGreaterThan failed: ("0") is not greater than ("0") - 需真实人物入镜才能验收人物分割，不能把空背景记为通过`

### FULL-20261028-016 — PortraitOptimizationPhysicalTests/testRearPortraitContinuousAdjustmentAndCapture

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 10.129 秒。
- 日志 L10721：`XCTAssertGreaterThan failed: ("0") is not greater than ("0") - 需真实人物入镜才能验收人物分割，不能把空背景记为通过`

### FULL-20261028-017 — PreviewExposureAssistPhysicalTests/testOrdinarySmoothPreviewLongAndShortExposureFiles

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 31.448 秒。
- 日志 L10852：`Asynchronous wait failed: Exceeded timeout of 30 seconds, with unfulfilled expectations: "普通曝光成片".`
- 日志 L10853：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机已停止，未完成拍摄。`

### FULL-20261028-018 — PreviewExposureAssistPhysicalTests/testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure

- 后续处理（本轮）：**定向通过**。M挡无预设仍启用慢门流畅预览优化；测试按新版A预设/M无预设契约进入，实际文件曝光与恢复通过。

- 本轮独立复验：**仍失败/目标前提未满足**。进入慢门后的预览曝光上限0.25s（断言<=约0.0353s）、requestedISO/Seconds为空，后续恢复断言亦失败；用例仍按M挡进入慢门后保持手动的旧前提，需结合新A/M规则核对，暂不裁定为单一功能缺陷。
- [ ] 未处理/未复测；耗时 10.354 秒。
- 日志 L10877：`failed - 相机已停止，未完成拍摄。`

### FULL-20261028-019 — PreviewExposureAssistPhysicalTests/testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 10.460 秒。
- 日志 L10901：`failed - 相机已停止，未完成拍摄。`

### FULL-20261028-020 — PreviewExposureAssistPhysicalTests/testSmoothPreviewRemainsPhotoOnlyAcrossVideoAndLifecycleChanges

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 7.631 秒。
- 日志 L10926：`failed - 预览辅助硬件状态未在 6 秒内达到目标：preview-state`
- 日志 L10927：`failed: caught error: "InvalidTransition { `

### FULL-20261028-021 — ProResCompatibilityPhysicalTests/testActualCameraFrameEncodesWithAllConventionalProfiles

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 6.188 秒。
- 日志 L10956：`XCTUnwrap failed: expected non-nil value of type "CVBufferRef"`

### FULL-20261028-022 — ProResRAWPhysicalTests/testRAWMetadataAfterWhiteBalanceLockWithoutWritingFiles

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 5.049 秒。
- 日志 L11260：`XCTAssertTrue failed`
- 日志 L11261：`failed - RAW white balance completion did not arrive`

### FULL-20261028-023 — ProToneCapturePhysicalTests/testAllProTonesAreUsedByActualHDRHEIFProCaptureWithoutSaving

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 55.808 秒。
- 日志 L11310：`Asynchronous wait failed: Exceeded timeout of 35 seconds, with unfulfilled expectations: "HDR HEIF Pro 自然影调".`
- 日志 L11311：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机已停止，未完成拍摄。`

### FULL-20261028-024 — RecordingEdgeLayoutPhysicalTests/testFrontButtonGroupsStayCenteredAndRecordingPanelsUsePreviewEdges

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 12.086 秒。
- 日志 L11368：`failed - 启动`
- 日志 L11369：`failed: caught error: "InvalidTransition { `

### FULL-20261028-025 — RecordingEdgeLayoutPhysicalTests/testRealRecordingUsesEdgePositionsAndStopsCleanly

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 15.102 秒。
- 日志 L11396：`failed - 启动 相机已停止，未完成拍摄。`
- 日志 L11397：`failed: caught error: "InvalidTransition { `

### FULL-20261028-026 — ShootingModeButtonTests/testActivePhotoAndVideoSubmodesUpdateEntryIcon

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.090 秒。
- 日志 L11427：`failed - Expected camera.fill, actual camera.fill, message=相机已停止，未完成拍摄。`
- 日志 L11428：`failed: caught error: "InvalidTransition { `

### FULL-20261028-027 — SilentShutterPhysicalTests/testNativeShutterSuppressionAcrossFormatsAndLiveWithoutSaving

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 76.786 秒。
- 日志 L11481：`XCTAssertTrue failed`
- 日志 L11482：`XCTAssertEqual failed: ("0") is not equal to ("1") - Capture must be accepted before waiting for completion`
- 日志 L11483：`Asynchronous wait failed: Exceeded timeout of 45 seconds, with unfulfilled expectations: "Shutter sound capture JPG".`
- 日志 L11484：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机已停止，未完成拍摄。`

### FULL-20261028-028 — SilentShutterPhysicalTests/testNightBatchesUseSilentPreferenceAndReleaseCaptureTasks

- 后续处理（本轮）：**定向通过**。夜景批次诊断通知改到真正提交设置后，批次[3,6]均可取得本次静音设置；没有改夜景融合算法。

- 本轮独立复验：**仍失败/目标前提未满足**。实际批次[3,6]完整，任务清空；静音状态快照仅收到1次而断言要求2次。不是少采一批，回调时序/验证方式待定位。
- [ ] 未处理/未复测；耗时 55.031 秒。
- 日志 L11508：`Asynchronous wait failed: Exceeded timeout of 40 seconds, with unfulfilled expectations: "静音夜景真实6帧".`
- 日志 L11509：`XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机已停止，未完成拍摄。`

### FULL-20261028-029 — SlowMotionLensTransitionPhysicalTests/testSlowMotionFocalSwitchLatencyAndRecording

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 58.827 秒。
- 日志 L11536：`XCTAssertEqual failed: ("nil") is not equal to ("Optional(LumaCamera.VideoFrameRate.fps120)")`
- 日志 L11537：`XCTAssertEqual failed: ("nil") is not equal to ("Optional(LumaCamera.VideoFrameRate.fps120)")`
- 日志 L11540：`XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:0:1.0000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:5:1.0000")`
- 日志 L11541：`XCTAssertNotEqual failed: ("Optional(E5F8BB87-AB7F-4180-8F6B-3102D492DFCB)") is equal to ("Optional(E5F8BB87-AB7F-4180-8F6B-3102D492DFCB)")`
- 日志 L11542：`failed: caught error: "InvalidTransition { `

### FULL-20261028-030 — SlowShutterPresetTests/testPresetSlotsAlignWithFocalSlotsAndSurviveRapidToggleOnDevice

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 15.105 秒。
- 日志 L11662：`failed - The app's live camera session did not deliver a fresh preview frame within 15 seconds; message=当前镜头无法启用慢动作`

### FULL-20261028-031 — SlowShutterPresetTests/testSlowShutterAllowsSwitchingRearLenses

- 后续处理（本轮）：**定向通过**。预设仅A挡可选，同一预设再次点击为取消；M挡保留慢门并清空预设；按该新版契约验证切镜。

- 本轮独立复验：**仍失败/目标前提未满足**。慢门M挡选择/切镜后selectedPreset=nil，旧断言要求保留预设；与当天文档“M挡清除/隐藏预设”新契约冲突，应核对用例。
- [ ] 未处理/未复测；耗时 15.086 秒。
- 日志 L11706：`failed - Live camera did not become ready`

### FULL-20261028-032 — SlowShutterSequencePhysicalTests/testAdaptiveOtherPresetsAutomaticFullSequences

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.124 秒。
- 日志 L11752：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L11753：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-033 — SlowShutterSequencePhysicalTests/testAdaptiveOtherPresetsManualEarlyFinishAndCancellation

- 后续处理（本轮）：**定向通过**。创建和提交手动包围曝光前都检查设备custom能力与当前格式具体时长/ISO支持，避免NSInvalidArgumentException；最终定向完整流程通过。

- 本轮独立复验：**真实崩溃**。真实崩溃：光轨、动态模糊后进入摇拍，手动包围曝光请求在当前format不支持时触发NSInvalidArgumentException。
- [ ] 未处理/未复测；耗时 20.134 秒。
- 日志 L11783：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L11784：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-034 — SlowShutterSequencePhysicalTests/testAdaptiveStarTrailsFullDuration

- 后续处理（本轮）：**定向通过**。星轨顶部默认时长已为60秒，测试使用当前所选时长重算而非旧120秒；完整采集通过。

- 本轮独立复验：**仍失败/目标前提未满足**。完整星轨实际约60秒并出片，旧断言要求>=119.95秒；与新默认60秒冲突，需更新测试契约。
- [ ] 未处理/未复测；耗时 20.111 秒。
- 日志 L11814：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L11815：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-035 — SlowShutterSequencePhysicalTests/testAdaptiveWaterAutomaticAndManualRestoration

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.104 秒。
- 日志 L11845：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L11846：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-036 — SlowShutterSequencePhysicalTests/testAdaptiveWaterEarlyFinishCancelAndRestart

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.124 秒。
- 日志 L11876：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L11877：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-037 — SlowShutterSequencePhysicalTests/testAdaptiveWaterSceneExposureWithJPEG

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.084 秒。
- 日志 L11907：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L11908：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-038 — SlowShutterSequencePhysicalTests/testAutomaticLightTrailsAndWaterCompleteOrRejectUnsafeExposure

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.119 秒。
- 日志 L11938：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L11939：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-039 — SlowShutterSequencePhysicalTests/testAutomaticNewPresetsPreserveModeAndValidateMeteredExposure

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.134 秒。
- 日志 L11969：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L11970：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-040 — SlowShutterSequencePhysicalTests/testAutomaticSequencesWithMeteredExposureCompensation

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.092 秒。
- 日志 L12000：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L12001：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-041 — SlowShutterSequencePhysicalTests/testEarlyFinishCancellationAndRepeatedSelectionRecover

- 后续处理（本轮）：**定向通过**。同033防异常；首帧延后到主线程生命周期指令与会话队列屏障后提交，防止取消/返回遗留stop吞掉新请求；提前结束、取消、重启及10次快速选择通过。

- 本轮独立复验：**真实崩溃**。真实崩溃：提前结束/取消及重新选择流程同样触发不支持手动包围曝光的NSInvalidArgumentException。
- [ ] 未处理/未复测；耗时 20.089 秒。
- 日志 L12031：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L12032：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-042 — SlowShutterSequencePhysicalTests/testManualBracketSpeedComparisonAndRepeatedCapture

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.104 秒。
- 日志 L12062：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L12063：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-043 — SlowShutterSequencePhysicalTests/testManualLightTrailsAndWaterCompleteWithMetadata

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.089 秒。
- 日志 L12093：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L12094：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-044 — SlowShutterSequencePhysicalTests/testManualMotionBlurCompletesWithShortSourceExposures

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.113 秒。
- 日志 L12124：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L12125：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-045 — SlowShutterSequencePhysicalTests/testPanningLatencyWithAndWithoutPreviewAssist

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.087 秒。
- 日志 L12155：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L12156：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-046 — SlowShutterSequencePhysicalTests/testSingleFramePresetsCaptureRequestedExposureWithoutStartingSequence

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.105 秒。
- 日志 L12186：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L12187：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-047 — SlowShutterSequencePhysicalTests/testStarTrailsEarlyFinishCancellationAndRepeatedSelection

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.126 秒。
- 日志 L12217：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L12218：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-048 — SlowShutterSequencePhysicalTests/testStarTrailsFull120FrameStreamingSequence

- 后续处理（本轮）：**定向通过**。同034，按顶部60秒执行流式合成，实际采集约61.34秒；保留旧120名称作为历史测试标识。

- 本轮独立复验：**仍失败/目标前提未满足**。完整星轨实际约60秒并出片，旧断言要求>=119.95秒；同034的新旧时长契约冲突。
- [ ] 未处理/未复测；耗时 20.113 秒。
- 日志 L12248：`failed - 诊断相机没有出帧; message=none progress=nil`
- 日志 L12249：`failed: caught error: "Error Domain=SlowShutterPhysicalTest Code=1 "(null)""`

### FULL-20261028-049 — Smart48CompatibilityTests/test48MPSmartFramingHDRAndNightBoundaries

- 后续处理（本轮）：**定向通过**。HDR真实RAW输入为4032×3024，输出3024×4032 PQ10bit；记录本镜头本会话观测并回落12MP，关闭相应HEIF HDR高像素选择；普通SDR仍实际6000×8000。不是证明所有设备HDR均不支持48MP。

- 本轮独立复验：**仍失败/目标前提未满足**。JPG48实际6000×8000；应用HDR建议后HEIF为3024×4032（10bit PQ），随后关闭HDR恢复HEIF48。HDR组合实际降到约12.2MP，UI/能力边界需核对。
- [ ] 未处理/未复测；耗时 37.292 秒。
- 日志 L12298：`failed - 启动 当前镜头无法启用慢动作`
- 日志 L12299：`failed: caught error: "InvalidTransition { `

### FULL-20261028-050 — SmartAutoFramingTests/testAutomaticHardwareFramingOnceAndCancelPendingWork

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 24.950 秒。
- 日志 L12359：`failed - 相机 当前镜头无法启用慢动作`
- 日志 L12360：`failed: caught error: "InvalidTransition { `

### FULL-20261028-051 — SmartAutoFramingTests/testBacklitPortraitWithoutBlurTracksAutomaticOrigin

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 31.234 秒。
- 日志 L12387：`XCTAssertTrue failed`
- 日志 L12388：`XCTAssertTrue failed`
- 日志 L12389：`XCTAssertTrue failed`

### FULL-20261028-052 — SmartAutoFramingTests/testRealSceneGuideAutomaticFramingAndCapture

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 18.755 秒。
- 日志 L12418：`failed - 当前镜头无法启用慢动作`
- 日志 L12419：`failed: caught error: "InvalidTransition { `

### FULL-20261028-053 — SmartCapturePhysicalTests/testRealPreviewAnalysisPerformanceAndStability

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 21.571 秒。
- 日志 L12460：`XCTAssertTrue failed - 当前镜头无法启用慢动作`
- 日志 L12462：`XCTAssertTrue failed`

### FULL-20261028-054 — SmartCompositionGeometryTests/testWhitePointAndThickerRingRendering

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 1.870 秒。
- 日志 L12475：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12476：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12479：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12480：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12483：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12484：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12487：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12488：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12491：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12492：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12495：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12496：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12499：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12500：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12503：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12504：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12507：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12508：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12511：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12512：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12515：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12516：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12519：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12520：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12523：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12524：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12531：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12532：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12535：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12536：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`
- 日志 L12539：`XCTAssertGreaterThan failed: ("0") is not greater than ("220") - 白点中心必须实心`
- 日志 L12540：`XCTAssertGreaterThan failed: ("0") is not greater than ("180") - 圆圈描边应清晰`

### FULL-20261028-055 — VideoCodecPhysicalTests/testActualCodecsAndColorsRepeatedRecording

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 55.482 秒。
- 日志 L12651：`XCTAssertTrue failed`
- 日志 L12652：`XCTAssertTrue failed - 当前镜头无法启用慢动作`
- 日志 L12653：`XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261028-056 — VideoColorPhysicalTests/testAppleLogLUTBurnKeepsLogVideoTagsAndTenBitPixels

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 28.948 秒。
- 日志 L12681：`XCTAssertTrue failed`
- 日志 L12682：`XCTAssertTrue failed - 当前镜头无法启用慢动作`
- 日志 L12683：`XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261028-057 — VideoColorPhysicalTests/testEveryAvailableColorSpaceRecordsRealTagsAndRestoresPhotos

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 40.169 秒。
- 日志 L12709：`XCTAssertTrue failed`
- 日志 L12710：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63063.091719541684")`
- 日志 L12711：`XCTAssertTrue failed - mode=auto color=SDR before=ready=false busy=false configuring=false capturing=false pending=0: 当前镜头无法启用慢动作`
- 日志 L12712：`XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261028-058 — VideoColorPhysicalTests/testLogAndLog2PreviewOnlyAndBurnHaveDifferentEncodedPixels

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 15.058 秒。
- 日志 L12736：`failed - 视频编码/色彩状态等待超时`
- 日志 L12737：`failed: caught error: "InvalidTransition { `

### FULL-20261028-059 — VideoColorPhysicalTests/testSDRAndP3FiltersAreBakedIntoRecordedPixelsWithStableFrameDelivery

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 31.388 秒。
- 日志 L12764：`XCTAssertTrue failed`
- 日志 L12765：`XCTAssertLessThan failed: ("inf") is not less than ("3.0") - The preview should use the same monochrome look as the encoded SDR/P3 movie`
- 日志 L12766：`XCTAssertTrue failed - 当前镜头无法启用慢动作`
- 日志 L12767：`XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261028-060 — VideoMacroIndicatorTests/testMacroIndicatorReplacesPortraitDepthControlAndSliderGrowsUpward

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 1.358 秒。
- 日志 L12945：`XCTAssertNil failed: "(20.0, 553.5594914754231, 40.0, 134.66666666666674)" - 退出微距后滑块保持收起，避免意外重新展开`

### FULL-20261028-061 — VideoModeTransitionTests/testAutomaticVideoRouteRestoresPhotoFormatAndLensSwitching

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 40.012 秒。
- 日志 L13004：`XCTAssertTrue failed`
- 日志 L13005：`XCTAssertTrue failed - 当前镜头无法启用慢动作`
- 日志 L13006：`XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261028-062 — VideoModeTransitionTests/testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 33.641 秒。
- 日志 L13034：`XCTAssertTrue failed`
- 日志 L13043：`XCTAssertTrue failed - Video shutter must become ready for live`
- 日志 L13044：`XCTAssertTrue failed - variant=live: 当前镜头无法启用慢动作`
- 日志 L13045：`XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261028-063 — VideoModeTransitionTests/testRepeatedModeTransitionPreviewLatency

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 30.271 秒。
- 日志 L13069：`XCTAssertTrue failed`
- 日志 L13070：`XCTAssertNotNil failed - Preview must resume after switching to video`
- 日志 L13072：`XCTAssertNotNil failed - Preview must resume after switching to photo`
- 日志 L13074：`XCTAssertNotNil failed - Preview must resume after switching to video`
- 日志 L13076：`XCTAssertNotNil failed - Preview must resume after switching to photo`
- 日志 L13078：`XCTAssertNotNil failed - Preview must resume after switching to video`
- 日志 L13080：`XCTAssertNotNil failed - Preview must resume after switching to photo`

### FULL-20261028-064 — VideoSpecificationTests/testAllSupportedVideoSpecificationsWriteMatchingTracks

- 后续处理（本轮）：**定向通过**。固定规格关闭自动帧率，检查官方锁帧能力；换格式/帧率先释放旧锁再设置。18种720p/1080p/4K与24/25/30/50/60/120实际编码/解码时间戳通过。

- 本轮独立复验：**仍失败/目标前提未满足**。720p/1080p所选30fps实际24fps、所选60fps实际50fps；输入和完整解码PTS均支持差异，notReady/appendRejected为0。25fps也实际24fps但落在当前宽容差内。4K 24/25/30/50/60/120对应正确。
- [ ] 未处理/未复测；耗时 34.530 秒。
- 日志 L13143：`XCTAssertTrue failed - 当前镜头无法启用慢动作`
- 日志 L13144：`XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261028-065 — VideoSpecificationTests/testCinematicOutputGraphsAgainstAppleCapturePatternOnDevice

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 12.478 秒。
- 日志 L13154：`XCTAssertTrue failed - AppleMovieFileOutput+Metadata+Photo running=false startMs=2020.459542 runtimeErrors=[]`

### FULL-20261028-066 — VideoSpecificationTests/testHighFrameRateAndFrontCameraRestoreSupportedSpecifications

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 10.008 秒。
- 日志 L13183：`failed - 相机启动: 当前镜头无法启用慢动作`
- 日志 L13184：`failed: caught error: "InvalidTransition { `

### FULL-20261028-067 — VideoSpecificationTests/testOpenGateSwitchRecordsOnlyFourByThreeOrSquareOnDevice

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 28.686 秒。
- 日志 L13215：`XCTAssertTrue failed - 当前镜头无法启用慢动作`
- 日志 L13216：`XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261028-068 — VideoSpecificationTests/testRenderedVideoPreviewCadenceTracksSupportedRates

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 122.618 秒。
- 日志 L13240：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63395.779974208344")`
- 日志 L13241：`XCTAssertGreaterThan failed: ("0") is not greater than ("8") - No preview frames for selected 24 fps`
- 日志 L13242：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63405.173917083346")`
- 日志 L13243：`XCTAssertGreaterThan failed: ("0") is not greater than ("8") - No preview frames for selected 25 fps`
- 日志 L13244：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63414.378719958346")`
- 日志 L13245：`XCTAssertGreaterThan failed: ("0") is not greater than ("8") - No preview frames for selected 30 fps`
- 日志 L13246：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63423.38527466668")`
- 日志 L13247：`XCTAssertGreaterThan failed: ("0") is not greater than ("8") - No preview frames for selected 50 fps`
- 日志 L13248：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63432.56345250001")`
- 日志 L13249：`XCTAssertGreaterThan failed: ("0") is not greater than ("8") - No preview frames for selected 60 fps`
- 日志 L13251：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63441.852288750015")`
- 日志 L13252：`XCTAssertGreaterThan failed: ("0") is not greater than ("30") - No high-frame-rate preview frames`
- 日志 L13253：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63451.65870704168")`
- 日志 L13254：`XCTAssertGreaterThan failed: ("0") is not greater than ("30") - No high-frame-rate preview frames`
- 日志 L13255：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63461.528984500015")`
- 日志 L13256：`XCTAssertGreaterThan failed: ("0") is not greater than ("30") - No high-frame-rate preview frames`
- 日志 L13257：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63471.35513487501")`
- 日志 L13258：`XCTAssertGreaterThan failed: ("0") is not greater than ("30") - No high-frame-rate preview frames`
- 日志 L13259：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63481.27672312501")`
- 日志 L13260：`XCTAssertGreaterThan failed: ("0") is not greater than ("30") - No high-frame-rate preview frames`
- 日志 L13261：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63491.10748058335")`
- 日志 L13262：`XCTAssertGreaterThan failed: ("0") is not greater than ("30") - No high-frame-rate preview frames`
- 日志 L13263：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63501.75028579168")`
- 日志 L13264：`XCTUnwrap failed: expected non-nil value of type "Double"`

### FULL-20261028-069 — VideoSpecificationTests/testSlowMotionAndCinematicRoutesOnDevice

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 141.165 秒。
- 日志 L13288：`XCTAssertTrue failed - 当前镜头无法启用慢动作`
- 日志 L13289：`XCTAssertTrue failed`
- 日志 L13290：`XCTAssertTrue failed`
- 日志 L13311：`XCTAssertTrue failed - 当前镜头无法启用慢动作 running=false runtimeErrors=0 outputs=AVCapturePhotoOutput,AVCaptureVideoDataOutput,AVCaptureAudioDataOutput,AVCaptureVideoDataOutput input=AVCaptureDeviceTypeBuiltInTripleCamera:com.apple.avfoundation.avcapturedevice.built-in_video:7 active=1920x1080 ranges=["1...30"] requested=1080p/30/capturenil cinematicRequested=false cinematic=false/false`
- 日志 L13312：`XCTAssertEqual failed: ("nil") is not equal to ("Optional(LumaCamera.VideoFrameRate.fps120)") - running=false runtimeErrors=0 outputs=AVCapturePhotoOutput,AVCaptureVideoDataOutput,AVCaptureAudioDataOutput,AVCaptureVideoDataOutput input=AVCaptureDeviceTypeBuiltInTripleCamera:com.apple.avfoundation.avcapturedevice.built-in_video:7 active=1920x1080 ranges=["1...30"] requested=1080p/30/capturenil cinematicRequested=false cinematic=false/false`
- 日志 L13313：`XCTAssertTrue failed - 当前镜头无法启用慢动作 running=false runtimeErrors=0 outputs=AVCapturePhotoOutput,AVCaptureVideoDataOutput,AVCaptureAudioDataOutput,AVCaptureVideoDataOutput input=AVCaptureDeviceTypeBuiltInTripleCamera:com.apple.avfoundation.avcapturedevice.built-in_video:7 active=1920x1080 ranges=["1...30"] requested=1080p/30/capturenil cinematicRequested=false cinematic=false/false`
- 日志 L13314：`XCTAssertEqual failed: ("nil") is not equal to ("Optional(LumaCamera.VideoFrameRate.fps120)") - running=false runtimeErrors=0 outputs=AVCapturePhotoOutput,AVCaptureVideoDataOutput,AVCaptureAudioDataOutput,AVCaptureVideoDataOutput input=AVCaptureDeviceTypeBuiltInTripleCamera:com.apple.avfoundation.avcapturedevice.built-in_video:7 active=1920x1080 ranges=["1...30"] requested=1080p/30/capturenil cinematicRequested=false cinematic=false/false`
- 日志 L13315：`XCTAssertTrue failed - 当前镜头无法启用电影效果 running=false runtimeErrors=0 outputs=AVCapturePhotoOutput,AVCaptureVideoDataOutput,AVCaptureAudioDataOutput,AVCaptureVideoDataOutput input=AVCaptureDeviceTypeBuiltInTripleCamera:com.apple.avfoundation.avcapturedevice.built-in_video:7 active=1920x1080 ranges=["1...30"] requested=1080p/30/capturenil cinematicRequested=false cinematic=false/false`
- 日志 L13316：`XCTAssertTrue failed - The attached input must support and enable Cinematic: running=false runtimeErrors=0 outputs=AVCapturePhotoOutput,AVCaptureVideoDataOutput,AVCaptureAudioDataOutput,AVCaptureVideoDataOutput input=AVCaptureDeviceTypeBuiltInTripleCamera:com.apple.avfoundation.avcapturedevice.built-in_video:7 active=1920x1080 ranges=["1...30"] requested=1080p/30/capturenil cinematicRequested=false cinematic=false/false`
- 日志 L13317：`XCTAssertNotEqual failed: ("Optional(E5F8BB87-AB7F-4180-8F6B-3102D492DFCB)") is equal to ("Optional(E5F8BB87-AB7F-4180-8F6B-3102D492DFCB)") - Preview must contain a frame from the new configuration`
- 日志 L13318：`XCTAssertTrue failed - Cinematic session stopped after activation: running=false runtimeErrors=0 outputs=AVCapturePhotoOutput,AVCaptureVideoDataOutput,AVCaptureAudioDataOutput,AVCaptureVideoDataOutput input=AVCaptureDeviceTypeBuiltInTripleCamera:com.apple.avfoundation.avcapturedevice.built-in_video:7 active=1920x1080 ranges=["1...30"] requested=1080p/30/capturenil cinematicRequested=false cinematic=false/false`
- 日志 L13319：`XCTAssertEqual failed: ("5") is not equal to ("4")`
- 日志 L13320：`XCTAssertGreaterThan failed: ("61992.34101054168") is not greater than ("63631.97303637501")`
- 日志 L13321：`XCTAssertTrue failed - 当前镜头无法启用电影效果`
- 日志 L13322：`XCTUnwrap failed: expected non-nil value of type "URL" - Cinematic movie did not finish`

### FULL-20261028-070 — VideoVirtualAperturePhysicalTests/testVideoEntryLayoutRecordingAndRecovery

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.098 秒。
- 日志 L13396：`failed - 相机 当前镜头无法启用电影效果`
- 日志 L13397：`failed: caught error: "InvalidTransition { `

### FULL-20261028-071 — VideoWhiteBalancePhysicalTests/testVideoWhiteBalanceLockIsOptionalAndRestoredAfterRecording

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 22.728 秒。
- 日志 L13427：`XCTAssertTrue failed - 当前镜头无法启用电影效果`
- 方法内部另有跳过提示（最终仍失败）：Rear camera HEVC SDR 1080p30 route unavailable after wait; count=75

### FULL-20261028-072 — VideoWorkflowTests/testImmediateCancelDuringWhiteBalanceStartupCompletesExactlyOnce

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.228 秒。
- 日志 L13474：`XCTAssertTrue failed`
- 日志 L13475：`XCTAssertEqual failed: ("0") is not equal to ("1") - 白平衡锁定等待期间取消也必须结束一次`
- 日志 L13476：`XCTAssertEqual failed: ("0.411412500005099") is not equal to ("0.0")`

### FULL-20261028-073 — VideoWorkflowTests/testLifecycleStopFreezesClockAndRapidModeRequestsCoalesce

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 10.062 秒。
- 日志 L13500：`failed - 恢复新帧: 当前镜头无法启用电影效果`
- 日志 L13501：`failed: caught error: "InvalidTransition { `

### FULL-20261028-074 — VideoWorkflowTests/testTimeLapsePresetBarMatchesFocalBarAndSurvivesRapidChanges

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 8.451 秒。
- 日志 L13547：`XCTAssertTrue failed`

### FULL-20261028-075 — VirtualAperturePhysicalTests/testLensRestrictionsContinuousSliderAndRealPhotoInformation

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 20.125 秒。
- 日志 L13598：`failed - 相机 当前镜头无法启用电影效果`
- 日志 L13599：`failed: caught error: "InvalidTransition { `

### FULL-20261028-076 — VirtualAperturePhysicalTests/testVirtualAperturePreservesAutoTapAndManualFocus

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 15.093 秒。
- 日志 L13626：`failed - 启动`
- 日志 L13627：`failed: caught error: "InvalidTransition { `

### FULL-20261028-077 — WhiteBalanceRouteSafetyTests/testStaleCustomWhiteBalanceDuringRouteChangesDoesNotCrashVirtualCamera

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 16.735 秒。
- 日志 L13682：`XCTAssertTrue failed`
- 日志 L13683：`XCTAssertTrue failed`
- 日志 L13684：`XCTAssertTrue failed`

### FULL-20261028-078 — ZoomWheelReopenPhysicalTests/testReopeningKeepsActualZoomAndAnchorAcrossBothModes

- 本轮独立复验：**通过**；未改相机功能/原断言，未认定原连续问题已修复。
- [ ] 未处理/未复测；耗时 21.077 秒。
- 日志 L13735：`XCTAssertTrue failed`
- 日志 L13736：`XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:0:1.0000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:2:1.0000")`
- 日志 L13737：`XCTAssertEqualWithAccuracy failed: ("1.0") is not equal to ("6.0") +/- ("0.02") - 建立实际 6× 基线后才能验证重开`
- 日志 L13738：`XCTAssertTrue failed`
- 日志 L13739：`XCTAssertTrue failed`
- 日志 L13740：`XCTAssertTrue failed`
- 日志 L13741：`XCTAssertLessThan failed: ("1.0") is not less than ("1.0")`
- 日志 L13742：`XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:0:1.0000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:2:1.0000")`
- 日志 L13743：`XCTAssertEqualWithAccuracy failed: ("1.0") is not equal to ("6.0") +/- ("0.02") - 建立实际 6× 基线后才能验证重开`
- 日志 L13744：`XCTAssertTrue failed`
- 日志 L13745：`XCTAssertTrue failed`
- 日志 L13746：`XCTAssertTrue failed`
- 日志 L13747：`XCTAssertLessThan failed: ("1.0") is not less than ("1.0")`

## 额外诊断待办（不增加失败方法计数）

- [ ] FULL-20261028-OBS-001：Live手动参数反复停启期间的真实AVFoundation -11800 / underlying -12785；日志L6935，方法随后通过，根因未定位。
- [ ] FULL-20261028-OBS-002：2344条MDB_MAP_FULL日志，来源及影响未定位；不能等同于硬盘/照片容量不足。
- [ ] FULL-20261028-OBS-003：智拍几何测试在View外读取Environment的运行警告，核对测试环境与快照像素失败的关系。

## 本轮跳过方法（14）

- `AdaptiveDynamicPhysicalTests/testSavedAdaptiveRAWResourcesByCaptureDate`：拍摄时间内未找到授权可访问的资产，不能推断DNG丢失。
- `AdaptiveDynamicPhysicalTests/testUserBacklitRAWDevelopment`：样片资产中未找到DNG；不能把HEIC当RAW对照。
- `CameraRulerMappingTests/testAMToToolsDoesNotMovePreviewForAnyRatio`：Layout regression is exercised in the simulator。
- `CameraSessionRecoveryTests/testTemporaryInterruptionIsSilentAndEndedCannotRestartStoppedCamera`：Use the shared visible engine for physical recovery tests。
- `NightAdaptiveCapturePhysicalTests/testMNightNaturalTriggerAndManualExposureNormalization`：M挡当前真实场景未达到暗光触发阈值，未冒充自然触发通过。
- `NightAdaptiveCapturePhysicalTests/testNaturallyTriggeredNightUsesActualMeteringAndFrameCount`：实际场景尚未触发夜景，不能记成自然触发通过。
- `PopupAppearanceAndOrientationTests/testPopupOpenCloseDuringOrientationChangesRemainsResponsive`：Full camera UI stress runs in the simulator; the device runs the harness orientation stress。
- `SlowShutterPresetTests/testAutomaticModeKeepsApertureModeAndPresetOnlyCapsAutomaticExposure`：Requires a live camera route; A-mode cap policy is covered by the model tests。
- `SlowShutterPresetTests/testMKeepsSlowModeButClearsAndHidesPreset`：Requires a live camera route。
- `SlowShutterPresetTests/testMShutterSliderUsesSelectedPresetRange`：Requires a live camera route。
- `SlowShutterPresetTests/testSelectingPresetsConstrainsManualExposureAndRepeatedTogglingClearsState`：Requires a live camera route; range/support logic is covered above。
- `SlowShutterPresetTests/testSelectingSamePresetAgainTurnsItOff`：Requires a live camera route。
- `TimeLapseSettingsTests/testCancellingPresetRestoresOneSecondAnd120Frames`：Requires a live camera route。
- `ToolbarHistogramLayoutTests/testAllRatioTransitionsKeepToolbarFixedAndHistogramClear`：Ratio layout is tested in simulator。
