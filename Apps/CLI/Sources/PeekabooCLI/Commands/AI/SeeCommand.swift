import Algorithms
import AppKit
import AXorcist
import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import ScreenCaptureKit

enum ScreenCaptureBridge {
    static func captureFrontmost(services: any PeekabooServiceProviding) async throws -> CaptureResult {
        try await Task { @MainActor in
            try await services.screenCapture.captureFrontmost()
        }.value
    }

    static func captureWindow(
        services: any PeekabooServiceProviding,
        appIdentifier: String,
        windowIndex: Int?
    ) async throws -> CaptureResult {
        try await Task { @MainActor in
            try await services.screenCapture.captureWindow(appIdentifier: appIdentifier, windowIndex: windowIndex)
        }.value
    }

    static func captureWindowById(
        services: any PeekabooServiceProviding,
        windowId: Int
    ) async throws -> CaptureResult {
        try await Task { @MainActor in
            try await services.screenCapture.captureWindow(windowID: CGWindowID(windowId))
        }.value
    }

    static func captureArea(services: any PeekabooServiceProviding, rect: CGRect) async throws -> CaptureResult {
        try await Task { @MainActor in
            try await services.screenCapture.captureArea(rect)
        }.value
    }

    static func captureScreen(
        services: any PeekabooServiceProviding,
        displayIndex: Int?
    ) async throws -> CaptureResult {
        try await Task { @MainActor in
            try await services.screenCapture.captureScreen(displayIndex: displayIndex)
        }.value
    }
}

/// Capture a screenshot and build an interactive UI map
@available(macOS 14.0, *)
struct SeeCommand: ApplicationResolvable, ErrorHandlingCommand, RuntimeOptionsConfigurable {
    @Option(help: "Application name to capture, or special values: 'menubar', 'frontmost'")
    var app: String?

    @Option(name: .long, help: "Target application by process ID")
    var pid: Int32?

    @Option(help: "Specific window title to capture")
    var windowTitle: String?

    @Option(
        name: .long,
        help: "Target window by CoreGraphics window id (window_id from `peekaboo window list --json`)"
    )
    var windowId: Int?

    @Option(help: "Capture mode (screen, window, frontmost)")
    var mode: PeekabooCore.CaptureMode?

    @Option(
        names: [.automatic, .customLong("save"), .customLong("output"), .customShort("o", allowingJoined: false)],
        help: "Output path for screenshot (aliases: --save, --output, -o)"
    )
    var path: String?

    @Option(
        name: .long,
        help: "Specific screen index to capture (0-based). If not specified, captures all screens when in screen mode"
    )
    var screenIndex: Int?

    @Flag(help: "Generate annotated screenshot with interaction markers")
    var annotate = false

    @Flag(name: .long, help: "Capture menu bar popovers via window list + OCR")
    var menubar = false

    @Option(help: "Analyze captured content with AI")
    var analyze: String?

    @Option(
        name: .long,
        help: """
        Overall timeout in seconds (default: 20, or 60 when --analyze is set).
        Increase this if element detection regularly times out for large/complex windows.
        """
    )
    var timeoutSeconds: Int?

    @Option(
        name: .long,
        help: """
        Capture engine: auto|modern|sckit|classic|cg (default: auto).
        modern/sckit force ScreenCaptureKit; classic/cg force CGWindowList;
        auto tries SC then falls back when allowed.
        """
    )
    var captureEngine: String?

    @Flag(help: "Skip web-content focus fallback when no text fields are detected")
    var noWebFocus = false

    @Flag(name: .long, help: "Output the full UI tree (raw snapshot.json) to stdout")
    var fullUiTree = false

    @Flag(name: .long, help: "Append an ASCII wireframe with element IDs (implies --full-ui-tree)")
    var wireframe = false
    @RuntimeStorage private var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    var jsonOutput: Bool { self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput }
    var verbose: Bool { self.runtime?.configuration.verbose ?? self.runtimeOptions.verbose }

    var logger: Logger { self.resolvedRuntime.logger }
    var services: any PeekabooServiceProviding { self.resolvedRuntime.services }
    var outputLogger: Logger { self.logger }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        let startTime = Date()
        let logger = self.logger
        let overallTimeout = TimeInterval(self.timeoutSeconds ?? ((self.analyze == nil) ? 20 : 60))

        logger.operationStart("see_command", metadata: [
            "app": self.app ?? "none",
            "mode": self.mode?.rawValue ?? "auto",
            "annotate": self.annotate,
            "menubar": self.menubar,
            "hasAnalyzePrompt": self.analyze != nil,
        ])

