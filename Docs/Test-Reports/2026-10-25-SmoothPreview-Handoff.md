# 2026-10-25 普通拍照流畅预览的成片交接

## 问题与修改

用户指出普通拍照中开启流畅预览后，EXIF数值相同，但照片明暗/拖影不符合设置。最初8张JPG/HEIF的ISO100、1/2秒和1/125秒文件EXIF均通过，这不能证明实际画面一致。用户固定静止明暗场景后，像素对照复现同参数短曝光的明显亮度差。

`submitPhotoCapture`在普通手动曝光提交前，现在先清除仅供AE使用的预览最长曝光限制，并与关闭辅助时一致地使用`updatePreviewHDR(customExposure:true)`，再等待官方custom曝光回调后提交。原`didCapturePhotoFor`不再立即恢复AE/HDR预览，统一在`finishPhotoCapture`的原生最终完成或失败清理中恢复。这样曝光前后都隔离预览策略，避免仍在原生捕获处理期间切回辅助预览。没有改EXIF伪造数值、后期补偿照片亮度、替换成预览帧，亦未改界面。

两个交接点一起修正后对照通过；未单独做两项修改的因果消融，不能把所有差异仅归因于某个HDR开关。

## 真实成片像素

iPhone17Pro/iOS27.0.1，正常项目签名。后置主摄M挡12MP，固定ISO100、WB5000/tint0、焦点，原片滤镜，HDR/Live关闭。用户固定静止场景；八次捕获覆盖JPG/HEIF、长短曝光、辅助关闭/开启。原生ISO和EXIF快门全部一致。每张实际文件用ImageIO取最长64像素缩略图，RGB按0.2126/0.7152/0.0722求平均；以下统计在0–1区间，是输出色调后的sRGB码值亮度，不是lux、线性曝光量或EV。

| 轮次 | 格式 | 快门 | 辅助关均值 | 辅助开均值 | 绝对差 |
| --- | --- | --- | --- | --- | --- |
| Pixels | jpeg | 0.5s | 0.7036 | 0.6465 | 0.0571 |
| Pixels | jpeg | 0.008s | 0.5756 | 0.3725 | 0.2031 |
| Pixels | heif | 0.5s | 0.6947 | 0.6424 | 0.0522 |
| Pixels | heif | 0.008s | 0.5795 | 0.3750 | 0.2044 |
| Handoff | jpeg | 0.5s | 0.5542 | 0.4979 | 0.0564 |
| Handoff | jpeg | 0.008s | 0.3157 | 0.3303 | 0.0146 |
| Handoff | heif | 0.5s | 0.5208 | 0.4936 | 0.0272 |
| Handoff | heif | 0.008s | 0.3124 | 0.3346 | 0.0222 |

修后四对均在预先设定的0.06平均码值差容差内；长曝光仍有约0.027–0.056残差，不宣称像素完全相同。原生照片处理、环境光变化/频闪等可能影响统计，此轮未逐项分离。已查看本地修前对照图，构图相同且短曝光明暗差异可见；文件附件保留本地测试包，未写系统相册或提交项目。

另已目视核对修后JPG短曝光开/关两图，画面明暗接近。修前与修后两轮之间构图/手机姿态发生变化，因此仅各轮内部的同参数开关对照成立，不能将跨轮差值之比当作同场景统一改善百分比。

## 性能与稳定性

- Handoff单项23.540秒通过；8次按请求至照片回调约0.234–2.658秒，长曝光约2.302–2.658秒，短曝光约0.234–0.943秒。包含原生拍摄/编码，不是显示FPS，也不与未控制同等条件的首轮耗时作提速结论。
- Recovery三项37.332秒通过：普通流畅预览20次快速开关、拍摄中关闭辅助后恢复真实M挡曝光，慢门自动辅助下HEIF实际ISO400/1/15秒，照片/视频/退出返回恢复。真实相机会话错误审计通过，临时视频检查轨道后删除。
- 普通M挡1/15秒时，3×1秒窗口发布计数关闭辅助均15，开启辅助均30；中位发布间隔约66.2–66.7ms和33.4–34.1ms。这是应用预览图发布节奏，不是屏幕扫描帧率。慢门自动辅助3×1秒窗口26/29/29次发布。
- 最终4个不同相关方法通过。Baseline与Pixels的诊断过程保留：前者仅EXIF通过，后者两项像素断言失败，未改写为原始通过。日志含系统缓存`MDB_MAP_FULL`消息；最终方法未收到携带错误的相机会话运行错误通知，不代表系统日志零警告。

## 官方依据与限制

- [Apple setExposureModeCustom](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom%28duration%3Aiso%3Acompletionhandler%3A%29?changes=_2)：完成回调提供首个应用设置的buffer时间；文档要求照片quality prioritization为speed以确保custom/locked时遵守时长和ISO。项目手动照片此前已使用speed，此次没有将balanced误当成根因。
- [Apple automaticallyAdjustsVideoHDREnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/automaticallyadjustsvideohdrenabled)：描述视频HDR流的自动管理。它不保证所有静态成片像素或色调完全一致，本次使用真实文件对照验证交接修改。

本轮静止场景主要验收明暗一致性和实际快门/ISO；未使用标定运动靶标量化拖影，不能宣称运动轨迹完全等同。未单独覆盖所有前后镜头、高像素、Live、RAW、HEIF Pro/HDR或闪光组合，未做长时功耗/热稳定性。滤镜、色彩算法和照片/视频布局不变。

结果前缀`/private/tmp/LumaCamera-SmoothOrdinary-20261025-`：Baseline、Pixels、Handoff、Recovery；像素附件位于本地结果包。详见[量化摘要](2026-10-25-SmoothPreview-Handoff-results.json)。
