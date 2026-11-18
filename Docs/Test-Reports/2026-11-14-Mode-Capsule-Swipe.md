# 模式胶囊滑动修复（2026-11-14）

## 变更

- 快门左侧照片/视频/星空入口与星空右侧照片/星轨/延时入口共用 `ModeCapsuleTouchSurface`。
- 关闭时长按 0.34 秒展开，同一次长按继续跟踪移动和松手；已展开时接受新的拖动或点击，不再要求重新长按。行图标不再各自竞争点击手势。
- 以按钮中心映射三行目标，松手提交一次；取消或远离胶囊松手不提交。靠按钮边缘静止长按只展开，不误切换。
- 操作开始取消旧的三秒收起任务；松手留在当前模式时重新计时。消失或切后台关闭胶囊并取消任务。
- 胶囊沿用淡入淡出；减弱动态效果使用 0.08 秒，普通为 0.16 秒。原生触摸层不参与动画，避免展开时触摸坐标系跟随尺寸插值。按钮布局尺寸不变。

## 官方依据与观测

- Apple [Handling long-press gestures](https://developer.apple.com/documentation/uikit/handling-long-press-gestures)：长按是连续手势，识别后持续接收 changed，手指离开原视图仍可继续跟踪，抬起进入 ended。
- Apple [require(toFail:)](https://developer.apple.com/documentation/uikit/uigesturerecognizer/require%28tofail%3A%29)：用于明确点击与持续手势之间的识别依赖。
- 代码检查发现旧实现每次拖动均经过 LongPress→Drag 串行识别，展开行另有 onTapGesture。此处作为应用实现问题处理，不据此断言 SwiftUI 平台缺陷。
- 初次挂载回归发现展开后触摸层高度仍为 116.979、收起后 68.700，处于动画插值中；触摸层取消动画后相同断言通过。

## 验证

设备：iPhone 17 Pro（iPhone18,1），iOS 27.2.1（24B156）。Debug 真机构建通过。

最终真机自动回归 `ModeCapsuleInteractionTests`：3/3 通过，9.405 秒。

| 项目 | 样本与结果 |
| --- | --- |
| 手势状态稳定性 | 1000 轮，覆盖上下拖动、展开后点击、快速重新进入、取消后迟到松手、远处松手与边缘静止长按；无断言失败 |
| 布局 | 3 主模式 × 3 星空子模式 × 4 内容角度 = 36 组；两按钮外框保持 52×52、组布局 180×52 |
| 实际挂载回调链 | 两侧各滑动选择一次、点击选择一次、取消一次；实际状态随回调更新 |
| 旧收起任务取消 | 两侧分别在原三秒截止前重新按住，跨过旧截止后仍保持展开；松手可切换 |
| CPU 性能 | 1000 轮处理序列，中位数 0.00717ms，P95 0.00754ms。包含测试断言，只代表回调处理成本，不代表触摸延迟、帧率或整次模式切换耗时 |

自动化通过真实 UIKit/SwiftUI 挂载视图的协调器回调验证，未通过操作系统合成真实触摸。普通 App 已恢复。用户真机确认：快门左侧与星空右侧均可长按不松手滑动、展开松手后再滑动、展开后点击图标，六项实际操作均正常。该结论来自用户实际操作反馈，未量化真实触摸延迟。无照片/视频拍摄，无系统相册写入。

证据：

- `/tmp/LumaCapsuleSwipe-StableTouchTests.xcresult`
- `/tmp/LumaCapsuleSwipe-StableTouchTests.log`
- `/tmp/LumaCapsuleSwipe-DeviceBuild-Final.log`
- 中间失败记录：`/tmp/LumaCapsuleSwipe-FinalDeviceTests.xcresult`（触摸层动画修复前）

复跑：使用 `xcodebuild build-for-testing` 构建后，执行 `test-without-building -only-testing:LumaCameraTests/ModeCapsuleInteractionTests`，目标为连接的 iPhone。