        let commandCopy = self

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await commandCopy.runImpl(startTime: startTime, logger: logger)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(overallTimeout * 1_000_000_000))
                    throw CaptureError.detectionTimedOut(overallTimeout)
                }

                do {
                    _ = try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            logger.operationComplete(
                "see_command",
                success: false,
                metadata: [
                    "error": error.localizedDescription,
                ]
            )
            throw error
        }
    }

    private func runImpl(startTime: Date, logger: Logger) async throws {
        do {
            // Check permissions
            logger.verbose("Checking screen recording permissions", category: "Permissions")
            try await requireScreenRecordingPermission(services: self.services)
            logger.verbose("Screen recording permission granted", category: "Permissions")

            // Perform capture and element detection
            logger.verbose("Starting capture and detection phase", category: "Capture")
            let captureResult = try await performCaptureWithDetection()
            logger.verbose("Capture completed successfully", category: "Capture", metadata: [
                "snapshotId": captureResult.snapshotId,
                "elementCount": captureResult.elements.all.count,
                "screenshotSize": self.getFileSize(captureResult.screenshotPath) ?? 0,
            ])

            // Generate annotated screenshot if requested
            var annotatedPath: String?
            if self.annotate {
                logger.operationStart("generate_annotations")
                annotatedPath = try await self.generateAnnotatedScreenshot(
                    snapshotId: captureResult.snapshotId,
                    originalPath: captureResult.screenshotPath
                )
                if let annotatedPath,
                   annotatedPath != captureResult.screenshotPath {
                    try await self.services.snapshots.storeAnnotatedScreenshot(
                        snapshotId: captureResult.snapshotId,
                        annotatedScreenshotPath: annotatedPath
                    )
                }
                logger.operationComplete("generate_annotations", metadata: [
                    "annotatedPath": annotatedPath ?? "none",
                ])
            }

            // Perform AI analysis if requested
            var analysisResult: SeeAnalysisData?
            if let prompt = analyze {
                // Pre-analysis diagnostics
                let fileSize = (try? FileManager.default
                    .attributesOfItem(atPath: captureResult.screenshotPath)[.size] as? Int) ?? 0
                logger.verbose(
                    "Starting AI analysis",
                    category: "AI",
                    metadata: [
                        "imagePath": captureResult.screenshotPath,
                        "imageSizeBytes": fileSize,
                        "promptLength": prompt.count
                    ]
                )
                logger.operationStart("ai_analysis", metadata: ["promptPreview": String(prompt.prefix(80))])
                logger.startTimer("ai_generate")
                analysisResult = try await self.performAnalysisDetailed(
                    imagePath: captureResult.screenshotPath,
                    prompt: prompt
                )
                logger.stopTimer("ai_generate")
                logger.operationComplete(
                    "ai_analysis",
                    success: analysisResult != nil,
                    metadata: [
                        "provider": analysisResult?.provider ?? "unknown",
                        "model": analysisResult?.model ?? "unknown"
                    ]
                )
            }

            // Output results
            let executionTime = Date().timeIntervalSince(startTime)
            logger.operationComplete("see_command", metadata: [
                "executionTimeMs": Int(executionTime * 1000),
                "success": true,
            ])

            let context = SeeCommandRenderContext(
                snapshotId: captureResult.snapshotId,
                screenshotPath: captureResult.screenshotPath,
                annotatedPath: annotatedPath,
                metadata: captureResult.metadata,
                elements: captureResult.elements,
                analysis: analysisResult,
                executionTime: executionTime
            )
            await self.renderResults(context: context)

        } catch {
            logger.operationComplete("see_command", success: false, metadata: [
                "error": error.localizedDescription,
            ])
            self.handleError(error) // Use protocol's error handling
            throw ExitCode.failure
        }
    }

    private func getFileSize(_ path: String) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
    }

    private func renderResults(context: SeeCommandRenderContext) async {
        if self.fullUiTree || self.wireframe {
            self.outputFullUITree(context: context, includeWireframe: self.wireframe)
        } else if self.jsonOutput {
            await self.outputJSONResults(context: context)
        } else {
            await self.outputTextResults(context: context)
        }
    }

    private func performCaptureWithDetection() async throws -> CaptureAndDetectionResult {
        let captureContext = try await self.resolveCaptureContext()
        let captureResult = captureContext.captureResult

        // Save screenshot
        self.logger.startTimer("file_write")
        let outputPath = try saveScreenshot(captureResult.imageData)
        self.logger.stopTimer("file_write")

        // Create window context from capture metadata
        let windowContext = WindowContext(
            applicationName: captureResult.metadata.applicationInfo?.name,
            applicationBundleId: captureResult.metadata.applicationInfo?.bundleIdentifier,
            applicationProcessId: captureResult.metadata.applicationInfo?.processIdentifier,
            windowTitle: captureResult.metadata.windowInfo?.title,
            windowID: captureContext.windowIdOverride ?? captureResult.metadata.windowInfo?.windowID,
            windowBounds: captureContext.captureBounds ?? captureResult.metadata.windowInfo?.bounds,
            shouldFocusWebContent: self.noWebFocus ? false : true
        )

        let detectionStart = Date()
        let detectionResult: ElementDetectionResult
        if captureContext.prefersOCR {
            self.logger.verbose("Running OCR for menu bar popover", category: "Capture")
            let ocrElements = try self.ocrElements(
                imageData: captureResult.imageData,
                windowBounds: captureContext.captureBounds ?? captureResult.metadata.windowInfo?.bounds
            )

            let warnings = ocrElements.isEmpty ? ["OCR produced no elements"] : []
            let metadata = DetectionMetadata(
                detectionTime: Date().timeIntervalSince(detectionStart),
                elementCount: ocrElements.count,
                method: captureContext.ocrMethod ?? "OCR",
                warnings: warnings,
                windowContext: windowContext,
                isDialog: false
            )
            detectionResult = ElementDetectionResult(
                snapshotId: UUID().uuidString,
                screenshotPath: "",
                elements: DetectedElements(other: ocrElements),
                metadata: metadata
            )
        } else {
            detectionResult = try await self.detectElements(
                imageData: captureResult.imageData,
                windowContext: windowContext
            )
        }

        // Update the result with the correct screenshot path
        let resultWithPath = ElementDetectionResult(
            snapshotId: detectionResult.snapshotId,
            screenshotPath: outputPath,
            elements: detectionResult.elements,
            metadata: detectionResult.metadata
        )

        try await self.services.snapshots.storeScreenshot(
            snapshotId: detectionResult.snapshotId,
            screenshotPath: outputPath,
            applicationBundleId: captureResult.metadata.applicationInfo?.bundleIdentifier,
            applicationProcessId: captureResult.metadata.applicationInfo.map { Int32($0.processIdentifier) },
            applicationName: windowContext.applicationName,
            windowTitle: windowContext.windowTitle,
            windowBounds: windowContext.windowBounds
        )

        // Store the result in snapshot
        try await self.services.snapshots.storeDetectionResult(
            snapshotId: detectionResult.snapshotId,
            result: resultWithPath
        )

        return CaptureAndDetectionResult(
            snapshotId: detectionResult.snapshotId,
            screenshotPath: outputPath,
            elements: detectionResult.elements,
            metadata: detectionResult.metadata
        )
    }
}

