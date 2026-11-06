# 2026-10-28 全量78项失败：逐项真机复验

## 结论

- **原78个失败方法全部执行复验：65项通过、11项断言仍失败、2项真实崩溃。**不是65项功能已修复；本轮没有修改相机功能逻辑或旧用例断言。
- 设备：iPhone 17 Pro / iOS 27.2（24B119），有线、正常项目签名，单机串行，每个方法单独启动测试进程。没有启动模拟器、使用手机镜像或进行无线配对。
- 首批72项自动检查：60通过、9断言失败、2崩溃、1超时。超时的慢门速度对比仅增加测试预算后补验通过，形成最终65/11/2；6项现场用例有用户配合，4通过、2仍未覆盖目标前提。
- 时间：首个失败方法复验14:04:43，最后一项结束14:51:15；含独立进程启动、现场准备和两次有依据的补测，不能与原连续全量耗时直接比较。另有13:59切镜基线及14:03只读隔离自检。
- 65项独立通过与原连续全量失败并不矛盾，说明原失败中存在运行顺序/共享状态/现场前提影响的可能；尚未通过重建原顺序定位具体根因，不把“单项通过”写为原连锁问题已解决。
- [逐项结构化结果](2026-10-28-FailureRecheck-results.json)保留所有原ID、断言、正式xcresult摘要、首轮和补测状态。[原始全量及待办](2026-10-28-FullDevice-TODO.md)保留历史证据，新增本轮状态，不覆盖原记录。

## 本轮测试隔离变化

自动审批因默认录像回调在异常清理时可能写相册，拒绝了未隔离的批量脚本；该脚本未执行。改用更安全的诊断隔离后才继续：

- `AppDependencies` 仅在DEBUG并显式收到 `LUMA_DIAGNOSTIC_READ_ONLY_PHOTOS=1` 时，将未显式注入的默认相册服务替换为只读适配器；六类保存/删除入口直接失败，浏览保留，默认照片/视频迟到回调也无法写入Photos。专用内存替身仍保留原行为。
- 两项隔离自检真机通过（六入口+默认录像+默认照片/录像共9次预期拒绝）；78个测试宿主均有只读启用标记，功能复验中没有额外默认保存拦截记录。没有诊断媒体写入/删除用户相册。
- 变量只存在临时 `ReadOnly.xctestrun`，按Apple本机 `xcodebuild.xctestrun(5)` 的EnvironmentVariables字段传给宿主，不写入正式scheme或偏好。普通启动无此变量、Release无该分支；不影响正常相册保存功能。
- 相比原全量，只改了默认服务的诊断注入和新增两项安全自检；相机、影像、界面逻辑和78项原断言未改。复验开始后源码/测试/项目文件SHA-256无变化。[审计与选择清单](2026-10-28-FailureRecheck-SafetyAudit.md)。

## 仍需处理/确认的13个方法

| 原ID尾号 | 状态 | 观测与判断边界 |
| --- | --- | --- |
| 003 | 断言失败/前提未满足 | 延时短片实际3帧/0.1秒，用例要求至少4帧且大于0.1秒；应先核对启动窗口、采样间隔与测试边界。 |
| 010 | 断言失败/前提未满足 | 两轮均未通过UIDevice横屏姿态前置判断，未录制；用户已配合横拿，姿态读取/测试前提仍待定位，不能判定实际跟随效果。 |
| 012 | 断言失败/前提未满足 | 焦距6.764999865652793与6.764999866370901精确相等断言失败，差约7.18e-10mm；照片采集/融合已完成，疑似浮点容差问题。 |
| 014 | 断言失败/前提未满足 | 用户准备5–10cm纹理物体后仍未观察到系统主供图切超广角；微距暂停人像分支未覆盖，触发条件/路线待定位。 |
| 018 | 断言失败/前提未满足 | 进入慢门后的预览曝光上限0.25s（断言<=约0.0353s）、requestedISO/Seconds为空，后续恢复断言亦失败；用例仍按M挡进入慢门后保持手动的旧前提，需结合新A/M规则核对，暂不裁定为单一功能缺陷。 |
| 028 | 断言失败/前提未满足 | 实际批次[3,6]完整，任务清空；静音状态快照仅收到1次而断言要求2次。不是少采一批，回调时序/验证方式待定位。 |
| 031 | 断言失败/前提未满足 | 慢门M挡选择/切镜后selectedPreset=nil，旧断言要求保留预设；与当天文档“M挡清除/隐藏预设”新契约冲突，应核对用例。 |
| 033 | 崩溃 | 真实崩溃：光轨、动态模糊后进入摇拍，手动包围曝光请求在当前format不支持时触发NSInvalidArgumentException。 |
| 034 | 断言失败/前提未满足 | 完整星轨实际约60秒并出片，旧断言要求>=119.95秒；与新默认60秒冲突，需更新测试契约。 |
| 041 | 崩溃 | 真实崩溃：提前结束/取消及重新选择流程同样触发不支持手动包围曝光的NSInvalidArgumentException。 |
| 048 | 断言失败/前提未满足 | 完整星轨实际约60秒并出片，旧断言要求>=119.95秒；同034的新旧时长契约冲突。 |
| 049 | 断言失败/前提未满足 | JPG48实际6000×8000；应用HDR建议后HEIF为3024×4032（10bit PQ），随后关闭HDR恢复HEIF48。HDR组合实际降到约12.2MP，UI/能力边界需核对。 |
| 064 | 断言失败/前提未满足 | 720p/1080p所选30fps实际24fps、所选60fps实际50fps；输入和完整解码PTS均支持差异，notReady/appendRejected为0。25fps也实际24fps但落在当前宽容差内。4K 24/25/30/50/60/120对应正确。 |

