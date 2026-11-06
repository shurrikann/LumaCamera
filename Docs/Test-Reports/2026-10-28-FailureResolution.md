# 2026-10-28 遗留失败修正

## 范围与结论

- 设备：iPhone 17 Pro，iOS 27.2（24B119），正常项目签名，单台有线串行；未启动模拟器。
- 原671项全量与78项独立复验为历史基线，不改写。本轮仅处理复验遗留13项及关联风险；12项定向通过，横屏人物效果仍待有效场景验收。
- 本轮33个不同方法最后结果：32通过、1未通过。多阶段失败、异常和后续通过都保存在结果JSON中，不能把这些次数相加当成独立功能数。
- 使用DEBUG环境`LUMA_DIAGNOSTIC_READ_ONLY_PHOTOS=1`，相册服务依赖注入阻止任何保存/删除入口；两项安全自检共9次预期阻断。每次实际执行均检查隔离标记，正常App不启用该变量。

## 原遗留13项

| 原ID | 处理及验证 |
| --- | --- |
| 003 | 延时人流预设现为1秒采样，2.2秒正确输出3帧/0.1秒；更新旧4帧断言，并新增两次真实3帧自动停止验收。 |
| 010 | 用户确认方向锁定开启；关闭后已读到横屏并正确录制1920×1080显示画面。首轮附件手指遮挡，未检出人物；最后状态见本报告。 |
| 012 | 原差异为EXIF浮点焦距约7.18e-10mm；以1e-6容差比较实际数字，未放宽缺失字段和融合断言。 |
| 014 | 修正用例仅开引擎未开模型的人像状态前提；通过真实入口后，现场自然超广角微距三次拍摄、人像暂停和恢复通过；未强制镜头。 |
| 018 | M挡无预设仍启用慢门流畅预览优化；测试按新版A预设/M无预设契约进入，实际文件曝光与恢复通过。 |
| 028 | 夜景批次诊断通知改到真正提交设置后，批次[3,6]均可取得本次静音设置；没有改夜景融合算法。 |
| 031 | 预设仅A挡可选，同一预设再次点击为取消；M挡保留慢门并清空预设；按该新版契约验证切镜。 |
| 033 | 创建和提交手动包围曝光前都检查设备custom能力与当前格式具体时长/ISO支持，避免NSInvalidArgumentException；最终定向完整流程通过。 |
| 034 | 星轨顶部默认时长已为60秒，测试使用当前所选时长重算而非旧120秒；完整采集通过。 |
| 041 | 同033防异常；首帧延后到主线程生命周期指令与会话队列屏障后提交，防止取消/返回遗留stop吞掉新请求；提前结束、取消、重启及10次快速选择通过。 |
| 048 | 同034，按顶部60秒执行流式合成，实际采集约61.34秒；保留旧120名称作为历史测试标识。 |
| 049 | HDR真实RAW输入为4032×3024，输出3024×4032 PQ10bit；记录本镜头本会话观测并回落12MP，关闭相应HEIF HDR高像素选择；普通SDR仍实际6000×8000。不是证明所有设备HDR均不支持48MP。 |
| 064 | 固定规格关闭自动帧率，检查官方锁帧能力；换格式/帧率先释放旧锁再设置。18种720p/1080p/4K与24/25/30/50/60/120实际编码/解码时间戳通过。 |

## 慢门与延时逻辑核对

- 慢门预设A挡自适应，进入M挡清空预设而保留慢门模式。M挡无预设采用完整硬件范围，保留显式ISO/快门，不把流水预设的曝光范围/最低帧数误套到通用序列。真实M挡ISO200、1/125秒有限序列完成，并在∞序列采集至少三帧后取消、无额外成片。
- ∞改为流式计数`Int.max`边界，不再因旧36,000帧上限自动停止；不宣称无限时长实测。首帧等待生命周期和相机队列完成，最长3秒等待就绪，取消检查序列token，避免旧请求重新启动。
- 延时只有写入器实际append成功才提交采样调度状态/计入目标帧数，失败不消耗名额；达到目标只触发一次停止。两轮临时录制均解码为3帧、无音轨并自动停止。
- 同挡位无操作不再重置延时自定义间隔/帧数；M/A实际切换仍恢复既定默认。无预设的5秒/60帧存档重建通过，未自动套回人流预设。

## 关联修正

- 普通M挡视频往返后曾出现读数0.5秒而文件实际1/50秒。标准JPG/HEIF无Live/RAW/夜景/人像时，手动曝光可用官方单帧手动包围请求绑定到照片；仍做具体格式能力预检。最终Live/HDR/M共六次往返、实际EXIF、两次0.5秒/ISO200出片及快速反向切换通过。RAW等路径保留原专门流程，不声称本项覆盖所有组合。
- 新固定帧率锁影响本项目电影输出图启用：电影请求前释放锁，不对电影请求附加普通视频锁帧。最终两轮电影进入、录制、规格切换及退出通过；这为本机本配置观测，官方只说明能力会随配置变化，未将其描述为所有电影/锁帧必然互斥。