// MARK: - Supporting Types

struct CaptureContext {
    let captureResult: CaptureResult
    let captureBounds: CGRect?
    let prefersOCR: Bool
    let ocrMethod: String?
    let windowIdOverride: Int?
}

struct MenuBarPopoverCapture {
    let captureResult: CaptureResult
    let windowBounds: CGRect
    let windowId: Int?
}

struct CaptureAndDetectionResult {
    let snapshotId: String
    let screenshotPath: String
    let elements: DetectedElements
    let metadata: DetectionMetadata
}

struct SnapshotPaths {
    let raw: String
    let annotated: String
    let map: String
}

struct SeeCommandRenderContext {
    let snapshotId: String
    let screenshotPath: String
    let annotatedPath: String?
    let metadata: DetectionMetadata
    let elements: DetectedElements
    let analysis: SeeAnalysisData?
    let executionTime: TimeInterval
}

// MARK: - JSON Output Structure (matching original)

struct UIElementSummary: Codable {
    let id: String
    let role: String
    let title: String?
    let label: String?
    let description: String?
    let role_description: String?
    let help: String?
    let identifier: String?
    let is_actionable: Bool
    let keyboard_shortcut: String?
}

struct SeeAnalysisData: Codable {
    let provider: String
    let model: String
    let text: String
}

struct SeeResult: Codable {
    let snapshot_id: String
    let screenshot_raw: String
    let screenshot_annotated: String
    let ui_map: String
    let application_name: String?
    let window_title: String?
    let is_dialog: Bool
    let element_count: Int
    let interactable_count: Int
    let capture_mode: String
    let analysis: SeeAnalysisData?
    let execution_time: TimeInterval
    let ui_elements: [UIElementSummary]
    let menu_bar: MenuBarSummary?
    var success: Bool = true
}

struct MenuBarSummary: Codable {
    let menus: [MenuSummary]

    struct MenuSummary: Codable {
        let title: String
        let item_count: Int
        let enabled: Bool
        let items: [MenuItemSummary]
    }

    struct MenuItemSummary: Codable {
        let title: String
        let enabled: Bool
        let keyboard_shortcut: String?
    }
}

// MARK: - Format Helpers Extension

extension SeeCommand {
    /// Fetches the menu bar summary only when verbose output is requested, with a short timeout.
    private func fetchMenuBarSummaryIfEnabled() async -> MenuBarSummary? {
        guard self.verbose else { return nil }

        do {
            return try await Self.withWallClockTimeout(seconds: 2.5) {
                try Task.checkCancellation()
                return await self.getMenuBarItemsSummary()
            }
        } catch {
            self.logger.debug(
                "Skipping menu bar summary",
                category: "Menu",
                metadata: ["reason": error.localizedDescription]
            )
            return nil
        }
    }

