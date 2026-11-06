# 照片拍摄参数与镜头诊断

`PhotoCaptureParameters` 保存数值和稳定标识，供后续边框读取，不依赖详情页已经格式化的文字。`CapturedPhoto.diagnostics.parameters` 传递本次记录；当前照片通过 `PhotoLibraryViewModel.captureParameters` 读取；已保存照片通过 `PhotoDetails.captureParameters` 读取本机拍摄记录。

记录范围：快门事件时间、A/M、显示倍率、快门时系统主镜头及名称、相机与镜头 EXIF 型号、ISO、快门秒数、光圈、实际焦距、35mm 等效焦距、成片曝光补偿、设置 EV、设备采样 ISO/快门、白平衡温度与色偏、白平衡模式、对焦位置、闪光灯设置与实际闪光标记、所选格式与像素、画面比例、滤镜标识与名称、强度、影调和边框状态。原始参数在编辑后保留，输出尺寸则从当前文件重新读取。

`iso`、`exposureSeconds`、`aperture`、`focalLengthMM` 等优先读取原始拍摄输出的 EXIF，缺失保持 nil。设备状态另存为 `sampledISO`、`sampledExposureSeconds`；不能当作最终 EXIF 测量值。RAW+JPG 双回调优先采用处理后照片 EXIF，RAW 只补缺失项。界面倍率与镜头物理焦距分别保存，二者不能混为同一值。

`PhotoCaptureDiagnosticsStore` 在应用 Application Support/CaptureDiagnostics 下按 PhotoKit 资源 ID 原子保存 JSON。照片写入系统相册成功后才关联保存；进程重启后可恢复，照片编辑不覆盖原拍摄记录。此记录属于本机 App 数据，不会随分享原图自动转移，卸载 App 也会移除；旧照片及其他来源照片只能读取文件已有 EXIF，不追溯生成不存在的拍摄状态。

诊断界面同时显示快门时系统主镜头、镜头内倍率、原生分辨率倍率与能力匹配，以及系统原始输出尺寸。能力匹配不能证明最终照片采样流程，系统虚拟相机可能融合多个镜头。不得将倍率按钮、成片像素数或此能力标记单独作为原生画质结论。模拟器演示不填造真实镜头信息。

后续边框功能应优先读取结构化数值，按边框模板独立格式化；缺失项隐藏或显示未知。加入边框只改变导出的图像，保留原始拍摄参数以支持再次编辑。
