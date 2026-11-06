# 2026-11-01 慢门剩余九项修复与真机复验

原第一轮剩余清单中的九个慢门失败方法全部通过。最终专项45方法：43通过、0失败、2跳过，测试执行905.130秒；未重跑736项全量。设备为iPhone17Pro（iPhone18,1）、iOS27.2（24B119），Xcode27.1。Debug测试构建和Release构建通过，源码编译警告0，保留工具链AppIntents元数据提取提示。测试后已重新启动无诊断环境变量的普通App。

## 修改与基线区分

- 手持背景/中央主体配准后，累积器保持第一张有效参考画布；新帧未覆盖的边沿采用已有真实像素，再参与本次融合。不再逐帧缩小交集，不通过放大或黑边满足像素断言。无配准的旧平均/亮部叠加路径保持原逻辑，低可信帧仍剔除。
- 全局配准及中央主体配准的小参考图改用自有像素；已有两张可靠融合后释放不再需要的全尺寸单帧备份。继续使用此前已修正的16位P3逐帧检查点和CI缓存清理，源帧长期保留上限仍为1。
- 中间预览除源帧侧渲染节流外，新增按主线程实际发布时间计算的0.5秒节流。等待时只保留最新一张；完成、失败、取消均撤销待发布任务，最终成片直接发布。先更新序列状态再通知预览，避免订阅者同步取消后旧状态将序列复活；同时清理`@Published`赋值前通知造成的旧预览残留。

修复前本次基线4方法已通过，其中包括一条完整星轨及车流/流水输出：此前自有像素渲染修正已在当前版本恢复这些路径，本轮没有再次复现原崩溃。基线星轨61.691秒、宿主采样峰值614.3MiB。交集逐帧收窄是代码中确认的问题；静止取景基线没有复现低于1100万像素，新加入的受控位移测试用于直接覆盖该边界。

