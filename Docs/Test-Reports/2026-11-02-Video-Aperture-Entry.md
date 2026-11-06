# 2026-11-02 视频虚拟光圈新入口

## 原因和修复

新入口位于视频子模块按钮上方，但toggleVirtualApertureSlider仍有captureKind == .photo的旧限制，视频点按直接返回。现在照片/视频共用展开动作；拍照采集中和视频非录制忙碌阶段拒绝，正常录像中可调渲染参数。照片顶部浮层仍仅在照片显示；视频使用现有入口上方的独立竖向滑块，不挪按钮位置。

删除CameraView里叠加在可见按钮上方的透明重复Button，保留唯一可见入口与原位置。竖向Slider的onEditingChanged同时接入setDepthControlEditing及原滤镜编辑通知：拖动持有不自动收起，释放重新计时3秒；退出清理编辑状态。保留既有淡入淡出和减弱动态效果规则。

## 真机验证

设备iPhone17Pro，iOS27.2（24B119），正常项目签名。测试启用DIAGNOSTIC-PHOTOS-READONLY，视频只存临时文件并删除；不使用镜像或模拟器。

VideoApertureEntryPhysicalTests.testVideoVerticalEntryLayoutHoldAutoHideRecordingAndExit通过，11.653秒：复用实际App相机窗口，5种视频比例均能通过生产展开动作显示竖向滑块，滑块底边在按钮上方，展开前后按钮中心误差<=1pt；窗口对应位置有触控命中。5次动作到几何登记的最大时间25.157ms（布局/主线程发布指标，不是屏幕呈现耗时或FPS）。持有3.2秒不关闭；60次连续参数更新；释放后追加操作重新计时；10次快速展开/取消；实际临时录像期间调节、停止并回退照片均通过。没有人工手指点按或横持的本轮观感验收。

附带DepthToolbarPhysicalTests.testDepthSlidersThreeSecondIdleResetHoldAndCancellation运行36.475秒但有3条失败断言：人像首次持有被关闭、后续计时对应2.519秒（小于测试2.9秒下限）。该方法后续照片虚拟光圈三次自动收起为3.016/3.025/3.025秒；不能把整个方法记为通过。人像首次展开的初始化时序单独待查，本轮没有修改人像控制逻辑。

第一轮测试另建完整CameraView并共享model，22秒未就绪，导致测试窗口离页停机会话相互干扰；改为使用实际App窗口后视频用例通过。保留失败，未用放宽就绪超时或改生产会话掩盖。

证据目录/private/tmp/LumaVideoApertureEntry：Related.xcresult为测试宿主失败，ActualWindow.xcresult为视频通过及人像首次持有失败；BuildActualWindow.log构建通过。Release构建通过（仅AppIntents无依赖提示），已正常签名安装并打开普通App，见Release.log、Install.log、Launch.log。未做全量测试、长时间热稳或实际显示帧率测量。
