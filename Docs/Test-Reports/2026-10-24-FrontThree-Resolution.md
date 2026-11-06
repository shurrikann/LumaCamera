# 2026-10-24 前置构图、成片方向与元数据专项

## 结果

原全量 FULL-20261024-002、003、004 已完成定向处理：测试前提修正，以及实际发现的前置横拿成片侧转修复。修复后两组真机共 13 次方法执行通过、0 失败、0 跳过（10 个不同方法，其中原三项分别在横持、竖持下重复验证）。其他 26 个原失败方法未处理、未复测；原始全量统计不改写。

## 发现与证据

1. 原三项在用户竖直固定手机后原样通过（1.351 / 6.550 / 3.436 秒）。原全量失败有姿态、横幅遗留和时机前提干扰，不能直接据宽高断言认定统一根因。
2. 两项照片用例在切到前置前调用 setFrontPhotoLandscapeEnabled(false)，但该 API 只对已经运行的前置输入生效。在前置就绪后再设置、确认实际应用和新预览，避免上一用例横幅残留；方向用例在前置就绪后重新读取物理姿态，配对结束方向通知订阅。
3. 测试前提调整后的 8 项虽全部通过，目视附件仍发现**真实缺陷**：手机横拿时人物、墙面内容侧转约 90°。说明宽高、比例、EXIF=1 和预览/成片相似都不足以证明重力方向正确；保留该中间结果，不写成产品已通过。
4. 原实现对新前置照片连接固定 0°，只在竖持下匹配传感器方向。横拿后预览在机身固定布局中仍合理，但输出缺少相对重力的旋转；原图经解码/编码归一化为 EXIF=1 后，错误直接体现在像素内容中。

## 产品修改

- CameraEngine 为当前新前置设备保留一个官方 AVCaptureDevice.RotationCoordinator，切换输入时更新或释放；快门前读取 videoRotationAngleForHorizonLevelCapture，只设置 photoOutput 的连接角度。预览、视频和 UI 布局保留原路径，不增加会话重配或画面过渡。
- sensor orientation compensation 继续关闭，系统按照片连接写入正确方向；Core Image 依文件 EXIF 解码后不再二次侧转，最终 EXIF/TIFF 归一化规则保留。
- 传感器横竖画幅状态不因照片旋转而改变；快门上下文在 90°/270° 时交换输出裁切轴。避免摆正横图后又按旧竖轴裁掉画面，也避免拉伸凑宽高。CaptureOrientation 新增纯量化轴转换，覆盖正负角度及周期角度。
- 不改后置相机、旧前置传感器、视频录制、固定焦段按钮、自动微距或界面样式。存量文件不重写。

## 真机验证

设备：iPhone 17 Pro / iOS 27.0.1（24A446），项目正常签名；没有使用镜像或模拟器，没有向系统相册保存诊断照片。

- 修复前基线：3 方法通过，11.337 秒；用户竖持的人物和背景附件朝上。
- 中间测试前提修正：8 方法通过，23.124 秒；附件发现横拿侧转，未作为最终产品验收。
- 修复后横持（UIDevice landscapeLeft，协调器 90°）：**9 方法通过，22.689 秒**。JPG/HEIF × 宽窄取景共 4 张标准画幅原图解码后 4032×3024，最终 4000×3000；动态横幅切换后输出 3000×4000，内容已摆正且仍保留约 1200 万像素。额外 A/JPG 与 M/HEIF 预览辅助动态画幅检查、M 挡重复点按与取消恢复、像素方向测试通过。
- 修复后竖持（portrait，协调器 0°）：**4 方法通过，27.204 秒**。上述 JPG/HEIF 四张均 3000×4000，M 挡照片缩略图方向一致；前置标准/广角 Live 两组原生配对识别通过。EXIF 焦距原片/成片分别一致为 31 / 20mm，最终文件 Orientation=1，TIFF 有方向字段时为 1；不是只修改应用详情文字。
- 目视复核修复后横持和竖持图像附件：人物及背景内容均朝上；预览采用固定机身坐标，成片采用重力坐标，两者比较前先换算方向。
- 性能：A/JPG 与 M/HEIF 各 8 次动态画幅切换，共 16 样本；每组中位约 44.4 / 65.9 ms，范围约 21.4–88.7 ms（模型调用到匹配预览发布，含轮询，非屏幕 FPS 或真实扫描延迟）。各 12 次快速请求后仍持续出帧，最大发布间隔约 101.8 / 120.8 ms。前置文件矩阵方法 6.002 秒；M 挡重复点按、拍摄及取消恢复 2.767 秒，均为整方法耗时，不等于单次快门延迟。
- 两组修复后日志未见带错误对象的相机会话运行错误；仍有既有 MDB_MAP_FULL 缓存日志，未据此宣称其他全量稳定性问题已经解决。