    /// Timeout helper that is not MainActor-bound, so it can still fire if the main actor is blocked.
    static func withWallClockTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CaptureError.detectionTimedOut(seconds)
            }

            guard let result = try await group.next() else {
                throw CaptureError.detectionTimedOut(seconds)
            }
            group.cancelAll()
            return result
        }
    }

    private func performAnalysisDetailed(imagePath: String, prompt: String) async throws -> SeeAnalysisData {
        // Use PeekabooCore AI service which is configured via ConfigurationManager/Tachikoma
        let ai = PeekabooAIService()
        let res = try await ai.analyzeImageFileDetailed(at: imagePath, question: prompt, model: nil)
        return SeeAnalysisData(provider: res.provider, model: res.model, text: res.text)
    }

    private func buildMenuSummaryIfNeeded() async -> MenuBarSummary? {
        // Placeholder for future UI summary generation; currently unused.
        nil
    }

    func determineMode() -> PeekabooCore.CaptureMode {
        if let mode = self.mode {
            mode
        } else if self.app != nil || self.pid != nil || self.windowTitle != nil || self.windowId != nil {
            // If app or window title is specified, default to window mode
            .window
        } else {
            // Otherwise default to frontmost
            .frontmost
        }
    }

    // MARK: - Output Methods

    private static let labelTruncationLimit = 200

    private func outputFullUITree(context: SeeCommandRenderContext, includeWireframe: Bool = false) {
        let snapshotJsonPath = self.services.snapshots.getSnapshotStoragePath()
            + "/\(context.snapshotId)/snapshot.json"
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: snapshotJsonPath))
            let optimized = Self.optimizeForAgent(from: data)
            if let jsonString = String(data: optimized, encoding: .utf8) {
                print(jsonString)
                if includeWireframe {
                    print("\n---WIREFRAME---")
                    print(Self.renderWireframe(from: optimized))
                }
            } else {
                outputError(
                    message: "Failed to decode snapshot.json",
                    code: .FILE_IO_ERROR,
                    logger: self.outputLogger
                )
            }
        } catch {
            outputError(
                message: "Failed to read snapshot.json at \(snapshotJsonPath): \(error.localizedDescription)",
                code: .FILE_IO_ERROR,
                logger: self.outputLogger
            )
        }
    }

    /// Optimize snapshot JSON for agent/LLM consumption:
    /// - Remove unused `elementId` field
    /// - Remove zero-size invisible elements (e.g. closed menu items)
    /// - Resolve `displayText` from label/description/value/help fallback chain
    /// - Remove redundant text fields (label, description, value, roleDescription) absorbed by `displayText`
    /// - Keep `help` only when it carries unique info beyond `displayText`
    /// - Convert frame from [[x,y],[w,h]] to {x,y,w,h}
    private static func optimizeForAgent(from data: Data) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uiMap = json["uiMap"] as? [String: Any]
        else {
            return data
        }

        var optimized: [String: Any] = [:]
        for (key, value) in uiMap {
            guard var element = value as? [String: Any] else { continue }

            // Remove zero-size invisible elements (e.g. AXMenuItem when menu is closed)
            if let frame = element["frame"] as? [[Any]], frame.count == 2,
               let size = frame[1] as? [NSNumber], size.count == 2,
               size[0].doubleValue == 0, size[1].doubleValue == 0
            {
                continue
            }

            // Remove unused/redundant fields
            element.removeValue(forKey: "elementId")
            element.removeValue(forKey: "title")

            // Omit isActionable when false (default); omit empty children array
            if let actionable = element["isActionable"] as? Bool, !actionable {
                element.removeValue(forKey: "isActionable")
            }
            if let children = element["children"] as? [Any], children.isEmpty {
                element.removeValue(forKey: "children")
            }

            // Convert frame [[x,y],[w,h]] → {"x":x,"y":y,"w":w,"h":h}
            if let frame = element["frame"] as? [[NSNumber]], frame.count == 2,
               frame[0].count == 2, frame[1].count == 2
            {
                element["frame"] = [
                    "x": frame[0][0], "y": frame[0][1],
                    "w": frame[1][0], "h": frame[1][1],
                ]
            }

            // Resolve displayText from fallback chain, then remove redundant fields
            Self.resolveDisplayText(&element)

            optimized[key] = element
        }

        // Update children references to only include surviving elements
        let survivingIds = Set(optimized.keys)
        for (key, value) in optimized {
            guard var element = value as? [String: Any] else { continue }
            if let children = element["children"] as? [String] {
                let filtered = children.filter { survivingIds.contains($0) }
                element["children"] = filtered
            }
            if let parentId = element["parentId"] as? String, !survivingIds.contains(parentId) {
                element.removeValue(forKey: "parentId")
            }
            optimized[key] = element
        }

        json["uiMap"] = optimized
        guard let result = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return data
        }
        return result
    }

    /// Resolve a single `displayText` from the label/description/value/help fallback chain,
    /// then remove all redundant text fields. After this call the element has at most
    /// `displayText` (the best human-readable name) and `help` (if it carries extra info).
    private static func resolveDisplayText(_ element: inout [String: Any]) {
        let label = element["label"] as? String ?? ""
        let description = element["description"] as? String ?? ""
        let value = element["value"] as? String ?? ""
        let help = element["help"] as? String ?? ""

        let labelIsGeneric = Self.isGenericLabel(label)

        // Fallback chain: semantic label → description → value → help
        var displayText: String?
        if !label.isEmpty, !labelIsGeneric {
            displayText = label
        } else if !description.isEmpty {
            displayText = description
        } else if !value.isEmpty {
            displayText = value
        } else if !help.isEmpty {
            displayText = help
        }

        // Truncate displayText if needed
        if let dt = displayText, dt.count > Self.labelTruncationLimit {
            displayText = String(dt.prefix(Self.labelTruncationLimit)) + " [truncated, \(dt.count) chars total]"
        }

        // Remove all original text fields — displayText replaces them
        element.removeValue(forKey: "label")
        element.removeValue(forKey: "description")
        element.removeValue(forKey: "value")
        element.removeValue(forKey: "roleDescription")

        // Set displayText (nil means the element has no human-readable name — structural container)
        if let dt = displayText {
            element["displayText"] = dt
        }

        // Keep help only if it carries unique info beyond displayText
        if help.isEmpty || help == displayText {
            element.removeValue(forKey: "help")
        } else {
            // Truncate help if needed
            if help.count > Self.labelTruncationLimit {
                element["help"] = String(help.prefix(Self.labelTruncationLimit))
                    + " [truncated, \(help.count) chars total]"
            }
        }
    }

    // MARK: - Wireframe Renderer

    /// A z-ordered character canvas for ASCII wireframe rendering.
    private struct WireframeCanvas {
        let width: Int
        let height: Int
        private var cells: [(ch: Character, z: Int)]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            self.cells = Array(repeating: (ch: " ", z: 0), count: width * height)
        }

        mutating func put(_ x: Int, _ y: Int, _ ch: Character, z: Int = 1) {
            guard x >= 0, x < self.width, y >= 0, y < self.height else { return }
            let idx = y * self.width + x
            if self.cells[idx].z <= z {
                self.cells[idx] = (ch, z)
            }
        }

        mutating func putText(_ x: Int, _ y: Int, _ text: String, z: Int = 1) {
            for (i, ch) in text.enumerated() {
                self.put(x + i, y, ch, z: z)
            }
        }

        mutating func drawBox(
            _ cx1: Int, _ cy1: Int, _ cx2: Int, _ cy2: Int,
            z: Int = 1, heavy: Bool = false
        ) {
            guard cx2 > cx1, cy2 > cy1 else { return }
            let tl: Character = heavy ? "┏" : "┌"
            let tr: Character = heavy ? "┓" : "┐"
            let bl: Character = heavy ? "┗" : "└"
            let br: Character = heavy ? "┛" : "┘"
            let hl: Character = heavy ? "━" : "─"
            let vl: Character = heavy ? "┃" : "│"

            for x in (cx1 + 1) ..< cx2 {
                self.put(x, cy1, hl, z: z)
                self.put(x, cy2, hl, z: z)
            }
            for y in (cy1 + 1) ..< cy2 {
                self.put(cx1, y, vl, z: z)
                self.put(cx2, y, vl, z: z)
            }
            self.put(cx1, cy1, tl, z: z)
            self.put(cx2, cy1, tr, z: z)
            self.put(cx1, cy2, bl, z: z)
            self.put(cx2, cy2, br, z: z)
        }

        func render() -> String {
            var lines: [String] = []
            for y in 0 ..< self.height {
                var line = ""
                for x in 0 ..< self.width {
                    line.append(self.cells[y * self.width + x].ch)
                }
                // Trim trailing spaces
                while line.hasSuffix(" ") { line.removeLast() }
                lines.append(line)
            }
            // Trim trailing empty lines
            while lines.last?.isEmpty == true { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
    }

    /// Labels that are generic role descriptions rather than meaningful content.
    /// When these appear as `label`, we prefer `description` instead.
    private static let genericLabels: Set<String> = [
        "按钮", "button", "Button",
        "单元格", "cell", "Cell",
        "表格行", "table row", "row",
        "组", "group", "Group",
        "图像", "image", "Image",
        "Menu Item",
        "外框行", "外框", "分离组", "滚动区", "滚动条",
        "值指示器", "菜单按钮", "单选按钮", "单选按钮组",
        "未知",
    ]

    private static func isGenericLabel(_ label: String) -> Bool {
        return self.genericLabels.contains(label)
    }

    /// Render an ASCII wireframe from optimized --full-ui-tree JSON data.
    static func renderWireframe(from data: Data, canvasWidth: Int = 120) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uiMap = json["uiMap"] as? [String: [String: Any]]
        else {
            return "(wireframe: failed to parse JSON)"
        }

        // Determine viewport from windowBounds
        let windowBounds = json["windowBounds"] as? [[NSNumber]] ?? [[0, 0], [1920, 1080]]
        let winX = windowBounds[0][0].doubleValue
        let winY = windowBounds[0][1].doubleValue
        let winW = windowBounds[1][0].doubleValue
        let winH = windowBounds[1][1].doubleValue

        // Viewport: menu bar row (y=0..30) + window area
        let viewMinX = winX
        let viewMinY: Double = 0
        let viewMaxX = winX + winW
        let viewMaxY = winY + winH
        let menuBarHeight: Double = 30

        let viewW = viewMaxX - viewMinX
        let viewH = viewMaxY - viewMinY
        guard viewW > 0, viewH > 0 else {
            return "(wireframe: invalid window bounds)"
        }

        // Scale to canvas; terminal chars ~2:1 aspect ratio
        let sx = Double(canvasWidth) / viewW
        let canvasHeight = max(20, Int(viewH * sx * 0.45))
        let sy = Double(canvasHeight) / viewH

        var canvas = WireframeCanvas(width: canvasWidth, height: canvasHeight)

        // Coordinate mapping — clamps to canvas bounds
        func toCanvas(_ px: Double, _ py: Double) -> (Int, Int) {
            let cx = Int((px - viewMinX) * sx)
            let cy = Int((py - viewMinY) * sy)
            return (max(0, min(canvasWidth - 1, cx)), max(0, min(canvasHeight - 1, cy)))
        }

        // Parse element frame from optimized {x,y,w,h} format
        func frame(_ element: [String: Any]) -> (x: Double, y: Double, w: Double, h: Double)? {
            guard let f = element["frame"] as? [String: NSNumber] else { return nil }
            guard let x = f["x"]?.doubleValue, let y = f["y"]?.doubleValue,
                  let w = f["w"]?.doubleValue, let h = f["h"]?.doubleValue
            else { return nil }
            return (x, y, w, h)
        }

        /// Clip frame to a rectangular region; returns nil if fully outside.
        func clipFrame(
            _ f: (x: Double, y: Double, w: Double, h: Double),
            minX: Double, minY: Double, maxX: Double, maxY: Double
        ) -> (x: Double, y: Double, w: Double, h: Double)? {
            let x1 = max(f.x, minX)
            let y1 = max(f.y, minY)
            let x2 = min(f.x + f.w, maxX)
            let y2 = min(f.y + f.h, maxY)
            guard x2 > x1, y2 > y1 else { return nil }
            return (x1, y1, x2 - x1, y2 - y1)
        }

        // Collect elements, clip to appropriate region, sort by area descending
        struct RenderElement {
            let id: String
            let role: String
            let label: String // best display text (label → description → value fallback)
            let frame: (x: Double, y: Double, w: Double, h: Double) // clipped
            let isActionable: Bool
            let area: Double
        }

        var elements: [RenderElement] = []
        for (eid, elem) in uiMap {
            guard let rawFrame = frame(elem) else { continue }
            let role = elem["role"] as? String ?? ""
            let clipped: (x: Double, y: Double, w: Double, h: Double)?
            if role == "AXMenu" || role == "AXMenuItem" {
                clipped = clipFrame(rawFrame, minX: viewMinX, minY: 0, maxX: viewMaxX, maxY: menuBarHeight)
            } else if role == "AXWindow" {
                clipped = rawFrame
            } else {
                clipped = clipFrame(rawFrame, minX: winX, minY: winY, maxX: winX + winW, maxY: winY + winH)
            }
            guard let finalFrame = clipped else { continue }

            // displayText is pre-computed by optimizeForAgent
            let displayLabel = elem["displayText"] as? String ?? ""

            let actionable = elem["isActionable"] as? Bool ?? false
            elements.append(RenderElement(
                id: eid, role: role, label: displayLabel,
                frame: finalFrame, isActionable: actionable,
                area: finalFrame.w * finalFrame.h
            ))
        }
        elements.sort { $0.area > $1.area }

        // ---- Draw menu bar separator ----
        let (_, menuBottom) = toCanvas(viewMinX, menuBarHeight)
        for x in 0 ..< canvasWidth {
            canvas.put(x, menuBottom, "─", z: 2)
        }

        // ---- Render each element by role ----
        for elem in elements {
            let f = elem.frame
            let (cx1, cy1) = toCanvas(f.x, f.y)
            let (cx2, cy2) = toCanvas(f.x + f.w, f.y + f.h)
            guard cx2 > cx1 || cy2 > cy1 else { continue }

            switch elem.role {
            case "AXWindow":
                canvas.drawBox(cx1, cy1, cx2, cy2, z: 10, heavy: true)
                let titleLabel = " [\(elem.id)] \(elem.label) "
                canvas.putText(cx1 + 1, cy1, String(titleLabel.prefix(cx2 - cx1 - 1)), z: 11)

            case "AXToolbar":
                if cy2 < canvasHeight {
                    for x in (cx1 + 1) ..< cx2 {
                        canvas.put(x, cy2, "─", z: 8)
                    }
                }
                let tag = " [\(elem.id)] Toolbar"
                canvas.putText(cx1 + 1, cy1 + 1, String(tag.prefix(cx2 - cx1 - 1)), z: 9)

            case "AXSplitGroup":
                // Only draw label, not a box — SplitGroup is a logical container
                break

            case "AXScrollArea":
                if cx2 - cx1 > 6, cy2 - cy1 > 2 {
                    canvas.drawBox(cx1, cy1, cx2, cy2, z: 4)
                    let tag = " [\(elem.id)] "
                    canvas.putText(cx1 + 1, cy1, String(tag.prefix(cx2 - cx1 - 1)), z: 5)
                }

            case "AXOutline", "AXList":
                if cx2 - cx1 > 6, cy2 - cy1 > 2 {
                    canvas.drawBox(cx1, cy1, cx2, cy2, z: 5)
                    let tag = " [\(elem.id)] "
                    canvas.putText(cx1 + 1, cy1, String(tag.prefix(cx2 - cx1 - 1)), z: 6)
                }

            case "AXScrollBar":
                for y in cy1 ... min(cy2, canvasHeight - 1) {
                    canvas.put(cx1, y, "▒", z: 6)
                }

            case "AXValueIndicator":
                for y in cy1 ... min(cy2, canvasHeight - 1) {
                    canvas.put(cx1, y, "█", z: 7)
                }

            case "AXMenu":
                // Menu bar items — render compactly with spacing
                let tag = " \(elem.label)[\(elem.id)]"
                let (mx, my) = toCanvas(f.x, menuBarHeight / 2)
                canvas.putText(mx, my, String(tag.prefix(20)), z: 5)

            case "AXButton":
                guard elem.isActionable else { break }
                let shortLabel = String(elem.label.prefix(6))
                let tag = shortLabel.isEmpty ? "[\(elem.id)]" : "[\(elem.id)|\(shortLabel)]"
                let (mx, my) = toCanvas(f.x, f.y + f.h / 2)
                canvas.putText(mx, my, String(tag.prefix(max(cx2 - cx1 + 4, tag.count))), z: 8)

            case "AXRadioButton":
                guard elem.isActionable else { break }
                let tag = "(\(elem.id))"
                let (mx, my) = toCanvas(f.x, f.y + f.h / 2)
                canvas.putText(mx, my, String(tag.prefix(20)), z: 8)

            case "AXStaticText":
                guard !elem.label.isEmpty else { break }
                let tag = "\(String(elem.label.prefix(14))) [\(elem.id)]"
                let (tx, ty) = toCanvas(f.x, f.y)
                canvas.putText(tx, ty, String(tag.prefix(max(cx2 - tx + 2, 10))), z: 6)

            case "AXTextArea":
                if cx2 - cx1 > 6, cy2 - cy1 > 2 {
                    canvas.drawBox(cx1, cy1, cx2, cy2, z: 4)
                    let tag = " [\(elem.id)] TextArea "
                    canvas.putText(cx1 + 1, cy1, String(tag.prefix(cx2 - cx1 - 1)), z: 5)
                }

            case "AXImage":
                let tag = "[\(elem.id)]"
                let (ix, iy) = toCanvas(f.x, f.y)
                if cx2 - cx1 >= tag.count {
                    canvas.putText(ix, iy, tag, z: 6)
                }

            case "AXMenuButton":
                let tag = "[\(elem.id)|v]"
                let (mx, my) = toCanvas(f.x, f.y + f.h / 2)
                canvas.putText(mx, my, String(tag.prefix(20)), z: 8)

            case "AXSlider":
                let (slx, sly) = toCanvas(f.x, f.y + f.h / 2)
                let tag = "[\(elem.id)|===]"
                canvas.putText(slx, sly, String(tag.prefix(cx2 - cx1 + 2)), z: 8)

            default:
                if elem.isActionable || elem.area > 1000 {
                    let tag = "[\(elem.id)]"
                    let (gx, gy) = toCanvas(f.x, f.y)
                    canvas.putText(gx, gy, String(tag.prefix(cx2 - cx1 + 2)), z: 5)
                }
            }
        }

        // Build header
        let appName = json["applicationName"] as? String ?? "?"
        let windowTitle = json["windowTitle"] as? String ?? ""
        let header = "\(appName) \"\(windowTitle)\" (\(Int(winW))x\(Int(winH)))"

        return header + "\n" + canvas.render()
    }

    private func outputJSONResults(context: SeeCommandRenderContext) async {
        let uiElements: [UIElementSummary] = context.elements.all.map { element in
            UIElementSummary(
                id: element.id,
                role: element.type.rawValue,
                title: element.attributes["title"],
                label: element.label,
                description: element.attributes["description"],
                role_description: element.attributes["roleDescription"],
                help: element.attributes["help"],
                identifier: element.attributes["identifier"],
                is_actionable: element.isEnabled,
                keyboard_shortcut: element.attributes["keyboardShortcut"]
            )
        }

        let snapshotPaths = self.snapshotPaths(for: context)

        // Menu bar enumeration can be slow or hang on some setups. Only attempt it in verbose
        // mode and bound it with a short timeout so JSON output is responsive by default.
        let menuSummary = await self.fetchMenuBarSummaryIfEnabled()

        let output = SeeResult(
            snapshot_id: context.snapshotId,
            screenshot_raw: snapshotPaths.raw,
            screenshot_annotated: snapshotPaths.annotated,
            ui_map: snapshotPaths.map,
            application_name: context.metadata.windowContext?.applicationName,
            window_title: context.metadata.windowContext?.windowTitle,
            is_dialog: context.metadata.isDialog,
            element_count: context.metadata.elementCount,
            interactable_count: context.elements.all.count { $0.isEnabled },
            capture_mode: self.determineMode().rawValue,
            analysis: context.analysis,
            execution_time: context.executionTime,
            ui_elements: uiElements,
            menu_bar: menuSummary
        )

        outputSuccessCodable(data: output, logger: self.outputLogger)
    }

    private func getMenuBarItemsSummary() async -> MenuBarSummary {
        // Get menu bar items from service
        var menuExtras: [MenuExtraInfo] = []

        do {
            menuExtras = try await self.services.menu.listMenuExtras()
        } catch {
            // If there's an error, just return empty array
            menuExtras = []
        }

        // Group items into menu categories
        // For now, we'll create a simplified view showing each menu bar item as a "menu"
        let menus = menuExtras.map { extra in
            MenuBarSummary.MenuSummary(
                title: extra.title,
                item_count: 1, // Each menu bar item is treated as a single menu
                enabled: true,
                items: [
                    MenuBarSummary.MenuItemSummary(
                        title: extra.title,
                        enabled: true,
                        keyboard_shortcut: nil
                    )
                ]
            )
        }

        return MenuBarSummary(menus: menus)
    }

    private func outputTextResults(context: SeeCommandRenderContext) async {
        print("🖼️  Screenshot saved to: \(context.screenshotPath)")
        if let annotatedPath = context.annotatedPath {
            print("📝 Annotated screenshot: \(annotatedPath)")
        }

        if let appName = context.metadata.windowContext?.applicationName {
            print("📱 Application: \(appName)")
        }
        if let windowTitle = context.metadata.windowContext?.windowTitle {
            let windowType = context.metadata.isDialog ? "Dialog" : "Window"
            let icon = context.metadata.isDialog ? "🗨️" : "[win]"
            print("\(icon) \(windowType): \(windowTitle)")
        }
        print("🧊 Detection method: \(context.metadata.method)")
        print("📊 UI elements detected: \(context.metadata.elementCount)")
        print("⚙️  Interactable elements: \(context.elements.all.count { $0.isEnabled })")
        let formattedDuration = String(format: "%.2f", context.executionTime)
        print("⏱️  Execution time: \(formattedDuration)s")

        if let analysis = context.analysis {
            print("\n🤖 AI Analysis\n\(analysis.text)")
        }

        if context.metadata.elementCount > 0 {
            print("\n🔍 Element Summary")
            for element in context.elements.all.prefix(10) {
                let summaryLabel = element.label ?? element.attributes["title"] ?? element.value ?? "Untitled"
                print("• \(element.id) (\(element.type.rawValue)) - \(summaryLabel)")
            }

            if context.metadata.elementCount > 10 {
                print("  ...and \(context.metadata.elementCount - 10) more elements")
            }
        }

        if self.annotate {
            print("\n📝 Annotated screenshot created")
        }

        if let menuSummary = await self.buildMenuSummaryIfNeeded() {
            print("\n🧭 Menu Bar Summary")
            for menu in menuSummary.menus {
                print("- \(menu.title) (\(menu.enabled ? "Enabled" : "Disabled"))")
                for item in menu.items.prefix(5) {
                    let shortcut = item.keyboard_shortcut.map { " [\($0)]" } ?? ""
                    print("    • \(item.title)\(shortcut)")
                }
            }
        }

        print("\nSnapshot ID: \(context.snapshotId)")

        let terminalCapabilities = TerminalDetector.detectCapabilities()
        if terminalCapabilities.recommendedOutputMode == .minimal {
            print("Agent: Use a tool like view_image to inspect it.")
        }
    }

    private func snapshotPaths(for context: SeeCommandRenderContext) -> SnapshotPaths {
        SnapshotPaths(
            raw: context.screenshotPath,
            annotated: context.annotatedPath ?? context.screenshotPath,
            map: self.services.snapshots.getSnapshotStoragePath() + "/\(context.snapshotId)/snapshot.json"
        )
    }
}

