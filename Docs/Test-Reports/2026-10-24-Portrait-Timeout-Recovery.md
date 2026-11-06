# 2026-10-24 人像原生回调超时与任务无法清空

## 已确认的问题

原全量日志中的人像请求 209 已到 didCapturePhoto（曝光完成），随后 55 秒内没有 processed / didFinishCapture 回调。captureContexts、hardwareTokens 与有序交付缺口只能靠最终回调释放；recoverSession 和用户重试都等待 captureContexts 清空，缺少截止条件。后续出现 capturing=true、pending=4，录像被占用状态阻止。

这是已证实的应用收尾缺口；系统原生处理为什么没有返回照片，尚未取得平台内部根因。不把诊断回调注入描述为复现系统服务故障。

## 修改

- 每个原生请求有一次延时检查，按请求 uniqueID 与上下文身份核对；正常 didFinishCapture 回调结束等待。夜景的三帧批次分别计时，批次间运动分析不算原生等待，不限制整组或慢门长序列时长。
- 应用级预算：标准处理格式人像 12 秒，其他普通/高像素处理格式 20 秒，RAW/Live 45 秒。预算是应用策略，不是 Apple 保证的完成时限；测试可显式缩短以验证异常路径，普通版本无测试覆盖值。
- 超时后撤销旧照片输出的全部未结束请求，释放硬件 token、快门、权重和计数。为失败序号提交空终结，使后面已成功的照片可以按快门顺序交付，不无限等待旧序号。
- 主线程用待终结 token 集合实现一次性收尾；超时后迟到/重复终结不能二次减计数、交付旧照片或留下过期有序结果。未完成照片不伪造成功，不写残缺资源。
- 阻断向旧会话提交新拍摄，再沿既有恢复路径停止会话、替换 AVCapturePhotoOutput、重新配置并等待新预览。用户已经离开相机时只清理，不自行重启；下次用户进入再替换旧输出。
- 原生人像蒙版请求实际超时的设备，在当前 CameraEngine 生命周期中记入失败集合。重建时关闭该设备原生深度/蒙版交付，后续处理格式人像保留已有 Vision 人物分割后备路径，避免每张重复触发同一路线超时；未失败的设备继续原路径，其他照片格式与手动参数保持既有规则。此状态不持久化到用户设置，重建整个 App 引擎后重新探测。
- 保留真实错误提示“拍照超时，本次照片未能完成，请重新拍摄。”；不会在恢复后自动补拍另一时刻的场景。
- 新增部分及测试均配中文逻辑注释。没有更改系统自动微距策略、强制物理镜头、焦距、滤镜配方或界面样式。

## 验证结果

设备 iPhone 17 Pro / iOS 27.0.1（24A446），正常项目签名，单真机串行；只使用临时数据，未写系统相册、未用镜像或模拟器。

四组共 **9 个不同方法通过、0 失败、0 跳过**，详见[结构化方法与指标](2026-10-24-Portrait-Timeout-Recovery-results.json)。

1. 真实远景：原人像处理格式/ProRAW矩阵、M 挡主摄 HEIF 人像、随后照片/视频路由恢复三方法通过（38.520 秒）。HEIF 12MP 1.244 秒回调；请求 48MP 的原生尺寸、HEIF 6000×8000、ProRAW 8064×6048及后续捕获/视频返回检查通过。此场景未交付人物蒙版，诊断为保留清晰原片；不作为人像抠图画质验收。
2. 真实近距：实际观察到系统选择超广角后，3 次微距优先照片完成，p50 0.599 秒、最大 1.077 秒；随后六次人像开关和退出/返回恢复通过。当前场景按既有规则暂停本张人像，不代表复现原主摄最近焦点/无微距时的系统处理挂起。
3. 最终组合四方法（46.883 秒）：普通 JPEG/HEIF Live 配对与解码、夜景实际 3/6/9/6/9 帧、人像漏回调恢复、后台超时/返回均通过。夜景为受控环境指标，不改写自然暗光验证范围。
4. 四请求容量专项（13.017 秒）：四个真实硬件请求结束后分别丢弃应用侧最终回调，确认 contexts/hardwareTokens/pendingTokens/pendingPhotoCount 都达到 4，容量耗尽；10 秒测试预算到期后全部清零，输出重建，新照片成功。包含重建/新照片的总时间 11.993 秒。

### 失败注入的含义与稳定性检查

- 注入发生在系统 didFinishCapture 真正到达后：清掉该测试上下文的图像数据并跳过应用收尾，不故意制造相机系统服务卡死；正式版本注入开关关闭。
- 单人像请求以 6 秒测试预算模拟漏通知；6.159 秒时计数/缺口清空，已经完成但被前序阻挡的一张新照片仍交付，输出实例确实更换；同一旧 token 重放两次不改变计数/照片数量。
- 后备标志实际为 true，后续同设备人像请求成功，随后 HEVC 临时录像能开始、停止、读取非零时长；没有把释放显示状态当成硬件恢复。
- 退出用例以 4 秒预算检查超时清理，系统会话仍停止，用户返回后重新拍照成功。未为测试添加空成功回调或忽略原断言。
- 四组日志未见带错误对象的 AVCaptureSession 运行错误；既有 MDB_MAP_FULL 缓存日志仍在，不将其根因写成已解决。
- 性能数值是请求/方法耗时，测试预算不是生产预算；原生人像内部挂起本轮未再自然出现。没有测真实屏幕 FPS、电池功耗或纯 App 内存，夜景日志的宿主 footprint 不当成应用内存。