建议优先处理：**033/041同类崩溃 → 064真实帧率差异 → 049 HDR与48MP能力边界**。其余先核对新版契约、异步回调或现场前提，不批量改生产代码以迁就旧断言。

## 两次补测

- 042速度对比：首轮被180秒执行预算中止，正式xcresult为失败（即使控制台曾打印passed也不算通过）。保留首轮；只将预算改为420秒补验，实际187.319秒通过。不是功能性能优化或修改断言。
- 010横屏：第一次未读到横屏姿态，用户进一步举起横拿后补一次，仍卡在同一前置判断；两次都未进入CenterStage录制。停止反复要求用户调姿态，保留为姿态读取/测试前提待定位。
- 两个崩溃方法的Xcode会话有意外退出后的测试宿主重启；没有人工重复触发相同方法，也没有把重启/崩溃算通过。两方法均抛出相同不支持手动包围曝光异常，各有一条QoS优先级倒置警告。

## 性能、稳定性与现场样本

- 每个方法独立进程，保留原方法内快速切换、重复操作和取消恢复；不能因此证明原连续全量顺序的稳定性已恢复。
- 多个名称含Manual的慢门序列用例经新版“开启慢门切A挡”流程后，实际日志记录mode=auto；不能凭方法名称把这些通过记成M挡手动多帧已验收。需结合新契约重审覆盖范围。
- 054绘制方法本轮通过，但xcresult仍记录在View外读取Environment的警告；通过不代表该诊断警告已修复。
- 滤镜压力：2040次更新、31.300秒、829次图像发布；宿主footprint约109→采样峰295→收起157 MiB，满足该用例+256/+128 MiB门限。原连续全量约405→696→531 MiB，本轮未改滤镜代码，差异不能当成优化收益或泄漏已修复。均包含XCTest，不代表独立App内存；图像发布数不是屏幕实际FPS。
- 速度对比每个预设1次基线、3次当前路径（单位秒）：光轨17.002 vs [16.472,16.428,16.316]；流水12.502 vs [11.532,11.526,11.598]；动态模糊6.406 vs [4.502,4.587,4.466]。样本量小、长序列受硬件调度与温度影响，不把此轮作为普适提速比例。
- 前置人像：180次滑块更新，162次图像发布，间隔P95 51.7ms/max87.7ms，分割有效54/54；0/满强度成片回调0.891/1.215秒。
- 后置人像：180次更新，219次发布，间隔P95 46.6ms/max49.5ms，分割有效56/56；两次成片0.774/0.963秒。没有空预览，任务收尾通过；未在本轮重新逐像素验收所有头发/镜框/绿叶边缘，不能宣称复杂人像问题全部解决。
- 前置竖屏CenterStage：系统激活并录制，6/6取样帧检出人脸，371次发布，最大间隔约99.6ms。仅证明该次实际人物录制及方向有效，人脸居中程度、多人或快速运动的跟随观感不能只由这些数值保证；横屏未通过前置姿态判断。
- 智拍真实引导：28次引导更新、1次自动取景，倍率1→1.24374，输出3000×4000/等效30mm；用户配合对齐后完成临时成片。单次成功不能证明所有候选点长期不漂移。
- 078变焦轮、虚拟光圈对焦、HDR HEIF Pro影调、编码/色彩/烧录、Live/HDR/M往返、视频生命周期、Open Gate等原失败方法本轮独立通过；见逐项表。
- 没有独立功耗/温度、自然极暗画质、实盘ProRes RAW、系统相册写入/删除等验证，不作对应通过结论。

