import Foundation

public enum VideoCompositorLayout {
    public static func overlayRect(
        screen: PixelSize,
        camera: PixelSize,
        settings: OverlaySettings
    ) -> PixelRect? {
        guard settings.isEnabled else {
            return nil
        }
        guard screen.width > 0, screen.height > 0, camera.width > 0, camera.height > 0 else {
            return nil
        }

        let usableWidth = max(0, screen.width - settings.margin * 2)
        let usableHeight = max(0, screen.height - settings.margin * 2)
        guard usableWidth > 0, usableHeight > 0 else {
            return nil
        }

        let cameraAspectRatio = camera.width / camera.height
        let requestedWidth = screen.width * settings.sizePreset.screenWidthFraction
        let maxAllowedWidth = min(settings.maximumWidth, usableWidth)
        var rectangleWidth = min(max(requestedWidth, settings.minimumWidth), maxAllowedWidth)
        var rectangleHeight = rectangleWidth / cameraAspectRatio

        if rectangleHeight > usableHeight {
            rectangleHeight = usableHeight
            rectangleWidth = rectangleHeight * cameraAspectRatio
        }

        var overlayWidth: Double
        var overlayHeight: Double

        switch settings.shape {
        case .rectangle:
            overlayWidth = rectangleWidth
            overlayHeight = rectangleHeight
        case .square:
            overlayWidth = min(rectangleWidth, usableHeight)
            overlayHeight = overlayWidth
        case .circle:
            let diameter = min(rectangleHeight, usableWidth, usableHeight)
            overlayWidth = diameter
            overlayHeight = diameter
        }

        if overlayHeight > usableHeight {
            overlayHeight = usableHeight
            switch settings.shape {
            case .rectangle:
                let cameraAspectRatio = camera.width / camera.height
                overlayWidth = overlayHeight * cameraAspectRatio
            case .square, .circle:
                overlayWidth = overlayHeight
            }
        }

        overlayWidth = max(0, min(overlayWidth, usableWidth))
        overlayHeight = max(0, min(overlayHeight, usableHeight))

        guard overlayWidth > 0, overlayHeight > 0 else {
            return nil
        }

        let minX = min(settings.margin, max(0, screen.width - overlayWidth))
        let maxX = max(0, screen.width - settings.margin - overlayWidth)
        let centerX = max(0, (screen.width - overlayWidth) / 2)
        let minY = min(settings.margin, max(0, screen.height - overlayHeight))
        let maxY = max(0, screen.height - settings.margin - overlayHeight)

        let x: Double
        let y: Double

        switch settings.position {
        case .bottomLeft:
            x = minX
            y = maxY
        case .topLeft:
            x = minX
            y = minY
        case .topRight:
            x = maxX
            y = minY
        case .bottomRight:
            x = maxX
            y = maxY
        case .topMiddle:
            x = centerX
            y = minY
        case .bottomMiddle:
            x = centerX
            y = maxY
        }

        return PixelRect(x: x, y: y, width: overlayWidth, height: overlayHeight)
    }
}
