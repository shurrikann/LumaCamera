# 2026-10-24 三项预览辅助回归与视频曝光隔离修复

## 原三项与新增问题

FULL-20261024-012/013/014 分别是 A 挡慢门预览上限、M 挡预设自动辅助、设置中的流畅预览。未修改生产代码时，三项单独运行已全部通过（0.583/8.487/13.312 秒）。原全量中这些项目在原生人像无最终回调之后执行；本轮不能据当前通过为每个历史失败单独确认根因。

补充照片/视频往返时复现真实产品问题：`usesSmoothManualPreviewExposure` 直接读取持久化照片偏好，却未排除视频路线。启用照片辅助后，视频 M 挡在 `setExposure` 中仍走自动曝光预览分支。真机诊断：engineManual/custom 请求均为 true，requestedISO=400、requestedSeconds=0.008，实际 ISO=1060.0615、seconds=0.020652，仍受 1/30 秒自动曝光上限控制。此时仅界面值是手动，实际设备参数不匹配。

## 修复及测试前提

- `CameraEngine.usesSmoothManualPreviewExposure` 首先排除 `videoModeRequested`；偏好继续保留，返回照片后自动恢复辅助，视频 M 挡按实际快门/ISO 工作。照片与慢门多帧原有辅助策略没有改变，不改 UI、滤镜、编码或自动微距。
- 生产注释明确慢门自动辅助触发为 1/15 秒，预览上限为 1/30 秒，不混淆两个门限。
- 原三项用例复用重置后的可见相机，避免继承上一项人像/慢门/视频状态，并用 `SessionRuntimeErrorAudit` 监听本进程所有会话。
- 成片验证新增直接从编码资源读取 ImageIO EXIF ISO/ExposureTime，不用界面请求值或拍摄诊断值替代系统照片可见参数。M 慢门自动辅助验证 HEIF，设置辅助验证 JPEG。
- 新增拍摄任务四种计数归零检查；连续开关、拍摄中关闭辅助、视频录制、返回照片、退出/重进及关闭后恢复实际手动曝光均有断言。

## 官方依据

Apple [自定义曝光 API](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:)) 控制实际 ISO/曝光时间，并提供参数完成回调；拍照按该回调后提交，沿用 `.speed` 优先级。Apple 的 [activeMaxExposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemaxexposureduration) 只限定自动曝光算法的最长时间，不能代替自定义录像曝光；[手动包围曝光](https://developer.apple.com/documentation/avfoundation/avcapturemanualexposurebracketedstillimagesettings) 可将曝光/ISO 绑定到静态请求。照片辅助与视频的隔离、1/15 触发和 1/30 上限均为本应用策略，不是 Apple 固定保证。

## 最终真机结果

iPhone 17 Pro / iOS 27.0.1（24A446），项目正常签名，不使用模拟器、镜像，不向系统相册写入诊断媒体。

**5 个不同方法通过，0 失败、0 跳过，38.665 秒**：

1. A 挡慢门预览限制与退出，1.235 秒。注入 1/15 秒测光读数验证激活函数及真实设备 AE 上限，6 次慢门关闭/开启后退出；不是自然暗光触发验收。
2. M 挡慢门预设自动辅助与成片，8.400 秒。设置辅助保持关闭，选预设后自动优化；实际 HEIF EXIF ISO=400、ExposureTime=1/15 秒；拍完恢复优化，6 次开关后退出保留最后手动快门。
3. 设置中的流畅预览，18.197 秒。JPEG 正常拍摄及拍摄中关闭辅助两张文件，EXIF 均 ISO=400、ExposureTime=1/15 秒。正常拍摄的原生采样约 ISO399.431、0.066563 秒；两次编码资源和硬件量化略有差异，均在断言容差内。20 次快速开关、拍摄中关闭后保持关闭，恢复实际手动曝光；正常两条辅助捕获路径完成后的上下文/硬件 token/逻辑 token/有序缓冲均为 0。
4. 辅助保持开启时进入视频与生命周期恢复，10.832 秒。真实录制中 actualISO=399.43124、actualSeconds=0.007997、custom=true，对应请求400与1/125；默认普通视频临时文件写入成功且含视频轨。回照片恢复辅助，退出后会话停止，重新进入后关闭辅助，实际恢复照片 ISO400、1/15 秒。临时视频删除。
5. 既有纯策略门限回归，0.001 秒：1/60、1/30 不触发，1/15 触发；预设上限过短、无效输入等维持原规则。

预览性能采用每组 3×1 秒应用图像发布采样：

- M 挡预设自动辅助：24/25/25 次每秒，样本中位间隔40.35/39.71/40.38ms。
- 设置辅助关闭、请求 1/15 秒时：16/15/15 次每秒，中位间隔66.25/66.61/67.55ms。
- 设置辅助开启：25/25/25 次每秒，中位间隔39.92/40.64/40.22ms。

这些是应用渲染图像发布，不是设备显示 FPS、GPU 帧率或相机原始采集帧率；不承诺始终达到30，不含真实长曝光正在进行期间的取景停顿。没有功耗或独立 App 内存测试。正常/修复后测试未见带错误对象的运行错误；原 MDB_MAP_FULL 缓存日志仍未处理。

## 结果与限制

- `/private/tmp/LumaCamera-PreviewAssist-20261024-Baseline.xcresult`：原三项，修改前通过。
- `VideoBaseline` / `VideoDiagnostic` 同前缀结果包：新增视频隔离检查在修复前失败；后者记录实际参数不匹配。前者等待失败后另出现 CancellationError，不计为产品的额外相机错误。
- `Fixed` 同前缀结果包：初次修复后5项通过。
- `/private/tmp/LumaCamera-PreviewAssist-20261024-Final.xcresult`：增加拍摄中关闭辅助与返回参数断言后的最终5项；同前缀 `.log`。
- [结构化摘要](2026-10-24-PreviewAssist-Resolution-results.json)保留原始指标与方法耗时。临时目录不保证永久保留。

本轮未安排用户进入自然暗光，A 挡自然触发条件仅由既有策略单测和注入后真实硬件 AE 上限验证；未覆盖全部镜头、RAW、Live、HDR、所有视频编码及不同设备，不据本次默认视频成功关闭其他视频失败项。原012/013/014已定向通过，累计15个原失败方法通过，其他18项未处理/未复测；历史全量489/33/7不改写。
