# 2026-10-27 高动态逆光暗部修正与DNG相册回路

## 问题与修正

用户提供3张光屿HEIC、2张CineStill HEIC及1张JPEG参考。实际ImageIO元数据确认光屿三张均为原片滤镜、高动态开启，其中1张8-bit sRGB、2张10-bit PQ。缩至768×768、以extendedLinearSRGB读回的亮度中位数分别约0.00638/0.00370/0.02699，参考图约0.07288–0.10421。不同文件并非同一曝光/画幅，不能据此计算传感器动态范围或直接认定同RAW差异。第一次沙盒内GPU解码返回全零，已丢弃该结果，改用正常权限实际渲染。

主因验证：旧版把CIRAWFilter.localToneMapAmount固定为0.35，削弱底片系统映射；自定义暗部最多0.8EV、深暗部门控不提升。现改为保留每张底片的系统默认局部映射，不固定成1；对有较大亮区的高反差画面，以线性亮度0.14为目标、最高3EV提升。p90>0.18、白点>0.3及对比度共同门控，避免只有小灯的近黑场景被整体提灰。Metal改为0到0.45锚点严格单调的有理曲线，保留黑位及RGB比例；原HDR/SDR高光肩部和HDR滤镜余量保护继续使用。不增加多帧、不改变硬件曝光；捕获和RAW重新显影共用修正。普通照片和视频未接入此路径。

依据：[苹果localToneMapAmount说明](https://developer.apple.com/documentation/coreimage/cirawfilter/localtonemapamount)明确默认值随图像变化，0–1调整色调曲线；具体0.14/3EV门限是项目策略，不是苹果推荐常量。[alternatePhoto文档](https://developer.apple.com/documentation/photos/phassetresourcetype/alternatephoto)说明同一资产可有独立RAW资源。

## 真机与性能稳定性

iPhone 17 Pro，iOS27.2（24B119），正常签名。定向检查，不做全量测试。

- 线性图检查：黑位、深暗部>2倍提升、12级亮度次序、近黑场景不抬灰、HDR>1及代表滤镜保留高光层次通过。288万像素统计+GPU实际渲染6次：5.63–7.48ms；非显示FPS。
- 捕获/重新显影组通过：后置A/M、前置、SDR/HDR，5张临时照片；M挡真实快门1/120，输出信息检查通过。12次RAW小图预览19.23–26.01ms；30次快速修改、16-bit HDR编辑预览及退出取消无迟到发布通过。SDR同配方缩图RMSE=0，HDR约0.001774。不是长期热稳/功耗测试。
- 固定逆光场景最后1张：预览亮度中位数0.15547，同RAW旧0.35基础0.03345、系统默认基础0.09344，新曲线0.14000，实际HEIF0.13892；预览与HEIF中位数约0.162挡差异。旧基础不是完整旧成片，不能把上述比值称为算法提升的动态挡数。实际捕获约1.727秒，含硬件、解码和编码，仅单次。最终临时图已目视确认椅背、桌下和叶片暗部改善，窗外仍有层次。
- 一轮手机移动、场景离开窗边的结果不计入逆光预览一致性验收；已保留原记录。用户重新固定后补测通过。
- 以上3个不同方法通过；之后用户明确授权的PhotoKit写入回路另1方法通过。按用户附件文件名、拍摄时间查旧资产的2个诊断方法跳过，用户随后确认旧照片已删除，不能记为DNG丢失或通过。

## 真实DNG保存与二次编辑

用户明确要求“真机拍一张验证”，本轮作为禁止诊断照片写相册的单次授权例外。测试由临时xctestrun环境变量启用；常规测试默认跳过该写入方法。

实际拍摄1张高动态HEIF Pro，调用正式SystemPhotoLibraryService.saveCapture保存。PhotoKit资源实读为photo/public.heic和alternatePhoto/com.adobe.raw-image；从正式openEditor读回DNG，16,053,763字节与拍摄原数据逐字节一致。修改RAW曝光+0.5、色温10并开启HDR，覆盖保存后重新openEditor，配方恢复、DNG仍逐字节不变；正式详情返回“RAW底片：已附带，可重新显影”。13.190秒完成整条测试，最后仅删除本轮新建资产，确认已不在活动相册。没有恢复或删除用户原照片。

因此本机“保存→读回DNG→重新显影→覆盖→再打开”现已验收。没有验证另存副本、iCloud跨设备/下载或其他iOS版本；原报告中这些范围的未验收仍保留。单张详情分享代码会同时提供HEIF和RAW文件，列表批量分享目前只导出主要成片；本轮未操作系统分享面板保存至文件App。

## 证据

/private/tmp/LumaCamera-BacklitRAW-Check.xcresult、BacklitRAW-Capture、BacklitRAW-Final、BacklitRAW-FixedScene、BacklitRAW-ArchiveAudit及RAWArchive-RoundTrip同前缀结果包/日志。最终对照图在BacklitRAW-FixedScene-Images。机器记录见同名results.json。旧照片已删除，本轮未从附件HEIC逆向伪造DNG。

正常Debug版构建通过，按项目签名安装至iPhone，安装序列2448；测试写入授权的临时xctestrun配置已移除，常规测试不会启用相册写入方法。
