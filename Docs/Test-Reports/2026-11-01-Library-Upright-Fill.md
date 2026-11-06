# 2026-11-01 横拍文件方向与铺满缩略图

## 已确认的问题与结果

用户确认横拍照片和视频在竖拿浏览时右转90°。仅调整相册角度后，用户复核仍失败。本轮随后读取用户实际选中的两份资源：设备方向、页面方向均为竖屏，媒体额外显示角度为0°；原照片编码2250×4000、EXIF和内容编辑输入方向均为1，图像像素本身侧着；原视频编码1440×1080，但轨道矩阵为90°，显示1080×1440，解码画面同样侧着。两份实际画面已目视确认，旧文件未被修改。

代码对应原因：后置照片输出连接固定90°，只有新前置路线使用捕获方向协调器；普通后置视频也默认把横向传感器帧按竖屏写轨道。修正后用户配合实际横拿、竖拿，各拍一张JPEG和一段约1.2秒视频：

| 实际持机 | 后置照片文件 | 视频自然编码 | 视频轨道角度 | 视频显示尺寸 |
| --- | --- | --- | --- | --- |
| 横拿 | 4000×2250，EXIF=1 | 1920×1080 | 0° | 1920×1080 |
| 竖拿 | 2250×4000，EXIF=1 | 1920×1080 | 90° | 1080×1920 |

横拍新照片和解码视频帧已经目视为正向。本次诊断拍摄没有写入系统照片。旧文件已经保存了错误的方向，需要单独旋转修正；升级应用不会重写旧文件。

## 实现与官方依据

- CameraEngine 增加后置 RotationCoordinator，在快门前获取最近90°持机方向、设置照片输出连接，并令本次 CaptureLook 选择匹配的横竖裁切轴，不改变实时预览。角度随 CaptureContext 固定；原生提交统一经 captureNativePhoto，夜景换路由/多批及曝光等待后仍应用同一快门角度。
- 普通后置视频开拍时固定协调器角度。MovieRecorder 根据该角度确定显示裁切轴和原始编码尺寸，再写入 AVAssetWriterInput.transform。保留一次编码，未旋转预览连接，也未对每帧增加软件旋转；前置原生传感器分支继续原有参数处理。RAW外接和双摄合成未接入本次新后置视频角度参数。
- GalleryView 自身持有方向观察对象，进入时按当前设备方向重置；未知/平放初始方向按竖屏打开，避免从相机继承旧角度。相册本地向照片和视频详情传递方向，App根节点不再注入媒体角度。该显示侧处理单独不能修复错误保存的旧文件。
- LibraryMediaThumbnail 改为 scaledToFill 并在槽内裁切；相册按钮不再使用圆内接小图。CaptureAlbumThumbnail 在自身已安装的环境中读取 captureControlAngle，使照片/视频封面随手持方向转正，外框和进度位置固定；相册列表封面也铺满，详情仍完整适配。
- 苹果说明 [RotationCoordinator](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator) 提供相对重力的捕获方向；[照片连接写EXIF、数据输出会旋转像素](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/videorotationangle)。[自定义AVAssetWriter视频应写输入transform](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator/videorotationangleforhorizonlevelcapture)，避免为方向改变逐帧旋转。最近90°方向及输出裁切计算是本项目实现选择，不是平台对任意构图的保证。

## 真机回归与证据

设备 iPhone17Pro（iPhone18,1），iOS27.2（24B119），Xcode27.1。证据目录 `/tmp/LumaCamera-MediaUprightFill-20261101`；各xctestrun在 `/tmp/LumaCamera-NightCancel-DD/Build/Products`。不同批次不重复累计同一方法。

- 显示/缩略图联合批次 Final：33方法中32通过、1失败，63.835秒；失败为隔离shutterBar组件读取未安装的CameraView环境得到默认0°，32条像素断言失败。改为独立CaptureAlbumThumbnail读取安装后的环境，Confirm定向3方法全部通过，17.347秒；33个不同方法均有通过结果。补测圆形距中心0.4倍直径处红蓝边缘像素，验证铺满且方向正确，按钮框不动、无重载。
- 后置编码与关联批次 Rear-Core：18方法全部通过，13.418秒。包含20个真实临时视频（四方向×五视频画幅），逐个读取轨道矩阵/显示比例并完整解码，另含前置方向、编码策略、虚拟光圈编码和延时实录。
- Rear-Landscape与Rear-Portrait：同一物理实拍方法分别通过，文件结果见表。相机实际协调器分别0°/90°，设备方向分别landscapeLeft/portrait；不是模拟器或注入角度拍摄。
- Rear-PhotoRegression：3方法全部通过，25.874秒；JPEG/HEIF Live配对解码、三次夜景及四次夜景开关后停启恢复普通拍摄通过。此批确认采集、配对、输出和任务释放，不重新宣称暗房画质提升。
- 合计55个不同回归方法已有通过结果；全项目未全量重跑。临时显示状态记录只含角度、尺寸、资产标识，未包含图片、位置或上传，定位完成后已移除生产诊断代码。只读保存资源检查保留为显式环境开关测试，普通回归默认跳过。
- Final-UI在诊断清理后3方法再次通过，17.364秒；最终Release通过、源码警告0，AppIntents仅工具提示，普通App已恢复。

## 性能、稳定性和范围

Confirm相册按钮32组照片/视频、四方向重复与全部照片画幅取值：截图绘制中位36.524ms、最大50.792ms；缩略图18次方向设置绘制中位39.658ms、最大44.719ms，只请求2次、取消2次。全屏相册在外部环境固定90°时，内部六次方向更新实际到达PhotoZoomScrollView，中位11.181ms、最大11.866ms，包含10ms轮询，不能作为手持传感器延迟或动画完成时间。后置20个短片编码并解码总墙钟每片约0.27—0.30秒，具体样本见JSON；这些指标均非屏幕FPS。重复操作、40次快速方向变更、退出重开、Live取消、缩放返回及夜景取消/停启沿用上述定向回归。

实际物理验收覆盖后置主摄、普通JPEG与HEVC SDR 1080p30、一个横拿方向和正竖拿；其他两个方向由真实临时视频矩阵/解码测试覆盖，未新增人工物理实拍。未新增所有镜头/HEIF Pro/RAW/DNG/外接RAW/双摄/慢门视频帧合成的横竖实拍或长期热稳验收。旧文件未自动旋转或覆盖。SLOW-RESUME-001与SLOW-META-001仍保留原状态。