// MARK: - Multi-Screen Support

extension SeeCommand {
    func performScreenCapture() async throws -> CaptureResult {
        // Log warning if annotation was requested for full screen captures
        if self.annotate {
            self.logger.info("Annotation is disabled for full screen captures due to performance constraints")
        }

        self.logger.verbose("Initiating screen capture", category: "Capture")
        self.logger.startTimer("screen_capture")

        defer {
            self.logger.stopTimer("screen_capture")
        }

        if let index = self.screenIndex ?? (self.analyze != nil ? 0 : nil) {
            // Capture specific screen
            self.logger.verbose("Capturing specific screen", category: "Capture", metadata: ["screenIndex": index])
            let result = try await ScreenCaptureBridge.captureScreen(services: self.services, displayIndex: index)

            // Add display info to output
            if let displayInfo = result.metadata.displayInfo {
                self.printScreenDisplayInfo(
                    index: index,
                    displayInfo: displayInfo,
                    indent: "",
                    suffix: nil
                )
            }

            self.logger.verbose("Screen capture completed", category: "Capture", metadata: [
                "mode": "screen-index",
                "screenIndex": index,
                "imageBytes": result.imageData.count
            ])
            return result
        } else {
            // Capture all screens
            self.logger.verbose("Capturing all screens", category: "Capture")
            let results = try await self.captureAllScreens()

            if results.isEmpty {
                throw CaptureError.captureFailure("Failed to capture any screens")
            }

            // Save all screenshots except the first (which will be saved by the normal flow)
            print("📸 Captured \(results.count) screen(s):")

            for (index, result) in results.indexed() {
                if index > 0 {
                    // Save additional screenshots
                    let screenPath: String
                    if let basePath = self.path {
                        // User specified a path - add screen index to filename
                        let directory = (basePath as NSString).deletingLastPathComponent
                        let filename = (basePath as NSString).lastPathComponent
                        let nameWithoutExt = (filename as NSString).deletingPathExtension
                        let ext = (filename as NSString).pathExtension

                        screenPath = (directory as NSString)
                            .appendingPathComponent("\(nameWithoutExt)_screen\(index).\(ext)")
                    } else {
                        // Default path with screen index
                        let timestamp = ISO8601DateFormatter().string(from: Date())
                        screenPath = "screenshot_\(timestamp)_screen\(index).png"
                    }

                    // Save the screenshot
                    try result.imageData.write(to: URL(fileURLWithPath: screenPath))

                    // Display info about this screen
                    if let displayInfo = result.metadata.displayInfo {
                        let fileSize = self.getFileSize(screenPath) ?? 0
                        let suffix = "\(screenPath) (\(self.formatFileSize(Int64(fileSize))))"
                        self.printScreenDisplayInfo(
                            index: index,
                            displayInfo: displayInfo,
                            indent: "   ",
                            suffix: suffix
                        )
                    }
                } else {
                    // First screen will be saved by the normal flow, just show info
                    if let displayInfo = result.metadata.displayInfo {
                        self.printScreenDisplayInfo(
                            index: index,
                            displayInfo: displayInfo,
                            indent: "   ",
                            suffix: "(primary)"
                        )
                    }
                }
            }

            // Return the primary screen result (first one)
            self.logger.verbose("Multi-screen capture completed", category: "Capture", metadata: [
                "count": results.count,
                "primaryBytes": results.first?.imageData.count ?? 0
            ])
            return results[0]
        }
    }
}

