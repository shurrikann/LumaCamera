# 2026-10-25 电影模式实际景深效果核对

结论：在用户准备的人物场景中，系统Cinematic景深效果已作用于预览和实际编码视频。强/弱模拟光圈对照有可见的前后景清晰度差异；本次不是仅凭开关或文件可播放判定。未修改正式电影管线或界面。

## 官方依据

苹果[`isCinematicVideoCaptureEnabled`](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/iscinematicvideocaptureenabled)说明启用后效果可作用于video data output等输出；[`simulatedAperture`](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/simulatedaperture)用于调节景深模拟程度，须在支持范围内且不能在录像中修改。本次按要求在每段录像之前改变诊断光圈，未在录制中改写该属性。正式入口仍使用活动格式默认光圈。

## 真实对照

- iPhone17Pro / iOS27.0.1，正常项目签名；用户后置对准人物并确认准备完成。无模拟器或镜像，不向系统相册写入测试媒体。
- 新增DEBUG诊断钩子和`CinematicEffectPhysicalTests/testSimulatedApertureChangesPreviewAndRecordedBackground`，9.957秒通过。首次构建遗漏iOS27新增元数据类型的版本保护，仅编译失败；补充保护后运行通过。
- 1080p30 SDR HEVC，四段：默认f/2.8、强虚化f/2、弱虚化f/16、再次强虚化f/2。各段实际光圈匹配，时长分别0.803、0.789、0.775、0.784秒；读取各文件约0.4秒处的真实帧。
- 四次系统元数据均出现face、humanBody等主体对象。测试通过现有对焦入口在中心区域设置Cinematic固定焦点，未修改普通设备focusMode，未调用应用自己的照片人像模糊。
- 本地目视：f/2预览与录制帧中人物面部相对清晰，背景绿植和前景织物变模糊；f/16时上述纹理明显恢复。再次f/2仍出现虚化，说明不是首次路由偶发旧帧。记录帧带真实效果，正常播放无需应用另加模糊。
- 默认f/2.8片段中有手持运动模糊，不用它作为默认景深美术质量或主体清晰度验收。人物、构图有移动，未做像素对齐或计算“虚化提升百分比”。

## 验证范围

这是单一人物场景下的实际效果对照，四种设置包含重复与反向变化。没有验证多主体自动焦点转移、所有头发/眼镜边缘质量、所有光线距离、长时间人物运动或4K效果。前一报告的三种电影规格只验证实际文件，不能替代本次画面观察；本次也不声称自动焦点过渡已验收。

性能仅记录整方法9.957秒与四段时长；不是显示FPS、单纯景深计算耗时或独立App功耗/内存。没有带error对象的会话运行错误通知，不据此声明平台日志零警告。

临时视频在读取对照帧后删除，图像保留在本地测试结果附件中，不进入代码库或系统相册。结果：`/private/tmp/LumaCamera-CinematicEffect-20261025-Compare.xcresult`；日志同前缀`.log`。本地导出：`/private/tmp/LumaCamera-CinematicEffect-20261025-Attachments`。普通App构建日志：`/private/tmp/LumaCamera-CinematicEffect-20261025-FinalApp.log`。

另记录技术讨论：当前流水预设为8帧×约1秒平均融合，单帧长曝光仍受明亮场景限制。“白天短曝光密集采样、以总采集时间控制流水强度”只是后续优化方案，本次没有修改或验证日间流水实现。
