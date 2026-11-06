# 2026-10-24 M→A 预览尺寸核对与前置方形冻结修复

## 原失败重新归因

FULL-20261024-006 的唯一不同断言是前后切镜后的 `width < height`，发生在六次前后切镜检查，不在前面的三轮 M→A 检查。旧前提假设所有预览都为竖图；当前新前置支持横幅取景，900×675 是合法横幅。此前把该项概括为“M→A 尺寸错误”不准确，保留原全量断言，不据此强制旋转正确的横幅。

旧用例现改为复用已重置的可见模型、通过模型生命周期启动，并核对切换后的新帧和当前实际构图。不是删除尺寸检查：仍检查 UIImage 方向、约 900（浮点边界外扩可为 901）像素宽度、实际高宽比和有效读数。对长画幅使用两轴各 1 像素取整容差折算，而非固定比值误差。

## 补测发现的真实产品问题

新增七种画幅回归复现：前置传感器保持横幅时切到 1:1，`look.landscape` 为 false，但输入仍是横幅；`renderPreviewFrame` 误把所有新帧当作旧画幅丢弃，屏幕保留上一张 900×675 横幅预览，造成尺寸不匹配和冻结。

修复在 `LivePreviewState.Snapshot` 增加独立的 `nativeFrontSensorLandscape`，从相机队列已确认的 `frontPhotoLandscapeApplied` 同步：

- 输入新旧画幅过滤核对传感器状态，不再使用最终裁切方向。
- 匹配帧更新前置宽高比状态也使用传感器状态。
- 最终 `FrameRatio.crop` 仍按 look 裁切，方形输入方向不影响方形输出；既有时间戳、代次和旧帧过滤保留。
- 不改按钮布局、照片旋转、倍率、M/A 参数、视频或系统自动微距选择，不新增自动切镜动画。

## 官方依据

Apple 的 [Center Stage 前置说明](https://developer.apple.com/videos/play/wwdc2026/341/) 明确支持无需转动设备切换横竖构图；[setDynamicAspectRatio](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setdynamicaspectratio(_:completionhandler:)) 的完成时间戳对应参数全部应用后的首个缓冲，应转换到会话时钟比较。项目沿用该官方动态画幅与时间戳路径。本次独立记录传感器方向属于应用实现；900 像素缩放及 1:1 后裁切不是 Apple 固定输出尺寸保证。

## 实际验证

设备 iPhone 17 Pro / iOS 27.0.1（24A446），正常签名，不使用镜像或模拟器，临时照片不写系统相册。

最终 **8 项通过、0 失败、0 跳过，53.641 秒**：

- 原 `PhysicalCameraSwitchingTests/testManualPresetsThenAutomaticModeOnPhysicalCamera`，20.791 秒：三轮 M 挡全部后置焦段往返、M→A 读数恢复、六次前后切镜，均检查匹配的新预览；2 秒直方图观察到 28 次发布（不是屏幕 FPS）。
- 新 `testManualToAutomaticPreviewMatchesAllPhotoRatiosAndFrontFraming`，20.652 秒：后置七种画幅各一次 M→A；前置竖/横/竖/横四轮，每轮七种画幅，28 次 M→A 新帧比例检查，包含两次横幅→方形；最后返回后置并退出，实际会话已停止。后置 7 样本从请求到匹配预览且有效读数中位 0.984 秒、最大 1.104 秒，含队列排空及 20ms 轮询，不是屏幕动画完成或实测 FPS。
- 既有前置 A/JPG 和 M/HEIF+预览辅助动态画幅回归两项（5.814、6.263 秒）：各 8 次构图往返、12 次快速请求后持续出帧、照片/视频返回及实际临时文件检查通过。构图发布中位 A 55.5ms、M 45.7ms；不据此声称内容朝向目视验收。
- 四项前置方向/像素/文件处理回归通过。正常组未见带错误对象的会话运行错误；MDB_MAP_FULL 缓存日志未处理。

中间运行记录：`Verified` 新矩阵复现方形冻结，同时出现超宽画幅固定比值误差假失败；`Fixed` 中方形已通过，少数高瘦画幅因两轴整数外扩的测试容差仍失败。最后按两轴像素容差修正后完整通过，不把中间结果计入通过。

局限：手机实际姿态未要求人工固定；此轮核对像素尺寸/代次、已有码流与方向处理，未做真实人物上下方向的目视验收，不声称所有持机方向或其他设备均已验证。没有功耗、屏幕 FPS 或独立 App 内存测量。未对其余全量失败项复测。

结果：`/private/tmp/LumaCamera-ModePreviewSize-20261024-Final.xcresult` 与同名前缀 `.log`；中间结果为 `Verified`、`Fixed` 结果包。结构化摘要见 `2026-10-24-ModePreviewSize-Resolution-results.json`。原 006 定向通过，累计 12 个原失败方法有通过记录，其余 21 项未处理/未复测，原全量 489/33/7 不变。