## 剩余边界

- 如果原生照片确实未返回数据，该张无法恢复为成功照片；提示用户重新拍摄，后续走可用后备路径。Vision 后备主要分割人物，没有人物时安全保留清晰原片，不宣称与系统深度蒙版或任意物体虚化等效。
- 本次有界保护针对原生请求回调；已完成原生交付后的普通图像处理/Live 后期任务仍沿用既有异步处理，没有通过统一短时限截断正常处理。
- 真实近距主摄/最近焦点与原平台挂起的精确触发条件仍待自然复现，本次不宣称 Apple 内部故障已消失；应用不会再仅因缺少最终回调永久占住四个名额。
- 全量 489/33/7 历史统计保留。本次原 007、009、024 三方法定向通过，累计十个原失败方法有定向通过记录，其他 23 项未处理/未复测；没有把下游所有失败一并标为已解决。

## 证据与官方依据

- `/private/tmp/LumaCamera-PortraitRecovery-20261024-Real.xcresult` 与同前缀 .log。
- `/private/tmp/LumaCamera-PortraitRecovery-20261024-Near.xcresult` 与同前缀 .log。
- `/private/tmp/LumaCamera-PhotoTimeout-20261024-Final.xcresult` 与同前缀 .log。
- `/private/tmp/LumaCamera-PhotoTimeout-20261024-Four.xcresult` 与同前缀 .log。
- 首轮收尾机制检查两项通过：`/private/tmp/LumaCamera-PhotoTimeout-20261024-1.xcresult`，后续增加原生后备标志及四请求断言，以最终各组为准。
- 普通版本构建日志：`/private/tmp/LumaCamera-PhotoTimeout-20261024-App.log`。
- Apple [didFinishCaptureFor](https://developer.apple.com/documentation/avfoundation/avcapturephotocapturedelegate/photooutput(_:didfinishcapturefor:error:)) 将它定义为该请求最终回调，按 uniqueID 对应请求并清理资源；[Tracking photo capture progress](https://developer.apple.com/documentation/avfoundation/tracking-photo-capture-progress) 区分曝光完成、多个图像结果和最终收尾。本项目正常路径仍遵循该生命周期，漏回调保护、预算和输出重建是应用层恢复策略。

### 原始指标摘录

```text
PORTRAIT-CAPTURE case=HEIF-12MP dimensions=3000x4000 matte=未生成可用人物遮罩，保留清晰原片 callback-seconds=1.2435461666755145
PORTRAIT-CAPTURE case=HEIF-48MP-control dimensions=3024x4032 pixels=12192768 callback-seconds=0.777412416660809
PORTRAIT-CAPTURE case=HEIF-48MP dimensions=6000x8000 matte=未生成可用人物遮罩，保留清晰原片
PORTRAIT-CAPTURE case=ProRAW-48MP dimensions=8064x6048 embeddedMatte=false decodedMatte=false reported=未生成可用人物遮罩，保留清晰原片
PORTRAIT-MACRO-CAPTURE samples=3 p50=0.5991913333418779 max=1.076783875003457 noPhotosWrites=true
NIGHT-ADAPTIVE target=3 captured=3 帧 merged=3 batches=[3] seconds=1.1443675416667247 hostFootprintMiB=502.48656463623047 injected-scene=true
NIGHT-ADAPTIVE target=6 captured=6 帧 merged=6 batches=[3, 6] seconds=2.579502666660119 hostFootprintMiB=609.8147354125977 injected-scene=true
NIGHT-ADAPTIVE target=9 captured=9 帧 merged=9 batches=[3, 6, 9] seconds=3.6407965416728985 hostFootprintMiB=609.8147354125977 injected-scene=true
NIGHT-ADAPTIVE target=6 captured=6 帧 merged=6 batches=[3, 6] seconds=2.6496988750004675 hostFootprintMiB=609.8147354125977 injected-scene=true
NIGHT-ADAPTIVE target=9 captured=9 帧 merged=9 batches=[3, 6, 9] seconds=3.751120416665799 hostFootprintMiB=652.8616561889648 injected-scene=true
2026-10-24 18:04:24.553978+0800 LumaCamera[6161:2139492] Photo capture timed out: request=16 unfinished=1; retire old photo output
PHOTO-TIMEOUT-RECOVERY injected=true releasedSeconds=6.1591943749954225 photosAfterRecovery=2 reorderedSuccessRetained=true oldCompletionReplayed=2 portraitFallback=true videoRecorded=true noPhotosWrites=true
2026-10-24 18:04:32.249748+0800 LumaCamera[6161:2139493] Photo capture timed out: request=21 unfinished=1; retire old photo output
PHOTO-TIMEOUT-LIFECYCLE injected=true backgroundRestart=false pending=0 returnedPhoto=1 noPhotosWrites=true
2026-10-24 18:07:37.215446+0800 LumaCamera[6174:2143083] Photo capture timed out: request=3 unfinished=4; retire old photo output
PHOTO-TIMEOUT-FOUR injected=true unfinishedBefore=4 unfinishedAfter=0 resumedPhoto=1 totalSeconds=11.993029166667839 noPhotosWrites=true
```

普通版本恢复：构建成功，已按项目正常签名安装至 iPhone 并启动，不包含测试插件，漏回调开关默认为 false、测试超时覆盖为 nil。
