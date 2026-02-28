import AppKit
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension SeeCommand {
    func saveScreenshot(_ imageData: Data) throws -> String {
        let outputPath: String

        if let providedPath = path {
            outputPath = NSString(string: providedPath).expandingTildeInPath
        } else {
            let timestamp = Date().timeIntervalSince1970
            let filename = "peekaboo_see_\(Int(timestamp)).png"
            let defaultPath = ConfigurationManager.shared.getDefaultSavePath(cliValue: nil)
            outputPath = (defaultPath as NSString).appendingPathComponent(filename)
        }

        let directory = (outputPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        try imageData.write(to: URL(fileURLWithPath: outputPath))
        self.logger.verbose("Saved screenshot to: \(outputPath)")

        return outputPath
    }

    func resolveSeeWindowIndex(appIdentifier: String, titleFragment: String?) async throws -> Int? {
        guard let fragment = titleFragment, !fragment.isEmpty else {
            return nil
        }

        let appInfo = try await self.services.applications.findApplication(identifier: appIdentifier)
        let snapshot = try await WindowListMapper.shared.snapshot()
        let appWindows = WindowListMapper.scWindows(
            for: appInfo.processIdentifier,
            in: snapshot.scWindows
        )

        guard !appWindows.isEmpty else {
            throw CaptureError.windowNotFound
        }

        if let index = WindowListMapper.scWindowIndex(
            for: appInfo.processIdentifier,
            titleFragment: fragment,
            in: snapshot
        ) {
            return index
        }

        if let index = WindowListMapper.scWindowIndex(for: fragment, in: appWindows) {
            return index
        }

        throw CaptureError.windowNotFound
    }

    func resolveWindowId(appIdentifier: String, titleFragment: String?) async throws -> Int? {
        guard let fragment = titleFragment, !fragment.isEmpty else {
            return nil
        }

        let windows = try await self.services.windows.listWindows(
            target: .applicationAndTitle(app: appIdentifier, title: fragment)
        )
        return windows.first?.windowID
    }

    // swiftlint:disable function_body_length
    func generateAnnotatedScreenshot(
        snapshotId: String,
        originalPath: String
    ) async throws -> String {
        guard let detectionResult = try await self.services.snapshots.getDetectionResult(snapshotId: snapshotId)
        else {
            self.logger.info("No detection result found for snapshot")
            return originalPath
        }

        let annotatedPath = (originalPath as NSString).deletingPathExtension + "_annotated.png"

        guard let nsImage = NSImage(contentsOfFile: originalPath) else {
            throw CaptureError.fileIOError("Failed to load image from \(originalPath)")
        }

        let imageSize = nsImage.size // Size in points (e.g. 1920x1080 on Retina 2x)

        // Use actual pixel dimensions so annotations render at full resolution.
        // NSImage.size returns points; on Retina 2x a 3840x2160 PNG reports 1920x1080 points.
        // Creating the bitmap at point dimensions would downscale the image and produce
        // nearly invisible annotations when compared with the full-resolution raw screenshot.
        let pixelWidth = nsImage.representations.first?.pixelsWide ?? Int(imageSize.width)
        let pixelHeight = nsImage.representations.first?.pixelsHigh ?? Int(imageSize.height)
        let scaleFactor = CGFloat(pixelWidth) / imageSize.width

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        else {
            throw CaptureError.captureFailure("Failed to create bitmap representation")
        }

        // Set point size so the graphics context maps points → pixels at the correct scale.
        // This gives the context an implicit scaling transform (e.g. 2x on Retina),
        // so all drawing coordinates stay in points while rendering at full pixel resolution.
        bitmapRep.size = imageSize

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            self.logger.error("Failed to create graphics context")
            throw CaptureError.captureFailure("Failed to create graphics context")
        }
        NSGraphicsContext.current = context
        self.logger.verbose(
            "Graphics context created: \(pixelWidth)x\(pixelHeight) pixels, scale \(scaleFactor)x"
        )

        nsImage.draw(in: NSRect(origin: .zero, size: imageSize))
        self.logger.verbose("Original image drawn at full resolution")

        let fontSize: CGFloat = 8
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]

        let roleColors: [ElementType: NSColor] = [
            .button: NSColor(red: 0, green: 0.48, blue: 1.0, alpha: 1.0),
            .textField: NSColor(red: 0.204, green: 0.78, blue: 0.349, alpha: 1.0),
            .link: NSColor(red: 0, green: 0.48, blue: 1.0, alpha: 1.0),
            .checkbox: NSColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1.0),
            .slider: NSColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1.0),
            .menu: NSColor(red: 0, green: 0.48, blue: 1.0, alpha: 1.0),
        ]

        let enabledElements = detectionResult.elements.all.filter(\.isEnabled)

        if enabledElements.isEmpty {
            self.logger.info("No enabled elements to annotate. Total elements: \(detectionResult.elements.all.count)")
            print("\(AgentDisplayTokens.Status.warning)  No interactive UI elements found to annotate")
            return originalPath
        }

        self.logger.info(
            "Annotating \(enabledElements.count) enabled elements out of \(detectionResult.elements.all.count) total"
        )
        self.logger.verbose("Image size: \(imageSize)")

        // Compute window origin from enabled elements, excluding those with extreme
        // dimensions (e.g. terminal scrollback buffers whose AX bounds span thousands
        // of points, pulling the origin far off-screen).
        var windowOrigin = CGPoint.zero
        if !enabledElements.isEmpty {
            let reasonableElements = enabledElements.filter { element in
                element.bounds.height <= imageSize.height * 2 &&
                    element.bounds.width <= imageSize.width * 2
            }
            let originElements = reasonableElements.isEmpty ? enabledElements : reasonableElements
            let minX = originElements.map(\.bounds.minX).min() ?? 0
            let minY = originElements.map(\.bounds.minY).min() ?? 0
            windowOrigin = CGPoint(x: minX, y: minY)
            self.logger.verbose("Estimated window origin: \(windowOrigin)")
        }

        var elementRects: [(element: DetectedElement, rect: NSRect)] = []
        for element in enabledElements {
            let elementFrame = CGRect(
                x: element.bounds.origin.x - windowOrigin.x,
                y: element.bounds.origin.y - windowOrigin.y,
                width: element.bounds.width,
                height: element.bounds.height
            )

            let rect = NSRect(
                x: elementFrame.origin.x,
                y: imageSize.height - elementFrame.origin.y - elementFrame.height,
                width: elementFrame.width,
                height: elementFrame.height
            )

            elementRects.append((element: element, rect: rect))
        }

        let labelPlacer = SmartLabelPlacer(
            image: nsImage,
            fontSize: fontSize,
            debugMode: self.verbose,
            logger: self.logger
        )

        var labelPositions: [(rect: NSRect, connection: NSPoint?, element: DetectedElement)] = []
        var placedLabels: [(rect: NSRect, element: DetectedElement)] = []
        let allElements: [(element: DetectedElement, rect: NSRect)] = elementRects.map { ($0.element, $0.rect) }

        for (element, rect) in elementRects {
            let drawingDetails = [
                "Drawing element: \(element.id)",
                "type: \(element.type)",
                "label: \(element.label ?? "")",
                "rect: \(rect)",
                "enabled: \(element.isEnabled)",
                "selected: \(String(describing: element.isSelected))",
                "windowOrigin: \(windowOrigin)",
                "elementBounds: \(element.bounds)",
            ]

            for detail in drawingDetails {
                self.logger.verbose(detail)
            }

            let color = roleColors[element.type] ?? NSColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1.0)
            color.withAlphaComponent(0.8).setStroke()

            let outlinePath = NSBezierPath(rect: rect)
            outlinePath.lineWidth = 1.5
            outlinePath.stroke()

            let label = element.id
            let labelSize = (label as NSString).size(withAttributes: textAttributes)
            guard let placement = labelPlacer.findBestLabelPosition(
                for: element,
                elementRect: rect,
                labelSize: labelSize,
                existingLabels: placedLabels,
                allElements: allElements
            ) else {
                continue
            }

            // Clamp label to stay within image bounds
            var clampedRect = placement.labelRect
            if clampedRect.minX < 0 { clampedRect.origin.x = 0 }
            if clampedRect.minY < 0 { clampedRect.origin.y = 0 }
            if clampedRect.maxX > imageSize.width {
                clampedRect.origin.x = imageSize.width - clampedRect.width
            }
            if clampedRect.maxY > imageSize.height {
                clampedRect.origin.y = imageSize.height - clampedRect.height
            }

            labelPositions.append((rect: clampedRect, connection: placement.connectionPoint, element: element))
            placedLabels.append((rect: clampedRect, element: element))

            if let connectionPoint = placement.connectionPoint {
                let linePath = NSBezierPath()
                linePath.move(to: connectionPoint)
                linePath.line(to: NSPoint(x: rect.midX, y: rect.midY))
                linePath.lineWidth = 0.8
                linePath.stroke()
            }
        }

        for (labelRect, _, element) in labelPositions where labelRect.width > 0 {
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 1, yRadius: 1).fill()

            let color = roleColors[element.type] ?? NSColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1.0)
            color.withAlphaComponent(0.8).setStroke()
            let borderPath = NSBezierPath(roundedRect: labelRect, xRadius: 1, yRadius: 1)
            borderPath.lineWidth = 0.5
            borderPath.stroke()

            let idString = NSAttributedString(string: element.id, attributes: textAttributes)
            idString.draw(at: NSPoint(x: labelRect.origin.x + 4, y: labelRect.origin.y + 2))
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw CaptureError.captureFailure("Failed to create PNG data")
        }

        try pngData.write(to: URL(fileURLWithPath: annotatedPath))
        self.logger.verbose("Created annotated screenshot: \(annotatedPath)")

        if !self.jsonOutput {
            let interactableElements = detectionResult.elements.all.filter(\.isEnabled)
            print("📝 Created annotated screenshot with \(interactableElements.count) interactive elements")
        }

        return annotatedPath
    }

    // swiftlint:enable function_body_length
}
