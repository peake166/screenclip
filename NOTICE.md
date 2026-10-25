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

## Maccy

- 上游项目：[p0deje/Maccy](https://github.com/p0deje/Maccy)
- 固定版本：[54fb9f00b828a4ec367e706c0e276df90febe76a](https://github.com/p0deje/Maccy/tree/54fb9f00b828a4ec367e706c0e276df90febe76a)
- 上游版权：Copyright (c) 2025 Alex Rodionov
- 许可：[MIT 原始全文](Resources/ThirdPartyLicenses/Maccy-LICENSE.txt)

Sources/ClipboardCapture.swift 的剪贴板类型过滤、敏感标记检查和格式取回逻辑适配自 Maccy/Clipboard.swift 与 Maccy/Extensions/NSPasteboard.PasteboardType+Types.swift。变更计数轮询沿用 Maccy 的处理方式。本项目增加单条大小限制、完整多条目边界、PNG 优先和本应用的复制标记；历史存储、界面和设置与截图助手独立整合。Sources/ClipboardPaste.swift 的原生粘贴事件和快捷键修饰键处理参考 Maccy/Clipboard.swift（其注释归功于 Clipy/Flycut），非激活浮窗方式参考 Maccy/FloatingPanel.swift；本项目增加有界焦点检查、窗口变更保护、取消和手动粘贴回退。未引入 Maccy 的第三方运行依赖或日志通知功能。