## 性能与稳定性

- 视频18种规格各录制/解码一段，以真实采样时间戳与尺寸校验，包含720p/1080p 30与60实际不再回落24/50。该矩阵未重复长时间耐久录制。
- 最终电影两次：配置就绪0.511/0.449秒，最终路由首张预览发布0.756/0.731秒；每次输出图重建1次。慢动作两次配置就绪0.500/0.437秒。首帧指标含10ms轮询，均不是屏幕扫描输出时刻。
- 慢门最终光轨/动态模糊/摇拍各一次约16.58/4.33/2.34秒；星轨60秒目标完整样本约61.34秒。不是与旧版同条件提速对照，也未验收真实星空/运动光轨审美。
- 自然微距三次成片回调中位0.803秒、最大1.984秒；取消中、完成待回调时取消、返回重启及10次快速选择通过。临时源图/任务均收尾，未写系统相册。
- 原033/041真实崩溃最终未复现，未以catch掩盖NSException；改为官方能力预检。开发中A阶段锁帧更新顺序曾再次引发异常，后续先解锁再更新，证据保留。E阶段关联曝光/电影失败随后由G阶段通过覆盖，不能删除旧失败记录。
- 流式合成只保留有限源图，但测试宿主仍有约500MiB级采样峰值，包含XCTest、临时图像和GPU资源，不代表独立App内存；未做独立功耗、温度或长期泄漏测量。预览图像发布频率不是实际屏幕FPS。

## 横屏人物现场结果

F阶段实际横屏录制显示1920×1080，系统激活、连续录制和新帧发布通过，但6张均无人脸。附件确认手指近处遮挡、主要为桌面。I阶段重新准备后同样0/6人脸，附件仍是失焦近物场景；实际横屏姿态3，显示1920×1080，372次发布、最大间隔78.4ms。人物跟随效果尚不能算通过，保留原断言，不继续反复要求现场配合。

## 官方依据与界限

