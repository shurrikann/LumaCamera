# 2026-11-17 固定半秒焦段与变焦轮共用入口

## 当前实现及结论

按钮的标准A挡后置及当前镜头可连续调节路径使用FocalZoomAnimation：CADisplayLink按显示时钟产生固定0.5秒的对数倍率曲线，再换算成虚拟转盘拖动量。按钮与转盘共用applyZoomWheelDelta，统一计算范围并进入applyZoomValue / CameraEngine.setContinuousZoom；不在该路径使用旧帧缩放、selectLens或系统ramp。快速重新点击替换旧曲线；开始手动拖动、捏合、拍摄、切模式、退出相机取消旧任务。减弱动态效果直接设置目标。

48MP固定镜头和M挡跨物理镜头仍保留原有固定切镜规则，未将其声明为已支持半秒连续变焦。星空独立物理镜头路径未在本轮扩大修改。主摄同镜头预设和录像可复用连续路由。

早期固定半秒版用户反馈与原版相似；最终共用换算入口版用户确认已有改善，跨镜头轻微跳动仍保留为残留问题。独立预览帧流/UIImageView尝试已撤销，沿用原SwiftUI真实预览。当前问题仍在实际画面与镜头交接的核对阶段。

## 真机验证

iPhone17Pro/iOS27.2.1，Xcode27.2。诊断Photos写入0次。

- /tmp/LumaFixedHalfSecondFocalR2.xcresult：1项集成通过，8次1/2/4/8倍率双向路线，实际命令轨迹完成0.497—0.524秒；采样硬件倍率单调、真实中间值多于3个。另含5次快速重选和后台取消。测试直接调用动画入口，不冒充用户手指点击。
- /tmp/LumaSharedWheelFocal.xcresult：最终共用拖动换算入口后2/2通过，含既有捏合真实硬件回归；8次定时变焦0.492—0.523秒，同样覆盖重选/取消。时长是命令轨迹与调度，不是所有物理镜头新画面的可见延迟保证；发布图像数量不代表屏幕FPS。
- /tmp/LumaFocalActualScreen.xcresult：保留启动设置，实际为standard/JPEG/A/Live关闭，自动调用焦段按钮动作并取得180帧ReplayKit应用录屏，麦克风关闭。导出/tmp/LumaFocalScreenShots；逐帧检查，不据单一回调判断观感。录屏用例须LUMA_RUN_FOCAL_SCREEN_TEST=1显式开启，常规回归跳过授权录屏。
- /tmp/LumaFixedHalfSecondRelease.log：核心驱动Release编译通过，源码error/warning为0，保留AppIntents工具链提取提示；之后共享换算小重构的Debug含测试构建通过。

## 参考

Apple CADisplayLink targetTimestamp用于下一次屏幕更新的目标时刻；具体呈现仍受设备帧节奏与系统调度影响：https://developer.apple.com/documentation/quartzcore/cadisplaylink/targettimestamp 。实际相机倍率与录屏为本次观测，未将显示时钟设置当作硬件零延迟保证。


## 最终实际反馈与交付状态

用户在共用入口版实操后反馈：“目前好多了，变焦轮不跳，焦段条的话跨镜头的时候会有轻微跳动”。保留现有固定半秒共用入口，未把跨镜头残留列为已消除。普通App已恢复。

/tmp/LumaSharedWheelFocalRelease.log：最终共用入口Release构建通过，源码error/warning为0，AppIntents工具链提取提示仍单列。实际屏幕录制与本地Vision帧间配准只用于诊断，不将配准估计当作设备倍率或帧率指标；录屏近距场景含对焦与视角变化，不能直接归因为更换会话输入。
