# 2026-10-29 慢门 A/M 预设与时长恢复

## 当前规则

- A→M：保留慢门功能，暂不应用 A 挡预设，拍摄时长重置为 1s；M 挡之后仍可自行调时长。同挡位 M→M 的内部同步不重置用户刚调的值。
- M→A：恢复离开 A 挡前选中的预设及其有效时长（包括合法的∞）；没有预设则回到 A 挡通用 1s，不沿用 M 挡时长。
- A 挡主动取消预设后，M→A 不会复活该预设。关闭慢门再开启清空记忆，从无预设、1s 开始。
- 开启保存拍摄设置时，额外保存 A 挡预设与时长快照；停在 M 挡重开也能回 A 恢复。旧存档缺少新字段时安全迁移。

## 实现

`CameraViewModel` 单独记录 `slowShutterAutomaticPreset` / `slowShutterAutomaticDuration`，真实切挡时保存和恢复；`SavedCaptureState` 新增同名可选字段。只改状态切换，不改曝光规划、合成算法、系统自动微距和现有过渡路径。

本次构建发现 `CameraFocalButton` 向不存在的 `CameraFocalControl.usesEnclosingGlassBackground` 属性赋值，仅移除该行失效赋值以恢复编译，没有改当前布局、渲染分支或背景样式。首次构建失败日志保留，修复后 build-for-testing 通过。

## 真机验证

设备 iPhone 17 Pro / iOS 27.2（24B119），正常项目签名，有线单机串行；未启动模拟器。三个相关方法全部通过，均确认诊断相册只读标记，不保存或删除系统相册媒体。

1. 五个预设各一轮 A→M→A：M 为1s；M自行选3s、同挡同步保持3s；A恢复原预设及自选有效时长。
2. 无预设通用5s→M恢复1s→M自选3s→A恢复1s；主动取消预设不复活；10次快速往返最终状态正确；关闭/重新开启无预设且1s。预览持续存在，过渡覆盖层释放，pendingPhotoCount=0。
3. M挡存档重建后回A恢复光轨/30s；旧字段缺失仍可解码。既有后置切镜回归验证光轨、流水与不同焦段，切M/回A及退出重进规则通过。

性能可重复指标：五预设测试脚本每轮分别2.631、2.553、2.472、2.560、2.449秒；每轮含A→M、M内改时长、M同挡同步、M→A、队列屏障和过渡层释放检查，**不是单次切换延迟、屏幕FPS或显示扫描时间**。快速往返10轮仅检查最终收敛，不把瞬时中间状态视为每帧正确。日志未检出相机会话runtime error；未做独立功耗、温度或长期内存测试。本轮没有拍摄合成样片，不宣称重新验证成片画质。

## 证据

- `SlowShutterPresetTests/testSlowShutterModeRoundTripRestoresAutomaticPresetAndResetsManualDuration`：17.034秒；`/private/tmp/LumaCamera-1029-SlowAM/ROUNDTRIP.xcresult`。
- `CaptureStatePersistenceTests/testSlowShutterAutomaticPresetSurvivesManualRecreation`：0.062秒；`/private/tmp/LumaCamera-1029-SlowAM/PERSIST.xcresult`。
- `SlowShutterPresetTests/testSlowShutterAllowsSwitchingRearLenses`：3.882秒；`/private/tmp/LumaCamera-1029-SlowAM/LENSES.xcresult`。

构建日志：`/private/tmp/LumaCamera-1029-SlowAM-build.log`（缺失属性失败）、`/private/tmp/LumaCamera-1029-SlowAM-build2.log`（成功）。结果JSON保留阶段、日志路径和只读隔离检查。
