# 2026-10-27 虚拟光圈拖动背景修正

## 修改与官方依据

原控件为SwiftUI系统Slider叠加可交互PreviewSurface，iOS26+按压时两层动态外观可能叠加。依据[UISlider官方说明](https://developer.apple.com/documentation/uikit/uislider)，只设置tint仍保留系统动态效果，自定义轨道图才停止该动态外观。

新增VirtualApertureContinuousSlider，仍使用UISlider的连续调节与无障碍行为，但普通/高亮/选中/禁用状态共用固定轨道和滑块图，内部透明、不生成第二个背景。外层玻璃保留，只有虚拟光圈条关闭interactive；PreviewSurface其他调用默认保持原交互。iOS18仍使用原SwiftUI Slider与原背景分支。滑块位置、外框宽高、连续数值映射、默认值、点按复位及星芒算法不变，照片与视频共用修正。

touchDown开启交互预览，valueChanged连续更新，touchUpInside/touchUpOutside/touchCancel及视图销毁释放编辑状态，避免取消后预览代次门控悬留。图像只在控件创建时生成，不在每次调节重建。

## 真机验证

iPhone17 Pro / iOS27.2（24B119），正常项目签名。两个不同硬件方法最终通过：照片15.904秒、视频20.172秒，整项含等待，不是帧率。

- 照片在M挡且原生控件isEnabled确认为true时验证高亮，普通/高亮轨道图内容一致，截图已目视检查，仅一层外框、无额外按压背景。通过UIControl事件与isHighlighted模拟按压状态，没有注入真实手指触摸，不声称已验收所有手势细节。
- 原生控件三轮共270次valueChanged、取消/界外松手/界内松手均恢复；每轮约1.552/1.546/1.558秒发布57/47/46张应用预览，最长间隔42.2/41.4/38.7ms。应用发布时刻不等于屏幕FPS或真实手指触控延迟。
- 照片28组画幅/方向布局与主摄/长焦实际文件通过，保留真实EXIF光圈及独立虚拟参数；主摄/长焦本轮临时出片约0.498/0.544秒，各一张，不与其他场景严格比较性能。
- 视频20组画幅/方向布局、三轮180次数值更新、录制隐藏/停止恢复、互斥及照片/视频返回通过。三轮各31张预览、最长间隔约37–40ms；HEVC720p、P3 H.2641080p、HEVC4K及常规ProRes1080p均30帧短片完整解码，最终接收/写入61/61、38/38、38/38、38/38。临时媒体未进系统相册。

结果包：`/private/tmp/LumaCamera-ApertureSlider-PhotoFinal.xcresult`、`/private/tmp/LumaCamera-ApertureSlider-VideoFinal.xcresult`；日志同前缀.log。高亮截图在PhotoFinal-Images目录。

## 保留问题与限制

初组照片通过，视频在刚发布ready/后置镜头ID后立即读取look得到nil，断言失败；随后持续更新及四组录制均正常。测试改为等待实际look应用后再断言，复测约4.83ms等到正确值并通过，没有用ready替代全部异步提交完成。首组高亮截图受近景A挡微距禁用条件影响，补在明确可交互状态验收，不将禁用截图当按压通过。启动曾被锁屏阻断，解锁后继续。

未全量测试，未在iOS18真机、VoiceOver、不同系统外观或长时功耗下逐项验收；真实手指拖动观感仍待使用反馈。未改曝光条、其他滤镜滑块或全局液态玻璃样式。

正常Debug构建、安装及启动成功，真机安装序号1672；机器指标见同名JSON。
