# 第三方代码声明

ScreenClip 自有代码使用根目录 [MIT License](LICENSE)。以下改编代码保留上游的独立许可；根目录许可不替代第三方的版权和许可条件。

## Snapzy

- 上游项目：[andynvt/snapzy](https://github.com/andynvt/snapzy)
- 固定版本：[`dec0e794503c3595ee2fe3462aafe5effa70f966`](https://github.com/andynvt/snapzy/tree/dec0e794503c3595ee2fe3462aafe5effa70f966)
- 上游版权：Copyright (c) 2026, Trong Duong Duc
- 许可：[BSD-3-Clause 原始全文](Resources/ThirdPartyLicenses/Snapzy-LICENSE.txt)

| 本项目文件 | 上游文件 |
| --- | --- |
| `Sources/SnapzyScrollingCaptureStitcher.swift` | `Snapzy/Services/Capture/ScrollingCapture/ScrollingCaptureStitcher.swift` |
| `Sources/ScopedScrollFrameSource.swift` | `Snapzy/Services/Capture/ScrollingCapture/ScrollingCaptureFrameSource.swift` |

本地调整包括导出时保留首尾边距、按完整输出限制长图尺寸、仅保留切片有效像素行，以及适配采集会话的配置、取消和帧发布。匹配搜索和评分主要沿用上游实现。详细来源与改动记录见 [Snapzy-SOURCE.txt](Resources/ThirdPartyLicenses/Snapzy-SOURCE.txt)。

构建脚本会将 `Resources/ThirdPartyLicenses/` 复制到应用资源中。分发源码或应用时应继续保留上述声明和许可全文。