苹果[CIImage文档](https://developer.apple.com/documentation/coreimage/ciimage)及[边界延拓文档](https://developer.apple.com/documentation/coreimage/ciimage/clampedtoextent%28%29)说明图像范围与范围外取样行为；[CIContext缓存清理](https://developer.apple.com/documentation/coreimage/cicontext/clearcaches%28%29)用于释放临时缓存。采用已有有效边沿、0.5秒更新门限及备份释放时机均为本项目策略，非平台保证。

## 原九项逐一结果

下列均为最终同一轮真机通过；耗时包含测试准备和恢复，不等于单次快门耗时。完整类名与结果见[JSON](2026-11-01-SlowShutter-Fixes-results.json)。

| 原问题 | 方法 | 结果 / 秒 |
|---|---|---|
| FULL-001 | testHandheldAlignmentPreservesStaticDetailAndRejectsUnrelatedFrame | 通过 / 0.508 |
| FULL-054 | testAdaptiveStarTrailsFullDuration | 通过 / 71.021 |
| FULL-055 | testAdaptiveWaterAutomaticAndManualRestoration | 通过 / 45.490 |
| FULL-058 | testAutomaticLightTrailsAndWaterCompleteOrRejectUnsafeExposure | 通过 / 48.687 |
| FULL-060 | testAutomaticSequencesWithMeteredExposureCompensation | 通过 / 55.572 |
| FULL-063 | testManualBracketSpeedComparisonAndRepeatedCapture | 通过 / 186.303 |
| FULL-064 | testManualLightTrailsAndWaterCompleteWithMetadata | 通过 / 52.225 |
| FULL-065 | testManualMotionBlurCompletesWithShortSourceExposures | 通过 / 24.544 |
| FULL-071 | testStarTrailsFull120FrameStreamingSequence | 通过 / 72.902 |

FULL编号均属20261030清单。方法名中的Manual保留历史命名；按当前A/M契约，选择自动预设后实际模式是A。不能据这些名称宣称M挡带预设拍摄。另行完成普通M挡ISO200、1/125秒实际编码EXIF核对、1秒合成及∞取消；五预设A/M往返、M挡清除预设及手动数值/白平衡恢复亦通过。

## 性能与稳定性

- 35次完整预设序列的实际编码资源均由ImageIO读取为3000×4000；核对首帧实际曝光、ISO、焦距、采集/有效融合计数和拍摄后状态。没有降低原1100万像素断言或缩短完整星轨时长。
- 两条星轨单次61.438/61.528秒，实际融合181/174帧，分别产生91/87次中间预览；最终画布均为1200万像素。`Full120Frame`是历史测试名，当前按完整时长采集，并非强制仅120帧。
- 35次完整序列共571次真实中间预览，最短发布时间间隔0.502790秒，预览最长边不超过901点；不包含占位和最终成片。此为发布频率，非屏幕帧率。
- 两种配准融合各20次受控位移：40/40帧接受，逐帧保持320×240，四角无透明/黑色填充。加入旋转和无关帧的16样本，配准及检查点渲染中位105.38ms、最大109.70ms；保留原异常帧剔除断言。14张实际JPEG覆盖7比例×2内容方向；真机预设布局覆盖7比例、20次快速开关及10次A/M快速往返。
- 累积预览渲染各12样本：320×240→最长边180，中位1.14ms/最大1.60ms；4032×3024→最长边900，中位2.25ms/最大10.97ms。均为该渲染调用耗时，不代表实际显示FPS。开头模型/渲染测试与Mac端Release构建并行，非严格隔离基准。
- 旧/当前采集路径每预设1/3次对照：车流16.776秒对16.405/16.410/16.395秒；流水11.800秒对11.808/11.836/11.834秒；动态模糊4.641秒对4.439/4.394/4.425秒。总时长包含固定采集窗口，不据此宣称本轮提速。
- 实际拍摄页累积预览、预览通知内同步取消、采集中取消、待结束取消、提前结束、∞取消、旧源帧迟到、重拍及快速预设切换均通过；同步取消后迟到中间预览0、保存0。普通M挡包围/回退交替4次后取景恢复约53–105ms；回退路径保留旧有效画面期间最大发布间隔1.65–1.91秒，未将这段停顿当成连续预览。
- 长序列保留原始源帧≤1；两条星轨宿主采样峰值548.8/741.7MiB，全部完整序列峰值范围548.8–823.9MiB。该值含XCTest、测试窗口及缓存，是测试宿主`phys_footprint`，不能当作独立普通App内存，也未证明所有场景内存上限。完整序列结束时thermalState均为0。

## 跳过与新增观察

两个跳过方法为`SlowShutterPresetTests/testAutomaticModeKeepsApertureModeAndPresetOnlyCapsAutomaticExposure`、`testSelectingPresetsConstrainsManualExposureAndRepeatedTogglingClearsState`：旧夹具创建模型后未启动硬件会话，因ready=false跳过。对应自动策略、真实A/M恢复、预设切换已在本轮其他方法执行，但这两个方法本身不记通过。

原崩溃相关字符串`IOSurface creation failed`、`Failed to allocate`及`AVFoundationErrorDomain/-11819`本轮均0次，实际会话运行错误审计通过。基线与本轮日志仍有`MDB_MAP_FULL`，最终2280次，来源未定位；局部测试宿主仍有SwiftUI Environment提示，未把日志完全清洁写成已通过。

另记录SLOW-META-001：输出主像素字典3000×4000，而星轨编码资源EXIF的PixelXDimension/PixelYDimension仍为源4032×3024。本轮九项不包含该字段一致性，未将全部EXIF字段标为一致；已加入待办。曝光、ISO与焦距核对来自实际编码资源，不是详情页文字。

本轮为室内真机功能回归与受控位移/旋转合成测试；未新增自然流水、运动人物或真实夜空的手持画质验收。诊断资源仅存测试内存/结果附件，未加入用户系统照片。

## 证据与复现

目录`/tmp/LumaCamera-SlowFix-20261101`：`Baseline.xcresult`（4通过）、`Quick.xcresult`（10通过）、`Final.xcresult`（43通过/2跳过）、对应日志及摘要、`Build.log`、`Release.log`。逐方法、35组输出与完整SLOW指标、源码SHA256见本报告JSON。

先用`xcodebuild build-for-testing -project LumaCamera.xcodeproj -scheme LumaCamera -destination id=<设备> -derivedDataPath <DD>`构建；在生成的xctestrun中设置`LUMA_DIAGNOSTIC_READ_ONLY_PHOTOS=1`，选择SlowShutterSequencePhysicalTests、SlowShutterHandheldTests、AdaptiveWaterComposerTests、AdaptiveWaterExposureTests、SlowShutterPresetTests，再以`test-without-building`运行。保持手机解锁，关闭其他相机占用；完整参数见`<DD>/Build/Products/SlowFix-Final.xctestrun`，本次DD为`/tmp/LumaCamera-NightCancel-DD`。