- [手动曝光具体格式支持](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/supportsexposuremodecustom(lensaperture:duration:iso:))：按请求的光圈、时长、ISO检查，而不是只看帧率范围。
- [输入锁帧](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/activelockedvideoframeduration)：能力随配置变化，切换格式会复位，并可能引起耗时重配；高帧率低于最短锁帧周期时保留设备帧周期设置。
- [照片最大尺寸请求](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/maxphotodimensions)及[高分辨率捕获说明](https://developer.apple.com/videos/play/wwdc2026/304/)：请求上限不保证实际输出，取最终文件/RAW尺寸，不自行上采样冒充。

## 最后状态与证据

| 阶段 | ID | 方法 | 最后结果 | 秒 |
| --- | --- | --- | --- | --- |
| G | 033 | `SlowShutterSequencePhysicalTests/testAdaptiveOtherPresetsManualEarlyFinishAndCancellation` | passed | 46.674 |
| G | 041 | `SlowShutterSequencePhysicalTests/testEarlyFinishCancellationAndRepeatedSelectionRecover` | passed | 10.858 |
| E | FULL-20261028-049 | `Smart48CompatibilityTests/test48MPSmartFramingHDRAndNightBoundaries` | passed | 13.739 |
| B | FULL-20261028-064 | `VideoSpecificationTests/testAllSupportedVideoSpecificationsWriteMatchingTracks` | passed | 43.437 |
| D | FULL-20261028-003 | `BasicVideoPhysicalTests/testTimeLapseRecordingCreatesSparseSilentMovie` | passed | 3.27 |
| C | FULL-20261028-012 | `NightCapturePhysicalTests/testThreeNightCapturesCompleteInMemoryAndReportHonestMergeState` | passed | 8.902 |
| C | FULL-20261028-018 | `PreviewExposureAssistPhysicalTests/testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure` | passed | 9.667 |
| D | FULL-20261028-028 | `SilentShutterPhysicalTests/testNightBatchesUseSilentPreferenceAndReleaseCaptureTasks` | passed | 5.431 |
| D | FULL-20261028-031 | `SlowShutterPresetTests/testSlowShutterAllowsSwitchingRearLenses` | passed | 3.803 |
| C | FULL-20261028-034 | `SlowShutterSequencePhysicalTests/testAdaptiveStarTrailsFullDuration` | passed | 71.315 |
| C | FULL-20261028-048 | `SlowShutterSequencePhysicalTests/testStarTrailsFull120FrameStreamingSequence` | passed | 72.991 |
| E | NEW-FINITE | `BasicVideoPhysicalTests/testFiniteTimeLapseActuallyStopsAtAcceptedFrameLimitTwice` | passed | 6.27 |
| E | NEW-GENERIC | `SlowShutterSequencePhysicalTests/testGenericManualDurationAndInfiniteCancellation` | passed | 5.306 |
| C | UNIT-TimeLapseSettingsTests-testIntervalAndFrameCountOptions | `TimeLapseSettingsTests/testIntervalAndFrameCountOptions` | passed | 0.001 |
| C | UNIT-TimeLapseSettingsTests-testPresetRecommendedCombinations | `TimeLapseSettingsTests/testPresetRecommendedCombinations` | passed | 0.001 |
| D | UNIT-TimeLapseSettingsTests-testCancellingPresetRestoresOneSecondAnd120Frames | `TimeLapseSettingsTests/testCancellingPresetRestoresOneSecondAnd120Frames` | passed | 1.082 |
| C | UNIT-TimeLapseSettingsTests-testSchedulerStopsAtFrameLimit | `TimeLapseSettingsTests/testSchedulerStopsAtFrameLimit` | passed | 0.001 |
| C | UNIT-SlowShutterDurationTests-testOptionsAndDefault | `SlowShutterDurationTests/testOptionsAndDefault` | passed | 0.001 |
| C | UNIT-SlowShutterDurationTests-testOneSecondScalesPresetDurationAndKeepsMinimumFrames | `SlowShutterDurationTests/testOneSecondScalesPresetDurationAndKeepsMinimumFrames` | passed | 0.001 |
| C | UNIT-SlowShutterDurationTests-testPresetDurationRangesAndDefaults | `SlowShutterDurationTests/testPresetDurationRangesAndDefaults` | passed | 0.003 |
| C | UNIT-SlowShutterDurationTests-testFivePerRowLayout | `SlowShutterDurationTests/testFivePerRowLayout` | passed | 0.001 |
| C | UNIT-SlowShutterProgressTests-testLongTargetAtWholeSecondStartsNewTurn | `SlowShutterProgressTests/testLongTargetAtWholeSecondStartsNewTurn` | passed | 0.001 |
| C | UNIT-SlowShutterProgressTests-testInfiniteProgressTurnsOncePerSecond | `SlowShutterProgressTests/testInfiniteProgressTurnsOncePerSecond` | passed | 0.001 |
| C | UNIT-SlowShutterProgressTests-testSubSecondProgressUsesRealDurationAsOneTurn | `SlowShutterProgressTests/testSubSecondProgressUsesRealDurationAsOneTurn` | passed | 0.001 |
| C | UNIT-SlowShutterProgressTests-testLongProgressTurnsOncePerSecond | `SlowShutterProgressTests/testLongProgressTurnsOncePerSecond` | passed | 0.001 |
| C | UNIT-SlowShutterProgressTests-testFrameFallbackWhenElapsedIsUnavailable | `SlowShutterProgressTests/testFrameFallbackWhenElapsedIsUnavailable` | passed | 0.001 |
| G | RESTORE | `VideoModeTransitionTests/testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips` | passed | 64.409 |
| E | HIGHFRONT | `VideoSpecificationTests/testHighFrameRateAndFrontCameraRestoreSupportedSpecifications` | passed | 22.129 |
| G | CINEMA | `VideoSpecificationTests/testSlowMotionAndCinematicRoutesOnDevice` | passed | 16.82 |
| I | 010 | `FrontVideoCenteringPhysicalTests/testCenterStagePersonLandscapeRecording` | failed | 15.275 |
| H | PERSIST | `CaptureStatePersistenceTests/testCustomTimeLapseWithoutPresetSurvivesRecreation` | passed | 0.051 |
| H | 017 | `PreviewExposureAssistPhysicalTests/testOrdinarySmoothPreviewLongAndShortExposureFiles` | passed | 23.492 |
| H | 014 | `PortraitCapturePhysicalTests/testAutomaticMacroSuspendsPortraitCaptureAndRecovers` | passed | 4.574 |

[逐次结果及原日志路径](2026-10-28-FailureResolution-results.json)。原结果包均在`/private/tmp/LumaCamera-1028-Resolution*`；仅临时证据，可能被系统清理。构建9通过；生产代码最终变更在构建8后不再改变，构建9仅补充两个用例。

正式xcresult汇总逐包核对：33项，32通过、1失败、0跳过，与控制台解析一致。正常App启动结果另见本次运行记录。

### 用户要求的最后一次横屏补测（J阶段）

横屏姿态3、显示1920×1080、系统激活与录制正常，371次图像发布、最大间隔100.4ms；6张均未检出人脸，临时附件目视为显示器和桌面，没有有效人物。原断言保留失败，不能算人物跟随效果通过；未改变产品代码。该补测与后续慢门A/M规则修改分开。
