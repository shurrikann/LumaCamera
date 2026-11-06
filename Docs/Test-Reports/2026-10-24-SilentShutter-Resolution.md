# 2026-10-24 静音快门：夜景多批次遗漏修复

## 原失败与本轮发现

原 FULL-20261024-016 在首张JPEG前 pending=4，没有接受新请求并超时。原始日志可确认任务积压，但不是静音标志本身失败的证据。本轮生产代码不变先复测原7种组合，10.131秒通过，未再复现原超时。

检查发现静音设置只在主捕获入口的 `!options.nightMode` 分支设置，`makeNightCaptureSettings` 及追加批次均没有应用偏好。新增真实6帧夜景检查复现：两批提交量为[3,6]，请求静音true、官方支持true，但enabled都为false；照片仍完成，说明这是独立的设置遗漏。

## 修复

`CameraEngine.submitPhotoCapture` 作为统一原生提交入口，在每次提交时查询官方 `isShutterSoundSuppressionSupported`，按该组 `CaptureContext.options.silentShutter` 快门快照设置 `isShutterSoundSuppressionEnabled`。普通照片、RAW、Live、手动包围和夜景首批/追加批次使用同一路径；当前组中途改偏好不会改写已接受的快门请求。关闭或不支持时设false。不改系统音量、静音状态、Live录音、拍照格式或界面。

Apple [支持能力](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isshuttersoundsuppressionsupported)由系统决定；[请求开关](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/isshuttersoundsuppressionenabled)为单次请求属性，不支持时强设true会抛出异常。项目不绕过该限制。Apple另说明Live自身会禁用快门声，不能用Live成功取代普通照片的静音请求检查。

## 真机结果

iPhone17Pro / iOS27.0.1（24A446），正常签名，无模拟器/镜像，诊断媒体不写系统相册。

最终3个不同相关方法有通过记录：

- 普通格式/Live增强方法15.412秒：10次捕获，包括JPEG关闭/开启、HEIF开启、RAW开启、RAW+JPEG开启、HEIF Pro开启、TIFF开启、HEIF Live开启、JPEG Live开启、最后JPEG关闭。每次图像资源可解码，Live两个组合实际包含pairedVideo，不是退化成静图。系统报告supported=true，enabled随true/false请求正确变化；各次上下文、硬件token、逻辑token、顺序缓冲均归零。
- 夜景最终4.273秒：固定测光/运动输入，真实3+3帧两批拍摄，首批提交后将用户偏好改为false，两批仍是(requested=true,supported=true,enabled=true)，照片为夜景合成且任务全部清空。成片回调约2.833秒；退出实际停机，再进入收到新帧，新PhotoOptions的静音为false。不是自然暗光触发验收。
- 既有偏好快照单测0.041秒通过，证明旧请求快照不随之后偏好变化。

性能：普通10次从接受请求至结果回调的秒数约0.539、0.350、0.453、0.871、0.609、0.880、0.439、3.602、3.345、1.114；其中两次Live约3.60/3.34秒，静图8次约0.35–1.11秒。混合格式不作为同质量速度对比，指标也不是快门曝光时间、显示FPS、功耗或独立App内存。正常修复后没有带error对象的会话运行错误；MDB_MAP_FULL缓存日志仍未处理。

## 记录与限制

- 原7组合基线：`/private/tmp/LumaCamera-SilentShutter-20261024-Baseline.xcresult`，通过。
- 新增夜景失败证据：同前缀`NightBaseline.xcresult`，两批enabled=false，3.588秒失败。
- 修复后`Fixed.xcresult`：3项通过、0失败/跳过，18.933秒；夜景3.481秒，普通组合15.412秒，偏好0.041秒。
- 增加中途改偏好及退出返回后的`Final.xcresult`：夜景1项通过、0失败/跳过，4.273秒。最终汇总使用该结果替代旧夜景方法，不把重复执行数写成不同方法数。同名前缀`.log`和[JSON](2026-10-24-SilentShutter-Resolution-results.json)保留原始数据。

本轮验证实际交给系统的静音设置和文件交付，没有用麦克风做声压/录音测量，也未人工对比不同系统音量/静音模式的听感。当前设备支持静音，未在系统禁止静音的地区配置上实测；代码仍保留系统能力判断。没有逐镜头/全部分辨率/HDR/人像/所有慢门预设组合实测，不据此声称全部声音场景已声学验收。

原016已有定向通过记录，累计20个原失败方法通过，其余13项未处理/未复测，原全量489/33/7不变。
