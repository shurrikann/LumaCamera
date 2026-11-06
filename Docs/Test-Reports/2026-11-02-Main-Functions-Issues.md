# 2026-11-02 主要功能问题清单

本轮只测试和记录；没有修改生产代码或测试断言。首次失败与独立通过同时保留，“独立通过”不代表连续问题已修复。

## 确认的用户可见问题

| 编号 | 优先级 | 当前问题 | 证据与下一步 |
| --- | --- | --- | --- |
| MAIN-001 | P1 | 视频虚拟光圈入口缺失，已有处理能力无法由菜单开启 | [视频菜单](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCamera/Features/Camera/Views/CameraToolsPanel.swift:26)只有延时/慢动作/电影；[内部开关](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCamera/Features/Camera/ViewModels/CameraViewModel.swift:2432)、滑条和编码仍在。VideoVirtualAperture测试直接调用模型因而通过；其menu-four-options截图实际只有三项。恢复入口并补入口验收。 |
| MAIN-010 | P3 | 关于页仍写“光绘和慢动作仍在规划中” | [当前文字](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCamera/Features/Camera/Views/CameraSettings.swift:96)与实际已实录通过能力不符。更新当前能力描述。 |
| MAIN-011 | P3 | 夜景无障碍说明仍仅描述三帧 | [当前说明](/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCamera/Features/Camera/Views/CameraToolsPanel.swift:83)未反映3/6/9帧分批自适应。同步用户说明；不等于多帧功能未实现。 |

MAIN-001的[真机菜单截图](/tmp/LumaCamera-MainFunctions-20261102/Video-attachments/51EB0E22-6C1D-4584-9EFA-34FD68AA1466.png)也仅显示三个选项；截图名中的four-options属于旧测试命名，不能作为四项存在的证据。

## 连续运行异常：独立复验均通过，仍需定位基线或时序

| 编号 | 优先级 | 首次观测 | 独立结果 / 后续 |
| --- | --- | --- | --- |
| MAIN-002 | P2 | HEIF HDR只有2250×3000，低于测试11MP门限 | 独立3000×4000、10bit通过。先固定镜头、倍率、画幅和恢复完成条件，区分合理裁切与输出退化。 |
| MAIN-003 | P1待复现 | 静音Live由HEIF改JPG后45秒没有成片回调 | 独立Live JPG约4.114秒、两份资源通过。复验连续格式切换和原生回调归属，不能以独立通过关闭。 |
| MAIN-004 | P1待复现 | 视频返回照片后Live不可用，预期动静两资源只交付一份静态图 | 独立6次Live/HDR/M挡往返通过。核对能力刷新与可点击时机，补固定路线/模式的连续序列。 |
| MAIN-005 | P2 | 景深滑条持有时已不满足可见条件，首次计时观察2.505秒 | 独立6次约3.006—3.028秒、持有和取消通过。记录工具栏页、模式准备及可见条件，定位初始状态/异步UI边界。 |
| MAIN-006 | P2测试问题 | 前置广角用例未进入前置 | 用例无条件flipCamera，上一用例已留在前置时会切回后置；独立六状态通过。先修测试朝向基线，再谈产品回归。 |
| MAIN-007 | P2测试时序 | 冷启动旧会话停止后ready尚为true | actualSessionRunning为false，仅ready即时发布断言失败；独立通过。等待引擎及主线程状态收敛，检查是否仍有真实可点击窗口问题。 |
| MAIN-008 | P2待查 | 两项长焦导航在直接创建系统双摄测试后无8×小窗 | 用户正常中远景下独立两项通过，Live/RAW与倍率恢复通过。直接系统会话测试影响/当前朝向或宏距条件需要明确，不直接判定普通导航失效。 |
| MAIN-009 | P2待查 | 白平衡locked后红/蓝增益变化约0.00317/0.00220 | 独立六组偏好/路由通过。确认首帧收敛、硬件量化或应用重写；尚未证明用户可见色温漂移。 |

## 能力条件与验收空缺

- MAIN-012：系统多模态模型当前返回deviceNotEligible，Vision回退已真实运行。属于当前系统可用性限制，不能写成已启用系统大模型，也不能从返回值推断具体地区/语言原因。
- MAIN-013：真人场景智拍未完成可靠推荐点对齐，跳过；自然暗景未达到现行触发门限，未实际拍摄。需要补真实取景闭环和自然暗景质量验收，而非继续只验证内部开关。
- 延续VIDEO-STAB-001：用户仍感有些抖动；本轮防抖生效及帧时间检查不关闭观感问题。
- 延续SLOW-RESUME-001：长期后台返回卡死未复现；短恢复与进程模型重建通过不足以关闭。
- 延续SLOW-META-001：此前星轨编码尺寸与EXIF PixelX/Y不一致，未在本轮专项关闭。
- RAW外接实盘、DockKit配件、系统相册实际写入/编辑覆盖仍为未验范围，不归为已经证明失效。

优先处理MAIN-001，再定位MAIN-003/004的连续操作风险；其余问题按真实用户症状和可复现性推进。完整统计、覆盖和指标见[回归报告](2026-11-02-Main-Functions.md)。
