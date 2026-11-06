# 夜景手持容错、降噪与渐亮预览

日期：2026-10-30。设备：iPhone17Pro，iOS27.2（24B119），Xcode27.1。仅主项目维护。

## 完成内容

修正已有Vision平移配准方向：SDK明确targeted image是floating，handler处理reference，旧代码传反。增加小幅旋转/轻微透视补偿和残差选优；平移快速路径不够时尝试受约束单应变换，失败时以小角度+平移补偿兜底。允许部分有效帧融合，局部运动继续保留参考，不强行平均重影；未扩大拍摄曝光、序列时长或资源上限。

自动影调融合的运动探针增加轻微平滑，减少把高ISO颗粒当运动而过度退回参考；暗部降噪随之后的提亮幅度增加，取消该路径额外颗粒锐化。手动曝光原非自适应融合像素配方保持。

夜景实时取景有独立显示提亮，低频测光并平滑取得0–1.5EV补偿；保存路径不消费预览标志。拍摄过程按收到的帧推进加亮显示，再淡入真实成片、短暂停留并恢复取景；只作用于预览区域，不使用白色蒙层，不移动控件。取消/后台/新拍摄按token隔离，减弱动态效果使用短动画。

成功融合的JPG/HEIF写CompositeImage=2（通用合成）、源/实际对齐张数与实际源曝光数组。总历时未知用ImageIO未知值0，不用快门秒数相加冒充批次总耗时。单帧回退不新增合成标记。当前ImageIO TIFF写入器保留CompositeImage及曝光数组，但会丢弃SourceImageNumberOfCompositeImage，未编造该字段已写入。

## 最终验证

27项真机定向测试通过，0失败/0跳过，73.517秒。日志`/tmp/LumaCamera-NightHandheld-Clean.log`；结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_14-41-06-+0800.xcresult`。

- 受控平移9/−6像素，实际补偿−9/+6，3帧参与，融合与同裁切参考的平均8位像素误差0。−3°/+2.5°/+1.5°及8/−5像素位移样本保持至少2帧融合，并实际使用旋转/透视补偿，裁切小于28%；这是测试边界，不是所有手持动作的保证。
- 320×240独立RGB噪声，暗部10400像素：三帧平均亮度38.07→76.57；归一化亮度标准差0.2664→0.0433，归一化色差均方根0.9216→0.1613。6/9帧同类指标继续下降。对照是人工含噪单帧，不是旧版本或用户房间的画质A/B，不能把百分比推广到实拍。
- 自动路径移动红色物体不留下参考帧不存在的副本，结构边缘保留；高光无新增白色饱和。曝光归一、缺帧/透明/单帧回退、七画幅编码、3/6/9帧非自适应历史像素基准通过。
- 真机真实静态请求：三次自动夜景（JPG/HEIF、3/6帧，含1秒ISO3200），额外两次JPG/HEIF渐亮预览拍摄，实际保存数据回读源曝光/张数；移动停止追加、追加至6帧取消、退出后普通拍摄恢复。诊断媒体只在内存，未写系统相册。
- 渐亮显示两次成功拍摄及一次取消共16个状态发布，3个token（2完成+1取消）；工具/A-M按钮位置不变。七画幅×两个内容方向14组、42个亮度关键帧，实际渲染中心亮度依次上升，截图已检查。短动画分支未切系统“减弱动态效果”逐帧验收。

## 性能与稳定性定义

- 320×240自动融合+真实渲染12次，中位0.0982秒，P95（12次最大）0.1008秒；含CPU掩码、64像素影调探针及CI渲染，不是12MP处理时间或预览FPS。
- 三个旋转/位移样本含实际输出渲染约0.118/0.116/0.125秒。平移足够时不启动旋转搜索，所有探针仅单次照片处理，未常驻预览。
- 七画幅14配置42次UI快照绘制中位0.0449秒、最大0.0525秒；测量的是drawHierarchy工作，不是屏幕帧率。
- 真机三次自动拍摄到回调约2.81/5.29/4.57秒（开发回归同版本样本），包含硬件曝光与整条处理链，曝光/运动输入为受控注入，不冒充自然暗景触发速度。
- 最终Release成功，源码警告0，保留无AppIntents.framework依赖的工具提示，日志`/tmp/LumaCamera-NightHandheld-Release-Final.log`。未测应用内存、长时热负载或功耗，不报告推算值。

## 过程修正与限制

开发中先发现TIFF计数字段被ImageIO丢弃；缩小验证承诺并记录限制。早期模拟手抖直接裁CI交集，意外改变画布尺寸/原点，修正为完整传感器画布后通过已知位移方向断言；未用降低方向精度掩盖。真实预览测试曾重复启动完整CameraView生命周期，排队恢复路线干扰测试提交，改为同一运行相机的实际预览/固定控件测试宿主，两个真实格式及取消流程通过。设备锁屏经用户解锁后继续。上述失败均保留原日志，最终完整27项重跑通过。

未在用户原房间、原照度、实际自然手持动作下重新拍摄成对样本；没有宣称已经达到系统相机Night mode画质。大幅移动、复杂三维视差和单帧自身运动模糊仍可能损失细节；本次提高容错，不要求用户使用三脚架，也不承诺任意移动均能重建。

依据：[Vision单应配准](https://developer.apple.com/documentation/vision/vnhomographicimageregistrationrequest)、[warpTransform](https://developer.apple.com/documentation/vision/vnimagehomographicalignmentobservation)、本机SDK `Vision.framework/Headers/VNImageRegistrationRequest.h` 对floating/reference的明确说明；[CINoiseReduction](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/noisereduction())说明阈值内局部降噪/边缘锐化；[ImageIO源曝光字段](https://developer.apple.com/documentation/imageio/kcgimagepropertyexifsourceexposuretimesofcompositeimage)与[CIPA合成EXIF说明](https://www.cipa.jp/std/documents/e/DC-X008-Translation-2019-E.pdf)。阈值与渐亮曲线为应用策略，不是Apple平台保证。