@MainActor
extension SeeCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            let definition = VisionToolDefinitions.see.commandConfiguration
            return CommandDescription(
                commandName: definition.commandName,
                abstract: definition.abstract,
                discussion: definition.discussion,
                usageExamples: [
                    CommandUsageExample(
                        command: "peekaboo see --json-output --annotate --path /tmp/see.png",
                        description: "Capture the frontmost window, print structured output, and save annotations."
                    ),
                    CommandUsageExample(
                        command: "peekaboo see --app Safari --window-title \"Login\" --json-output",
                        description: "Target a specific Safari window to collect stable element IDs."
                    ),
                    CommandUsageExample(
                        command: "peekaboo see --mode screen --screen-index 0 --analyze 'Summarize the dashboard'",
                        description: "Capture a display and immediately send it to the configured AI provider."
                    )
                ],
                showHelpOnEmptyInvocation: true
            )
        }
    }
}

extension SeeCommand: AsyncRuntimeCommand {}

@MainActor
extension SeeCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = values.singleOption("app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
        self.windowTitle = values.singleOption("windowTitle")
        self.windowId = try values.decodeOption("windowId", as: Int.self)
        if let parsedMode: PeekabooCore.CaptureMode = try values.decodeOptionEnum("mode", caseInsensitive: false) {
            self.mode = parsedMode
        }
        self.path = values.singleOption("path")
        self.screenIndex = try values.decodeOption("screenIndex", as: Int.self)
        self.annotate = values.flag("annotate")
        self.analyze = values.singleOption("analyze")
        self.noWebFocus = values.flag("noWebFocus")
        self.menubar = values.flag("menubar")
        self.fullUiTree = values.flag("fullUiTree")
        self.wireframe = values.flag("wireframe")
    }
}

extension SeeCommand {
    private func screenDisplayBaseText(index: Int, displayInfo: DisplayInfo) -> String {
        let displayName = displayInfo.name ?? "Display \(index)"
        let bounds = displayInfo.bounds
        let resolution = "(\(Int(bounds.width))×\(Int(bounds.height)))"
        return "[scrn]️  Display \(index): \(displayName) \(resolution)"
    }

    private func printScreenDisplayInfo(
        index: Int,
        displayInfo: DisplayInfo,
        indent: String = "",
        suffix: String? = nil
    ) {
        var line = self.screenDisplayBaseText(index: index, displayInfo: displayInfo)
        if let suffix {
            line += " → \(suffix)"
        }
        print("\(indent)\(line)")
    }
}
