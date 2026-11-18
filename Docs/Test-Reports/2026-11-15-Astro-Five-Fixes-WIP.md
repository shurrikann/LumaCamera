# 星空五项修复与图标优化：暂停记录（2026-11-15）

> 已于2026-11-16继续处理并完成集成及真实后台验证。当前状态以[正式记录](2026-11-16-Astro-Five-Fixes.md)为准；下文保留暂停时的历史状态。

用户要求今天停止，明天继续。实现仍在工作区，尚未作整体验收，不标记五项全部完成。没有正在运行的测试；真实后台交互验证尚未开始。

## 已修改

- AstroManualSettings：resolvedISO按测光ISO×测光快门/目标快门换算，处理EV、原生测光bias和offset；iOS27混合曝光能力查询及可用时原生autoISO分支。
- AstroPhotoEngine：修正fallback换算/EV，过期RAW与排队回调用capture/recovery ID隔离；记录实际RAW曝光/ISO/焦距；恢复快照和最终保存接入恢复存储。
- AstroTrailsEngine：零帧/准备阶段停止走取消清理；真实采集快照保留ISO/曝光，35mm等效焦距单独填写，未知物理焦距不伪造；接入快照/落盘保存。
- AstroStarRegistration：多星点刚体匹配，含旋转，保留原始CIImage浮点变换。缩略图位图Y坐标已修正；旧单星点translation辅助API仅供兼容测试。
- 新增AstroRecoveryStore/Journal/Panel：原子图像文件和manifest，5秒节流快照、最终快照，先落盘再提交相册，UIBackgroundTask保护及过期保留；视频Application Support持久目录、逐输出帧分段MOV、恢复时passthrough重封装；重新进入星空提供恢复入口。测试进程只暂存，不写系统相册。
- AstroModeView：后台/退出时完成或保留已有结果，停止引擎；恢复面板淡入淡出；DEBUG诊断引用允许测试实际可见场景。
- 三个子模式图标改为统一细线矢量。星轨第一版截图像Wi-Fi，已改成绕星点的长弧。最新最终图标截图仍需导出复查及用户确认。

## 实际通过的验证

1. CoreR2：14项通过，涵盖ISO/EV公式、实际文件EXIF字段、旋转配准/HDR浮点保留、恢复快照冷加载、过期保留、写入尚未结束的分段MOV冷恢复。
   /tmp/LumaAstroFive-CoreR2-20261115.xcresult
2. Physical：8项通过，包含实际RAW落盘ISO800、1/15秒、物理焦距6.765mm与等效24mm；实际2160×3840延时冷加载；8轮零帧停止后仍能拍摄；旧预览/恢复性能及胶囊交互回归；图标16组快照渲染。
   /tmp/LumaAstroFive-Physical-20261115.xcresult
3. 最新FinalCore：执行16项，15通过、1跳过、0失败。原生固定快门autoISO测试因当前格式不支持该组合而跳过，不能写成原生autoISO路径已验证通过。
   /tmp/LumaAstroFive-FinalCore-20261115.xcresult

以上均未写系统相册。完整日志同名.log。第一版图标截图位于/tmp/LumaAstroFive-IconAttachments/54D6D510-BC27-4EC0-8F54-0934D1A209D6.png，非最终星轨版本。

## 明天继续

- 当前设备格式不支持原生autoISO混合模式：重点完成fallback自动测光/EV的真实采集验证，检查固定0.22秒测光等待的限制。
- 用户已答复方便配合真实后台测试。需再次通知开始，不能直接沿用昨天的就位状态。testSystemBackgroundSavesVisibleStarCaptureAndColdReloadsIt要求测试App环境LUMA_RUN_BACKGROUND_RECOVERY_TEST=1，单独运行；看到ASTRO-BG-READY后让用户返回主屏5秒再打开。验证实际AstroModeView后台链路和恢复UI。
- 导出最新图标截图、复查星轨长弧，必要时调整后请用户确认。
- 对恢复面板补视觉检查；复查保存失败、过期与元数据快照、恢复操作的边界，完成最终集成回归及Release构建。
- 本轮尚未更新README/Architecture为完成；完成实际验证后更新README、Docs/Validation、Docs/Architecture和正式报告。

主工作区仅LumaCamera，不同步其他项目。设备UDID 00008150-001934280220401C，测试派生目录/tmp/LumaUltraWideTestsDD。没有使用子代理。
