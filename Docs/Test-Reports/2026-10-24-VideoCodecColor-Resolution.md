# 2026-10-24 视频编码、色彩与滤镜四项定向验收

## 结论与本轮改动

原FULL-20261024-020/021/022/023分别为编码矩阵、Log LUT烧录标记、各色彩空间与拍照恢复、SDR/P3滤镜输出。原全量多个视频用例遇到capturing=true/pending=4而没有录出文件。本轮在已有拍摄任务清理修复后，原四方法独立基线全部通过（70.839秒），未复现原失败；不据顺序单独证明每条历史失败根因。

本轮未修改生产视频录制、编码、色彩、LUT、滤镜或UI；补强测试如下：

- `VideoCodecPhysicalTests`监听实际运行错误，解码完必须是completed、至少两帧，并以首末实际PTS计算帧率，不仅检查nominalFrameRate。
- 三个色彩硬件方法改用重置的可见相机基线，补齐Log烧录、滤镜方法的会话错误监听。
- 新增Log/Log2诊断LUT对照：固定洋红输出的2³ LUT，先确认实时预览确实已变成洋红，再分别仅预览与烧录。解码文件每帧抽样，不以滤镜名或文件Log标记代替像素效果。
- 另运行既有固定彩色输入的SDR/P3黑白、美食LUT及10-bit Log缓冲测试，避免自然场景本身接近灰色使黑白判据失去区分能力。

## 官方依据与范围

Apple [canApply](https://developer.apple.com/documentation/avfoundation/avassetwriter/canapply(outputsettings:formediatype:))用于查询容器与编码设置兼容性，但实际写入仍需检查文件；[视频色彩属性](https://developer.apple.com/documentation/avfoundation/avvideocolorpropertieskey)及[iOS27 Log标记](https://developer.apple.com/documentation/avfoundation/avvideologtransferfunctionkey)用于标注输出。项目延续一次AVAssetWriter编码，通过实际轨道、位深、传递函数和像素核对；未改成二次转码。Log LUT按用户既定规则烧录到Log信号且保留Log标记，不自动改成Rec.709输出。

## 最终设备与统计

设备iPhone17Pro / iOS27.0.1（24A446），项目正常签名，未使用模拟器/镜像，所有短片为临时文件并删除，恢复拍照只用内存样片，不保存系统相册。

最终9个不同方法均有通过记录、0失败/跳过：增强硬件/规则组6项93.859秒；固定像素组3项0.156秒。增强组共产生39段短片、10次恢复JPEG拍摄，并非39段都做同样深度的解码：编码矩阵22段完整解码，LUT像素对照4段完整解码，SDR/P3滤镜2段完整解码；10色彩短片主要核对文件标签/轨道及后续拍照，1段实际资源LUT主要核对标签/位深。

### 1. 真实编码矩阵

方法33.732秒；22种组合录制矩阵耗时32.716秒。

- HEVC SDR、H.264 SDR/P3、六种普通ProRes（422 Proxy/LT/422/HQ、4444/XQ）。
- ProRes HLG HDR、AppleLog、AppleLog2；4K60 H.264/HQ，4K120 HQ/XQ。
- ProRes五种画幅及A挡后置/前置1080p30。
- 文件fourCC、比例、nominalFrameRate与请求匹配，整段解码完成；实际PTS帧率分别为30/60/120，无只靠nominal宣称匹配。当前4K120 HQ/XQ各实录约1秒，不能推广为任意时长持续录制能力。
- RAW/RAW HQ仅确认未接外盘时入口不能被选，不含外盘RAW实录/拔盘恢复验证。

### 2. 全色彩空间与拍照恢复

方法42.652秒，10种A/M×色彩组合循环41.492秒：

- SDR:709原色/709传递、8位；P3:P3_D65原色/709传递、8位。
- HDR:BT.2020原色/HLG传递、10位。
- Log:com.apple.rec2020.apple-log、10位；Log2:com.apple.apple-wide-gamut.apple-log、10位，系统文件无传统primaries/transfer字段，未硬标为BT.2020/709。
- 两挡均1080p30，采集色彩与8/10位缓冲匹配；HDR实时预览16位、P3预览色彩空间匹配。每段录完返回照片后，原生PhotoOutput恢复，输入不遗留Log色彩，10次JPEG均完成。
- HLG标记及10位不等于已逐帧验证DolbyVision动态元数据，本轮不对此作通过承诺。

### 3. Log LUT实际文件

既有资源LUT烧录方法7.836秒，1段AppleLog实际LUT保留Log标签及10位；新增Log/Log2对照方法4.920秒：

- 四段各19个已解码帧，标签保持各自Log/Log2，位深10。
- 仅预览：预览已为诊断洋红，文件抽样洋红占比0%，未烧录预览效果。
- 烧录：同一LUT文件抽样洋红占比100%，确实改变编码像素。
- 这是诊断LUT的明确开关判据，未逐个验证所有自带LUT的美术效果，也未承诺真实场景不受曝光/白平衡变化影响。

### 4. SDR/P3滤镜实际文件

方法4.718秒。两段各34帧、约1.133秒、文件平均约30帧/秒；完整解码后的平均通道差SDR约0.158、P3约0.145（8位采样尺度），黑白效果已进入视频帧。写入器两段均收到并写入34/34帧，约1.100秒PTS跨度。实时预览平均通道差均0，实际预览/输出在黑白效果上匹配。

另3项固定像素检查：彩色输入经黑白处理后RGB接近且非空，SDR/P3美食LUT使像素变化，Log LUT目标缓冲保持10位420。未用某个灰墙自然场景的低色差单独证明滤镜管线正确。

## 稳定性与性能限制

22组连续录制和10轮照片/视频往返通过，最终收到的运行错误通知未带真实AVFoundation error对象。日志仍有MDB_MAP_FULL及一次FigCaptureSessionRemote err=-12784断言文本，不将这些描述为完全无底层警告，也不凭单行推断新的独立产品故障。温度状态日志为nominal，但不是能耗/热功耗实测。

指标为实际文件解码PTS帧率或接收/写入样本数，不是屏幕显示FPS；没有独立App内存、功耗、长时4K120或外接盘测量。本轮未追加取消录制/所有生命周期用例，不能据正常停止和返回通过关闭原032。其余分辨率帧率矩阵、慢动作、电影、OpenGate、白平衡锁定等独立失败尚未本轮重测。

## 结果文件

- `/private/tmp/LumaCamera-VideoCodecColor-20261024-Baseline.xcresult`：原四方法4通过，70.839秒。
- `Enhanced.xcresult`：新增Log2诊断用例初次构建缺系统版本守卫，编译失败，未启动真机测试；已补iOS27守卫。
- `/private/tmp/LumaCamera-VideoCodecColor-20261024-Verified.xcresult`：6项通过，93.859秒。
- `/private/tmp/LumaCamera-VideoCodecColor-20261024-Pixels.xcresult`：3项通过，0.156秒。
- 同前缀`.log`与[结构化JSON](2026-10-24-VideoCodecColor-Resolution-results.json)保留指标，临时目录不保证永久保留。

原020/021/022/023已有定向通过记录，累计24个原失败方法通过，其余9项未处理/未复测。原始全量489/33/7不改写。
