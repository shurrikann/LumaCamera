# 普通M挡最低快门恢复自动：调查中

**后续进展**：2026-10-26已完成同会话恢复策略与定向真机验证，[后续报告](2026-10-26-SlowestShutterAuto-Recovery.md)。本页保留当时未解决状态及撤回试验的历史记录。

用户反馈最低快门恢复自动仍慢，并明确选择保留真实曝光预览，不接受普通M挡自动开启流畅预览。此问题未解决，不把测试通过写成延迟已修复。

设备iPhone17Pro/iOS27.0.1，正常签名。新增`ManualAutoRecoveryPhysicalTests.testSlowestOrdinaryShutterReturnToAutoLatency`，普通照片M挡ISO100/1秒，关闭/开启流畅预览各3次。最终测法先等长曝光至少2.5秒稳定，再分别额外等150/450/750毫秒点击自动；订阅点击之后的新读数，避免拿旧自动读数冒充即时响应。未拍照、不写相册、未启动模拟器。

## 保留原行为的基线（Settled）

|流畅预览|样本|硬件自动状态观测|新自动读数|窗口内最长预览发布间隔|
|---|---:|---:|---:|---:|
|关|1|1.345秒|2.457秒|1.355秒|
|关|2|2.031秒|2.148秒|2.043秒|
|关|3|1.737秒|2.856秒|1.749秒|
|开|1|0.015秒|0.037秒|0.046秒|
|开|2|0.010秒|0.033秒|0.045秒|
|开|3|0.012秒|0.043秒|0.043秒|

六次均恢复真实连续自动曝光；单方法36.921秒通过只证明最终恢复，没有证明足够流畅。硬件状态通过会话队列查询，可能包括队列阻塞；发布间隔是应用交付UIImage的间隔，不是屏幕呈现FPS或首个真正自动曝光像素的时间，窗口包含恢复后约1秒。样本量小，不能泛化所有场景。

## 已试验并撤回的方案

本地日志/xcresult前缀`/private/tmp/LumaCamera-SlowestAuto-20261025-`：

- `Baseline`/`Phases`：较早快速改值测试确认1秒设置后自动读数约2.32–2.97秒；AE模式setter本身很快，HDR恢复调用可阻塞，但不能据此认定唯一根因。
- `Deferred`：按属性缩短后延后恢复HDR，新读数仍约2.48–3.14秒。
- `ShortHandoff`：先请求短曝光再立即切AE，新读数仍约2.35–2.95秒。
- `AutoHDR`：只归还HDR自动管理权，新读数约2.67–3.29秒。
- `Batched`：会话事务合并AE/帧时长/HDR，新读数约2.70–3.28秒。
- `FrameHandoff`：由新预览帧触发HDR恢复，新读数约2.70–3.19秒。
- `AppliedHandoff`：等待短曝光应用回调再切AE，含后备路径，约3.31–3.97秒，更慢。
- `HDRIsolation`：临时跳过HDR恢复，仍约2.66–3.29秒，排除“HDR是唯一原因”的过早判断。
- `FrameFirst`：稳定长曝光后先重置帧周期及AE上限，新读数约2.47–3.13秒。
- `Connection`：短暂关闭/开启原生预览连接，发布间隙更大，没有实际收益。
- `Unlock`：iOS27官方自动ISO/自动曝光时长组合在当前格式查询支持，但立即交还连续AE后仍无实际收益。

上述试验均无足够收益，生产实现全部回退，仅保留分阶段DEBUG追踪和新的诊断测试。没有自动启用流畅预览、限缩用户手动曝光、修改保存文件参数或添加假自动读数。不同试验的部分环境、等待时长及读数测法不同，不作严格跨组平均速度比较。

## 官方依据与边界

[曝光时长](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration)受当前格式上下限约束；[手动曝光接口](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))的完成回调对应设置生效，文档没有承诺一秒真实曝光切回自动的固定低延迟。[HDR流开关](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isvideohdrenabled)可能触发耗时重配置，但本次隔离观察表明不能只归因于HDR。传感器长帧、自动曝光过渡及ISP缓冲各自占比仍未明确；没有把推断写成平台保证。

后续继续研究真实曝光预览下的恢复时序；30秒单帧硬件支持与30秒多帧合成是另一问题，本次没有增加30秒快门功能。