## 结果包与限制

- 原基线：`/private/tmp/LumaCamera-FrontThree-20261024-Baseline.xcresult`。
- 中间 8 项：`/private/tmp/LumaCamera-FrontThree-20261024-Final.xcresult`（名称 Final 为当时命名，随后目视发现问题，以后两组为最终修复验证）。
- 修复后横持：`/private/tmp/LumaCamera-FrontThree-20261024-Rotation.xcresult`。
- 修复后竖持/Live：`/private/tmp/LumaCamera-FrontThree-20261024-PortraitLive.xcresult`。
- 日志与结果包同前缀、扩展名 .log。临时图像附件仅留在结果包和 /private/tmp 的导出目录，不加入仓库/系统相册。
- 本轮验证横持一个方向（landscapeLeft）和竖持；另一横持方向、倒置姿态有轴转换单测，未作对应真机内容目视验收。Live 真实配对本轮只在竖持验证，横持 Live 动态片段未逐帧复核。前置 HDR/人像及其他设备未扩大验证。
- 未测实际电池功耗、纯 App 内存或屏幕 FPS。普通版本恢复构建日志：`/private/tmp/LumaCamera-FrontThree-20261024-RestoredApp.log`。

## 官方依据与项目选择

- [RotationCoordinator](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator) 区分预览与捕获相对重力的角度；捕获角度用于输出连接，不能把某机型的竖持 0° 固定当成所有姿态的值。
- [官方设备旋转示例](https://developer.apple.com/documentation/avfoundation/supporting-device-rotation-in-your-camera-app) 说明照片连接通过 EXIF 表达旋转。[Center Stage 前置相机](https://developer.apple.com/videos/play/wwdc2026/341/) 说明新传感器及补偿行为，关闭补偿后需自行保证方向。
- 固定机身预览布局、输出裁切轴在四分之一圈时互换是本项目行为；样本尺寸与实际角度是本机观测，不写成所有设备平台保证。

### 原始指标摘录

```text
FRONT-FRAMING portrait preview=(0.6219034790992737, 0.6624650955200195, 0.1378132849931717, 0.18375104665756226) photo=(0.6205093860626221, 0.6521637439727783, 0.1420792192220688, 0.18943896889686584) width-delta=0.004265934228897095 height-delta=0.005687922239303589
FRONT-PHOTO-ASPECT rapid-requests=12 recovery-frames=11 max-publication-gap=0.10182279166474473; app frame publications, not display FPS
FRONT-FRAMING landscape preview=(0.6495461463928223, 0.6225890517234802, 0.17650166153907776, 0.13237625360488892) photo=(0.6494544148445129, 0.6055100560188293, 0.19060757756233215, 0.14295567572116852) width-delta=0.014105916023254395 height-delta=0.010579422116279602
FRONT-PHOTO-ASPECT device=iPhone physical cycles=8 first-frame-seconds=[0.043440208333777264, 0.03354183332703542, 0.06654383332352154, 0.06581637500494253, 0.07684875000268221, 0.021383708342909813, 0.0762255833396921, 0.0658933333324967] median=0.0658933333324967; measured from model action to first matching rendered-frame publication, not display FPS
FRONT-FRAMING portrait preview=(0.605212390422821, 0.6488012671470642, 0.14291834831237793, 0.1905577927827835) photo=(0.6117444038391113, 0.6565006971359253, 0.1414991319179535, 0.18866552412509918) width-delta=0.0014192163944244385 height-delta=0.0018922686576843262
FRONT-PHOTO-ASPECT rapid-requests=12 recovery-frames=8 max-publication-gap=0.1208034166629659; app frame publications, not display FPS
FRONT-FRAMING landscape preview=(0.6460782885551453, 0.6182634830474854, 0.18151114881038666, 0.1361333578824997) photo=(0.6481978893280029, 0.620570957660675, 0.18197683990001678, 0.1364826261997223) width-delta=0.00046569108963012695 height-delta=0.0003492683172225952
FRONT-PHOTO-ASPECT device=iPhone physical cycles=8 first-frame-seconds=[0.034979999996721745, 0.0777586249896558, 0.044356416663504206, 0.034096041665179655, 0.08817412500502542, 0.032886666667764075, 0.08865316666197032, 0.032805958326207474] median=0.044356416663504206; measured from model action to first matching rendered-frame publication, not display FPS
FRONT-ORIENTATION initial=3 ready=3
FRONT-FILE format=jpeg framing=Optional(LumaCamera.FrontCameraFraming.standard) rotation=90.0 original=(0.0, 0.0, 4032.0, 3024.0) saved=(0.0, 0.0, 4000.0, 3000.0) nativeEXIF=31 fileEXIF=31
FRONT-FILE format=jpeg framing=Optional(LumaCamera.FrontCameraFraming.wide) rotation=90.0 original=(0.0, 0.0, 4032.0, 3024.0) saved=(0.0, 0.0, 4000.0, 3000.0) nativeEXIF=20 fileEXIF=20
FRONT-FILE format=heif framing=Optional(LumaCamera.FrontCameraFraming.standard) rotation=90.0 original=(0.0, 0.0, 4032.0, 3024.0) saved=(0.0, 0.0, 4000.0, 3000.0) nativeEXIF=31 fileEXIF=31
FRONT-FILE format=heif framing=Optional(LumaCamera.FrontCameraFraming.wide) rotation=90.0 original=(0.0, 0.0, 4032.0, 3024.0) saved=(0.0, 0.0, 4000.0, 3000.0) nativeEXIF=20 fileEXIF=20
FRONT-CAPTURE-ROTATION angle=90.0 finalLandscape=true
FRONT-CAPTURE-ROTATION angle=90.0 finalLandscape=true
FRONT-ORIENTATION initial=1 ready=1
FRONT-LIVE-FOCAL framing=Optional(LumaCamera.FrontCameraFraming.standard) native=Optional(31) saved=Optional(31) zoom=1.6 nativePixels=(0.0, 0.0, 3024.0, 4032.0) savedPixels=(0.0, 0.0, 3000.0, 4000.0)
FRONT-LIVE-FOCAL framing=Optional(LumaCamera.FrontCameraFraming.wide) native=Optional(20) saved=Optional(20) zoom=1.0 nativePixels=(0.0, 0.0, 3024.0, 4032.0) savedPixels=(0.0, 0.0, 3000.0, 4000.0)
FRONT-FILE format=jpeg framing=Optional(LumaCamera.FrontCameraFraming.standard) rotation=0.0 original=(0.0, 0.0, 3024.0, 4032.0) saved=(0.0, 0.0, 3000.0, 4000.0) nativeEXIF=31 fileEXIF=31
FRONT-FILE format=jpeg framing=Optional(LumaCamera.FrontCameraFraming.wide) rotation=0.0 original=(0.0, 0.0, 3024.0, 4032.0) saved=(0.0, 0.0, 3000.0, 4000.0) nativeEXIF=20 fileEXIF=20
FRONT-FILE format=heif framing=Optional(LumaCamera.FrontCameraFraming.standard) rotation=0.0 original=(0.0, 0.0, 3024.0, 4032.0) saved=(0.0, 0.0, 3000.0, 4000.0) nativeEXIF=31 fileEXIF=31
FRONT-FILE format=heif framing=Optional(LumaCamera.FrontCameraFraming.wide) rotation=0.0 original=(0.0, 0.0, 3024.0, 4032.0) saved=(0.0, 0.0, 3000.0, 4000.0) nativeEXIF=20 fileEXIF=20
FRONT-CAPTURE-ROTATION angle=0.0 finalLandscape=false
FRONT-CAPTURE-ROTATION angle=0.0 finalLandscape=false
```

普通版本恢复：构建成功，已正常签名安装至 iPhone 并启动；不包含测试插件。
