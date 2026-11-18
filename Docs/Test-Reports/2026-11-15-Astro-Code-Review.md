# 星空模式当前代码复核（2026-11-15）

本轮仅检查及测试，未修改拍摄实现。

## 已接通的变更

- 星空照片：RAW 连拍、平移配准、三组时域中值、后处理和实际格式/比例编码。
- 星轨：分钟级/不限时，拍摄中快门已允许调用 stopAndSave，自动完成保存。
- 延时：手动停止允许保留至少一个有效输出帧；零帧丢弃，自动结束仍要求30帧。
- 三个引擎拍摄开始时均传 lockAutomaticParameters=true，自动白平衡增益在拍摄开始锁定。
- 后台改为发起照片 interruptAndSave、星轨 stopAndSave、延时手动停止保存。尚未实测后台终止/恢复。
- 星空照片保存优先采用实际 RAW ISO/焦距。

## 剩余发现

1. 自动 ISO/EV 联动未完成：照片每帧开启自动曝光0.22秒后只读取ISO，再改用用户快门；未按测光时曝光时长换算，也未在该最终路径应用手动EV。星轨/延时自动ISO仍为读取当前ISO后锁定，没有照片引擎的重新测光步骤。
2. 星轨零帧停止：finish 在 accumulator=nil 时直接返回，未清 capturing/isCapturing；极早停止或首帧前切后台可能仍停留拍摄态。
3. 星轨焦距写入13/24/100等固定值到EXIF FocalLength，未取真实物理焦距，也未单独标记35mm等效。星空照片无RAW焦距时也使用此类回退。
4. 星空配准仅估计亮点重心平移，变换通过8位sRGB图像；没有旋转配准，RAW精度链路仍不完整。
5. 后台保存仅发起异步处理，未见后台任务保护或可恢复落盘检查点；不能视为中断恢复已经完成。

以上为代码路径发现，未将潜在画质或后台失败写成实拍复现。

## 本轮验证

- iPhone 17 Pro，iOS 27.2.1；重新编译后在真机运行11项测试，11/11通过、0跳过，测试用例累计0.227秒（非构建/安装总耗时）。
- AstroImageEncoderTests 3项；AstroManualSettingsTests 3项；AstroStarRegistrationTests 1项；AstroTemporalMedianTests 1项；AstroTimelapseStopPolicyTests 3项。
- 范围：编码/裁切/水印、参数边界、合成图平移、三组中值、停止判定。非实际星空采集、系统相册保存、后台恢复或长时性能验收。无媒体拍摄或系统相册写入。
- 证据：/tmp/LumaAstroReview-20261115.log、/tmp/LumaAstroReview-20261115.xcresult。
- 已结束测试并成功启动普通App。
