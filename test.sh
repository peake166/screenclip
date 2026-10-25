#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p .build
xcrun swiftc -O -swift-version 5 -framework AppKit Sources/Appearance.swift Sources/Clipboard*.swift Tests/ClipboardHistoryWindowTests.swift -o .build/clipboard-window-tests
.build/clipboard-window-tests
xcrun swiftc -O -swift-version 5 -framework AppKit Sources/Appearance.swift Sources/Clipboard*.swift Tests/ClipboardPickerInteractionTests.swift -o .build/clipboard-picker-interaction-tests
.build/clipboard-picker-interaction-tests
xcrun swiftc -O -swift-version 5 -framework AppKit Sources/Appearance.swift Sources/Clipboard*.swift Tests/ClipboardPreviewCacheTests.swift -o .build/clipboard-preview-cache-tests
.build/clipboard-preview-cache-tests
.build/clipboard-preview-cache-tests --real-idle
xcrun swiftc -O -swift-version 5 -framework AppKit -framework Carbon -framework ServiceManagement Sources/Shortcuts.swift Sources/ShortcutRecorder.swift Sources/LoginItem.swift Sources/Appearance.swift Sources/MainWindow.swift Tests/WindowAppearanceTests.swift -o .build/window-appearance-tests
.build/window-appearance-tests
xcrun swiftc -O -framework AppKit Sources/ClipboardCapture.swift Tests/ClipboardCaptureTests.swift -o .build/clipboard-capture-tests
.build/clipboard-capture-tests
xcrun swiftc -O -framework AppKit Sources/ClipboardCapture.swift Sources/ClipboardHistoryEncryption.swift Sources/ClipboardHistoryStore.swift Tests/ClipboardHistoryStoreTests.swift -o .build/clipboard-store-tests
.build/clipboard-store-tests
xcrun swiftc -O -framework AppKit Sources/ClipboardCapture.swift Sources/ClipboardHistoryEncryption.swift Sources/ClipboardHistoryStore.swift Sources/ClipboardHistory.swift Tests/ClipboardHistoryTests.swift -o .build/clipboard-history-tests
.build/clipboard-history-tests
xcrun swiftc -O -swift-version 5 -framework AppKit -framework Security Sources/ClipboardCapture.swift Sources/ClipboardHistoryEncryption.swift Sources/ClipboardHistoryStore.swift Tests/ClipboardUpgradeTests.swift -o .build/clipboard-upgrade-tests
.build/clipboard-upgrade-tests
xcrun swiftc -O -swift-version 5 -framework AppKit -framework Security Sources/ClipboardCapture.swift Sources/ClipboardHistoryEncryption.swift Sources/ClipboardHistoryStore.swift Tests/ClipboardEncryptionTests.swift -o .build/clipboard-encryption-tests
.build/clipboard-encryption-tests
xcrun swiftc -O -swift-version 5 -framework AppKit -framework Carbon Sources/ClipboardPaste.swift Tests/ClipboardPasteTests.swift -o .build/clipboard-paste-tests
.build/clipboard-paste-tests
xcrun swiftc -O -framework AppKit -framework Carbon Sources/Shortcuts.swift Tests/ClipboardShortcutTests.swift -o .build/clipboard-shortcut-tests
.build/clipboard-shortcut-tests
capture_sources=(Sources/CaptureFrameBuffer.swift Sources/CaptureWindowSelection.swift Sources/LiveCaptureStream.swift Sources/ScopedScrollFrameSource.swift Sources/ScrollCaptureDiagnostics.swift)
xcrun swiftc -O -framework AppKit -framework Carbon -framework ServiceManagement Sources/LoginItem.swift Tests/LoginItemTests.swift -o .build/login-item-tests
.build/login-item-tests
xcrun swiftc -O -framework AppKit -framework Carbon -framework ServiceManagement Sources/Shortcuts.swift Sources/ShortcutRecorder.swift Sources/LoginItem.swift Sources/Appearance.swift Sources/MainWindow.swift Tests/LoginItemWindowTests.swift -o .build/login-item-window-tests
.build/login-item-window-tests
xcrun swiftc -O Sources/CaptureFrameBuffer.swift Tests/CaptureFrameBufferTests.swift -o .build/capture-frame-tests
.build/capture-frame-tests
xcrun swiftc -O -framework AppKit -framework ScreenCaptureKit -framework CoreImage -framework CoreMedia Sources/Stitcher.swift Sources/Raster.swift Sources/CaptureFrameBuffer.swift Sources/LiveCaptureStream.swift Tests/CaptureSampleDecoderTests.swift -o .build/capture-decoder-tests
.build/capture-decoder-tests
xcrun swiftc -O Sources/CaptureWindowSelection.swift Tests/CaptureWindowSelectionTests.swift -o .build/capture-window-tests
.build/capture-window-tests
xcrun swiftc -O -framework AppKit Sources/Stitcher.swift Sources/Raster.swift Sources/ScrollCaptureDiagnostics.swift Tests/ScrollCaptureDiagnosticsTests.swift -o .build/scroll-diagnostic-tests
.build/scroll-diagnostic-tests
xcrun swiftc -O -framework AppKit Sources/Stitcher.swift Sources/Raster.swift Tests/ImageClipboardTests.swift -o .build/image-clipboard-tests
.build/image-clipboard-tests
xcrun swiftc -O Sources/Stitcher.swift Sources/ScrollSessionState.swift Tests/ScrollSessionStateTests.swift -o .build/scroll-session-state-tests
.build/scroll-session-state-tests
xcrun swiftc -O -framework AppKit -framework Vision Sources/Stitcher.swift Sources/Raster.swift Sources/SnapzyScrollingCaptureStitcher.swift Sources/OpenSourceScrollStitcher.swift Tests/OpenSourceScrollStitcherTests.swift -o .build/open-source-scroll-tests
.build/open-source-scroll-tests
xcrun swiftc -O -framework AppKit -framework Carbon -framework ServiceManagement Sources/Shortcuts.swift Sources/HotKeys.swift Sources/ShortcutRecorder.swift Sources/LoginItem.swift Sources/Appearance.swift Sources/MainWindow.swift Tests/ShortcutTests.swift -o .build/shortcut-tests
.build/shortcut-tests
xcrun swiftc -O -framework AppKit -framework Carbon Sources/Shortcuts.swift Sources/HotKeys.swift Tests/NativeHotKeyTests.swift -o .build/native-hotkey-tests
.build/native-hotkey-tests
selection_sources=(Sources/*.swift)
selection_sources=(${selection_sources:#Sources/main.swift})
xcrun swiftc -O -swift-version 5 -framework AppKit -framework ScreenCaptureKit -framework Carbon -framework SwiftUI -framework Translation -framework Vision -framework NaturalLanguage -framework Security -framework ServiceManagement ${selection_sources[@]} Tests/SelectionCancelTests.swift -o .build/selection-cancel-tests
.build/selection-cancel-tests
xcrun swiftc -O -framework AppKit -framework Carbon -framework ServiceManagement Sources/Shortcuts.swift Sources/ShortcutRecorder.swift Sources/LoginItem.swift Sources/Appearance.swift Sources/MainWindow.swift Tests/Preview.swift -o .build/ui-preview
.build/ui-preview
xcrun swiftc -O Sources/TranslationModel.swift Tests/TranslationModelTests.swift -o .build/translation-model-tests
.build/translation-model-tests
xcrun swiftc -O Sources/TranslationModel.swift Tests/FreeTranslationModelTests.swift -o .build/free-translation-model-tests
.build/free-translation-model-tests
xcrun swiftc -O -framework AppKit Sources/Stitcher.swift Sources/Raster.swift Sources/TranslationModel.swift Sources/TranslationLayout.swift Sources/TranslationWorkflow.swift Tests/TranslationWorkflowTests.swift -o .build/translation-workflow-tests
.build/translation-workflow-tests
xcrun swiftc -O -framework NaturalLanguage Sources/TranslationModel.swift Sources/SystemTranslationLanguage.swift Tests/SystemTranslationLanguageTests.swift -o .build/system-language-tests
.build/system-language-tests
xcrun swiftc -O -framework Vision Sources/Stitcher.swift Sources/Raster.swift Sources/TranslationModel.swift Sources/TranslationLayout.swift Sources/TextRecognizer.swift Tests/OCRCancellationTests.swift -o .build/ocr-cancellation-tests
.build/ocr-cancellation-tests
xcrun swiftc -O -framework AppKit -framework Vision Sources/Stitcher.swift Sources/Raster.swift Sources/TranslationModel.swift Sources/TranslationLayout.swift Sources/TextRecognizer.swift Tests/OCRTests.swift -o .build/ocr-tests
.build/ocr-tests
xcrun swiftc -O Sources/TranslationModel.swift Sources/CloudTranslation.swift Tests/CloudTranslationTests.swift -o .build/cloud-translation-tests
.build/cloud-translation-tests
xcrun swiftc -O -swift-version 5 Sources/TranslationModel.swift Sources/CloudTranslation.swift Sources/TranslationBenchmark.swift Tests/TranslationBenchmarkTests.swift -o .build/translation-benchmark-tests
.build/translation-benchmark-tests
xcrun swiftc -O -swift-version 5 Sources/TranslationModel.swift Sources/CloudTranslation.swift Sources/TranslationBenchmark.swift Tests/TranslationBenchmarkTransportTests.swift -o .build/translation-benchmark-transport-tests
.build/translation-benchmark-transport-tests
xcrun swiftc -O Sources/TranslationLayout.swift Tests/TranslationLayoutTests.swift -o .build/layout-tests
.build/layout-tests
xcrun swiftc -O Sources/TranslationBatchMapping.swift Tests/TranslationBatchMappingTests.swift -o .build/batch-mapping-tests
.build/batch-mapping-tests
xcrun swiftc -O -framework AppKit Sources/Stitcher.swift Sources/Raster.swift Sources/TranslationModel.swift Sources/TranslationLayout.swift Sources/TranslationWorkflow.swift Tests/InPlaceWorkflowTests.swift -o .build/inplace-workflow-tests
.build/inplace-workflow-tests
xcrun swiftc -O -framework AppKit Sources/Stitcher.swift Sources/Raster.swift Sources/TranslationLayout.swift Sources/TranslationOverlayLayout.swift Tests/TranslationOverlayLayoutTests.swift -o .build/overlay-layout-tests
.build/overlay-layout-tests
preview_sources=(Sources/*.swift)
preview_sources=("${(@)preview_sources:#Sources/main.swift}")
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -framework AppKit -framework ScreenCaptureKit -framework Carbon -framework SwiftUI -framework Translation -framework Vision -framework NaturalLanguage -framework Security -framework ServiceManagement \
  "${preview_sources[@]}" Tests/TranslationPreview.swift -o .build/translation-preview
.build/translation-preview
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -framework AppKit -framework ScreenCaptureKit -framework Carbon -framework SwiftUI -framework Translation -framework Vision -framework NaturalLanguage -framework Security -framework ServiceManagement \
  "${preview_sources[@]}" Tests/TranslationSettingsTests.swift -o .build/translation-settings-tests
.build/translation-settings-tests
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -framework AppKit -framework ScreenCaptureKit -framework Carbon -framework SwiftUI -framework Translation -framework Vision -framework NaturalLanguage -framework Security -framework ServiceManagement \
  "${preview_sources[@]}" Tests/TranslationBenchmarkWindowTests.swift -o .build/translation-benchmark-window-tests
.build/translation-benchmark-window-tests
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -framework AppKit -framework ScreenCaptureKit -framework Carbon -framework SwiftUI -framework Translation -framework Vision -framework NaturalLanguage -framework Security -framework ServiceManagement \
  "${preview_sources[@]}" Tests/InPlaceOverlayTests.swift -o .build/inplace-overlay-tests
.build/inplace-overlay-tests