## 逐项最终状态

| 原ID | 方法 | 最终复验 |
| --- | --- | --- |
| FULL-20261028-001 | `AutomaticLensStabilityPhysicalTests/testAutomaticModeUsesSystemVirtualCameraCandidatesAndWheelRetainsFullRange` | 独立通过 |
| FULL-20261028-002 | `AutomaticWhiteBalanceExposureTests/testAutomaticWhiteBalanceRemainsAutomaticDuringManualISOSweep` | 独立通过 |
| FULL-20261028-003 | `BasicVideoPhysicalTests/testTimeLapseRecordingCreatesSparseSilentMovie` | 仍失败/前提未满足 |
| FULL-20261028-004 | `DualCapturePhysicalTests/testEngineDualCaptureRecordingSwapAndOrdinaryRecovery` | 独立通过 |
| FULL-20261028-005 | `DualCapturePhysicalTests/testInactiveDualCaptureEntryIsVisibleInsideLensRegion` | 独立通过 |
| FULL-20261028-006 | `FilterEditorPhysicalTests/testRepeatedFilterEditingResetsAndFormatChangesStayBoundedAndRecover` | 独立通过 |
| FULL-20261028-007 | `FocusNavigatorPhysicalTests/testLiveAndRawPhotoPipelineRestoresAfterNavigation` | 独立通过 |
| FULL-20261028-008 | `FocusNavigatorPhysicalTests/testManualCaptureMetadataAndMovableNavigatorLayout` | 独立通过 |
| FULL-20261028-009 | `FocusNavigatorPhysicalTests/testPhotoNavigatorThresholdCaptureAndVideoExit` | 独立通过 |
| FULL-20261028-010 | `FrontVideoCenteringPhysicalTests/testCenterStagePersonLandscapeRecording` | 仍失败/前提未满足 |
| FULL-20261028-011 | `FrontVideoCenteringPhysicalTests/testCenterStagePersonPortraitRecording` | 独立通过 |
| FULL-20261028-012 | `NightCapturePhysicalTests/testThreeNightCapturesCompleteInMemoryAndReportHonestMergeState` | 仍失败/前提未满足 |
| FULL-20261028-013 | `PhysicalCameraSwitchingTests/testManualPresetsThenAutomaticModeOnPhysicalCamera` | 独立通过 |
| FULL-20261028-014 | `PortraitCapturePhysicalTests/testAutomaticMacroSuspendsPortraitCaptureAndRecovers` | 仍失败/前提未满足 |
| FULL-20261028-015 | `PortraitOptimizationPhysicalTests/testFrontPortraitContinuousAdjustmentAndCapture` | 独立通过 |
| FULL-20261028-016 | `PortraitOptimizationPhysicalTests/testRearPortraitContinuousAdjustmentAndCapture` | 独立通过 |
| FULL-20261028-017 | `PreviewExposureAssistPhysicalTests/testOrdinarySmoothPreviewLongAndShortExposureFiles` | 独立通过 |
| FULL-20261028-018 | `PreviewExposureAssistPhysicalTests/testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure` | 仍失败/前提未满足 |
| FULL-20261028-019 | `PreviewExposureAssistPhysicalTests/testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles` | 独立通过 |
| FULL-20261028-020 | `PreviewExposureAssistPhysicalTests/testSmoothPreviewRemainsPhotoOnlyAcrossVideoAndLifecycleChanges` | 独立通过 |
| FULL-20261028-021 | `ProResCompatibilityPhysicalTests/testActualCameraFrameEncodesWithAllConventionalProfiles` | 独立通过 |
| FULL-20261028-022 | `ProResRAWPhysicalTests/testRAWMetadataAfterWhiteBalanceLockWithoutWritingFiles` | 独立通过 |
| FULL-20261028-023 | `ProToneCapturePhysicalTests/testAllProTonesAreUsedByActualHDRHEIFProCaptureWithoutSaving` | 独立通过 |
| FULL-20261028-024 | `RecordingEdgeLayoutPhysicalTests/testFrontButtonGroupsStayCenteredAndRecordingPanelsUsePreviewEdges` | 独立通过 |
| FULL-20261028-025 | `RecordingEdgeLayoutPhysicalTests/testRealRecordingUsesEdgePositionsAndStopsCleanly` | 独立通过 |
| FULL-20261028-026 | `ShootingModeButtonTests/testActivePhotoAndVideoSubmodesUpdateEntryIcon` | 独立通过 |
| FULL-20261028-027 | `SilentShutterPhysicalTests/testNativeShutterSuppressionAcrossFormatsAndLiveWithoutSaving` | 独立通过 |
| FULL-20261028-028 | `SilentShutterPhysicalTests/testNightBatchesUseSilentPreferenceAndReleaseCaptureTasks` | 仍失败/前提未满足 |
| FULL-20261028-029 | `SlowMotionLensTransitionPhysicalTests/testSlowMotionFocalSwitchLatencyAndRecording` | 独立通过 |
| FULL-20261028-030 | `SlowShutterPresetTests/testPresetSlotsAlignWithFocalSlotsAndSurviveRapidToggleOnDevice` | 独立通过 |
| FULL-20261028-031 | `SlowShutterPresetTests/testSlowShutterAllowsSwitchingRearLenses` | 仍失败/前提未满足 |
| FULL-20261028-032 | `SlowShutterSequencePhysicalTests/testAdaptiveOtherPresetsAutomaticFullSequences` | 独立通过 |
| FULL-20261028-033 | `SlowShutterSequencePhysicalTests/testAdaptiveOtherPresetsManualEarlyFinishAndCancellation` | 真实崩溃 |
| FULL-20261028-034 | `SlowShutterSequencePhysicalTests/testAdaptiveStarTrailsFullDuration` | 仍失败/前提未满足 |
| FULL-20261028-035 | `SlowShutterSequencePhysicalTests/testAdaptiveWaterAutomaticAndManualRestoration` | 独立通过 |
| FULL-20261028-036 | `SlowShutterSequencePhysicalTests/testAdaptiveWaterEarlyFinishCancelAndRestart` | 独立通过 |
| FULL-20261028-037 | `SlowShutterSequencePhysicalTests/testAdaptiveWaterSceneExposureWithJPEG` | 独立通过 |
| FULL-20261028-038 | `SlowShutterSequencePhysicalTests/testAutomaticLightTrailsAndWaterCompleteOrRejectUnsafeExposure` | 独立通过 |
| FULL-20261028-039 | `SlowShutterSequencePhysicalTests/testAutomaticNewPresetsPreserveModeAndValidateMeteredExposure` | 独立通过 |
| FULL-20261028-040 | `SlowShutterSequencePhysicalTests/testAutomaticSequencesWithMeteredExposureCompensation` | 独立通过 |
| FULL-20261028-041 | `SlowShutterSequencePhysicalTests/testEarlyFinishCancellationAndRepeatedSelectionRecover` | 真实崩溃 |
| FULL-20261028-042 | `SlowShutterSequencePhysicalTests/testManualBracketSpeedComparisonAndRepeatedCapture` | 独立通过（补测） |
| FULL-20261028-043 | `SlowShutterSequencePhysicalTests/testManualLightTrailsAndWaterCompleteWithMetadata` | 独立通过 |
| FULL-20261028-044 | `SlowShutterSequencePhysicalTests/testManualMotionBlurCompletesWithShortSourceExposures` | 独立通过 |
| FULL-20261028-045 | `SlowShutterSequencePhysicalTests/testPanningLatencyWithAndWithoutPreviewAssist` | 独立通过 |
| FULL-20261028-046 | `SlowShutterSequencePhysicalTests/testSingleFramePresetsCaptureRequestedExposureWithoutStartingSequence` | 独立通过 |
| FULL-20261028-047 | `SlowShutterSequencePhysicalTests/testStarTrailsEarlyFinishCancellationAndRepeatedSelection` | 独立通过 |
| FULL-20261028-048 | `SlowShutterSequencePhysicalTests/testStarTrailsFull120FrameStreamingSequence` | 仍失败/前提未满足 |
| FULL-20261028-049 | `Smart48CompatibilityTests/test48MPSmartFramingHDRAndNightBoundaries` | 仍失败/前提未满足 |
| FULL-20261028-050 | `SmartAutoFramingTests/testAutomaticHardwareFramingOnceAndCancelPendingWork` | 独立通过 |
| FULL-20261028-051 | `SmartAutoFramingTests/testBacklitPortraitWithoutBlurTracksAutomaticOrigin` | 独立通过 |
| FULL-20261028-052 | `SmartAutoFramingTests/testRealSceneGuideAutomaticFramingAndCapture` | 独立通过 |
| FULL-20261028-053 | `SmartCapturePhysicalTests/testRealPreviewAnalysisPerformanceAndStability` | 独立通过 |
| FULL-20261028-054 | `SmartCompositionGeometryTests/testWhitePointAndThickerRingRendering` | 独立通过 |
| FULL-20261028-055 | `VideoCodecPhysicalTests/testActualCodecsAndColorsRepeatedRecording` | 独立通过 |
| FULL-20261028-056 | `VideoColorPhysicalTests/testAppleLogLUTBurnKeepsLogVideoTagsAndTenBitPixels` | 独立通过 |
| FULL-20261028-057 | `VideoColorPhysicalTests/testEveryAvailableColorSpaceRecordsRealTagsAndRestoresPhotos` | 独立通过 |
| FULL-20261028-058 | `VideoColorPhysicalTests/testLogAndLog2PreviewOnlyAndBurnHaveDifferentEncodedPixels` | 独立通过 |
| FULL-20261028-059 | `VideoColorPhysicalTests/testSDRAndP3FiltersAreBakedIntoRecordedPixelsWithStableFrameDelivery` | 独立通过 |
| FULL-20261028-060 | `VideoMacroIndicatorTests/testMacroIndicatorReplacesPortraitDepthControlAndSliderGrowsUpward` | 独立通过 |
| FULL-20261028-061 | `VideoModeTransitionTests/testAutomaticVideoRouteRestoresPhotoFormatAndLensSwitching` | 独立通过 |
| FULL-20261028-062 | `VideoModeTransitionTests/testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips` | 独立通过 |
| FULL-20261028-063 | `VideoModeTransitionTests/testRepeatedModeTransitionPreviewLatency` | 独立通过 |
| FULL-20261028-064 | `VideoSpecificationTests/testAllSupportedVideoSpecificationsWriteMatchingTracks` | 仍失败/前提未满足 |
| FULL-20261028-065 | `VideoSpecificationTests/testCinematicOutputGraphsAgainstAppleCapturePatternOnDevice` | 独立通过 |
| FULL-20261028-066 | `VideoSpecificationTests/testHighFrameRateAndFrontCameraRestoreSupportedSpecifications` | 独立通过 |
| FULL-20261028-067 | `VideoSpecificationTests/testOpenGateSwitchRecordsOnlyFourByThreeOrSquareOnDevice` | 独立通过 |
| FULL-20261028-068 | `VideoSpecificationTests/testRenderedVideoPreviewCadenceTracksSupportedRates` | 独立通过 |
| FULL-20261028-069 | `VideoSpecificationTests/testSlowMotionAndCinematicRoutesOnDevice` | 独立通过 |
| FULL-20261028-070 | `VideoVirtualAperturePhysicalTests/testVideoEntryLayoutRecordingAndRecovery` | 独立通过 |
| FULL-20261028-071 | `VideoWhiteBalancePhysicalTests/testVideoWhiteBalanceLockIsOptionalAndRestoredAfterRecording` | 独立通过 |
| FULL-20261028-072 | `VideoWorkflowTests/testImmediateCancelDuringWhiteBalanceStartupCompletesExactlyOnce` | 独立通过 |
| FULL-20261028-073 | `VideoWorkflowTests/testLifecycleStopFreezesClockAndRapidModeRequestsCoalesce` | 独立通过 |
| FULL-20261028-074 | `VideoWorkflowTests/testTimeLapsePresetBarMatchesFocalBarAndSurvivesRapidChanges` | 独立通过 |
| FULL-20261028-075 | `VirtualAperturePhysicalTests/testLensRestrictionsContinuousSliderAndRealPhotoInformation` | 独立通过 |
| FULL-20261028-076 | `VirtualAperturePhysicalTests/testVirtualAperturePreservesAutoTapAndManualFocus` | 独立通过 |
| FULL-20261028-077 | `WhiteBalanceRouteSafetyTests/testStaleCustomWhiteBalanceDuringRouteChangesDoesNotCrashVirtualCamera` | 独立通过 |
| FULL-20261028-078 | `ZoomWheelReopenPhysicalTests/testReopeningKeepsActualZoomAndAnchorAcrossBothModes` | 独立通过 |

## 产物与结束状态

所有日志、独立结果包、临时只读xctestrun及源码哈希位于 `/private/tmp/LumaCamera-FailureRecheck-20261028/`。临时文件不保证永久保留。
测试结束后尝试打开正常App时CoreDevice超时；只读查询显示设备随后锁屏（passcodeRequired=true）。未因此重跑用例或修改连接设置，未声称正常App已经自动重新打开。
