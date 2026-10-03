import AppKit

///
enum Geo {


    static func pixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let w = Int((points.width * scale).rounded())
        let h = Int((points.height * scale).rounded())
        return (min(max(w, 2), 4096), min(max(h, 2), 4096))
    }

    static func isScreenFillingWindow(size: CGSize, screenSizes: [CGSize]) -> Bool {
        screenSizes.contains { screen in
            guard screen.width > 1, screen.height > 1 else { return false }
            let widthRatio = size.width / screen.width
            let heightRatio = size.height / screen.height
            return widthRatio >= 0.85 && widthRatio <= 1.05
                && heightRatio >= 0.75 && heightRatio <= 1.05
        }
    }

    ///
    static func initialPiPWidth(
        sourceSize: CGSize,
        rememberedWidth: CGFloat?,
        screenSizes: [CGSize],
        isWindowSource: Bool
    ) -> CGFloat {
        let legacyDefaultMax: CGFloat = 640
        let fullscreenDefaultMax: CGFloat = 480
        let isFullscreenLike = isWindowSource && screenSizes.contains { screen in
            guard screen.width > 1, screen.height > 1 else { return false }
            let widthRatio = sourceSize.width / screen.width
            let heightRatio = sourceSize.height / screen.height
            return widthRatio >= 0.97 && widthRatio <= 1.03
                && heightRatio >= 0.97 && heightRatio <= 1.03
        }

        if isFullscreenLike {
            if let rememberedWidth, abs(rememberedWidth - legacyDefaultMax) > 0.5 {
                return rememberedWidth
            }
            return min(max(sourceSize.width / 4, 320), fullscreenDefaultMax)
        }

        if let rememberedWidth { return rememberedWidth }
        return min(max(sourceSize.width / 2, 320), legacyDefaultMax)
    }


    static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, PiPSessionState.minZoom), PiPSessionState.maxZoom)
    }

    /// - Parameters:
    static func sourceRect(zoom: CGFloat, anchor: CGPoint, full: CGRect) -> CGRect {
        let z = clampZoom(zoom)
        let w = full.width / z
        let h = full.height / z
        var x = full.minX + anchor.x * full.width - w / 2
        var y = full.minY + anchor.y * full.height - h / 2
        x = min(max(x, full.minX), full.maxX - w)
        y = min(max(y, full.minY), full.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func clampAnchor(_ anchor: CGPoint, zoom: CGFloat) -> CGPoint {
        let z = clampZoom(zoom)
        guard z > 1 else { return CGPoint(x: 0.5, y: 0.5) }
        let half = 1 / (2 * z)
        return CGPoint(
            x: min(max(anchor.x, half), 1 - half),
            y: min(max(anchor.y, half), 1 - half)
        )
    }

    static func anchor(_ anchor: CGPoint, pannedBy delta: CGSize, zoom: CGFloat) -> CGPoint {
        let z = clampZoom(zoom)
        let moved = CGPoint(x: anchor.x + delta.width / z, y: anchor.y + delta.height / z)
        return clampAnchor(moved, zoom: z)
    }

    static func anchor(zoomingFrom oldAnchor: CGPoint, oldZoom: CGFloat,
                       to newZoom: CGFloat, pointerNorm: CGPoint) -> CGPoint {
        let oz = clampZoom(oldZoom), nz = clampZoom(newZoom)
        guard nz > 1 else { return CGPoint(x: 0.5, y: 0.5) }
        let dx = pointerNorm.x - oldAnchor.x
        let dy = pointerNorm.y - oldAnchor.y
        let ratio = oz / nz
        return clampAnchor(CGPoint(x: pointerNorm.x - dx * ratio,
                                   y: pointerNorm.y - dy * ratio), zoom: nz)
    }


    ///
    ///
    /// - Parameters:
    static func trustedSourceSize(sampled: CGSize, current: CGRect, axSize: CGSize?) -> CGSize? {
        guard sampled.width > 1, sampled.height > 1 else { return nil }
        if let ax = axSize, ax.width > 1, ax.height > 1 {
            let differs = abs(ax.width - sampled.width) > 1 || abs(ax.height - sampled.height) > 1
            return differs ? ax : sampled
        }
        guard current.width > 1, current.height > 1 else { return sampled }
        let sx = sampled.width / current.width
        let sy = sampled.height / current.height
        let uniformShrink = sx < 0.995 && abs(sx - sy) < 0.01
        return uniformShrink ? nil : sampled
    }

    ///
    static func displayLayerFrame(
        bufferSize: CGSize,
        visibleRectPixels: CGRect,
        in bounds: CGRect
    ) -> CGRect? {
        guard bufferSize.width > 1, bufferSize.height > 1,
              visibleRectPixels.width > 1, visibleRectPixels.height > 1,
              bounds.width > 1, bounds.height > 1 else { return nil }

        let surfaceBounds = CGRect(origin: .zero, size: bufferSize)
        let visible = visibleRectPixels.intersection(surfaceBounds)
        guard !visible.isNull, visible.width > 1, visible.height > 1 else { return nil }

        let sx = bounds.width / visible.width
        let sy = bounds.height / visible.height
        let bottomPadding = bufferSize.height - visible.maxY
        return CGRect(
            x: bounds.minX - visible.minX * sx,
            y: bounds.minY - bottomPadding * sy,
            width: bufferSize.width * sx,
            height: bufferSize.height * sy
        )
    }


    static func contentRect(aspect: CGSize, in bounds: CGRect) -> CGRect {
        guard aspect.width > 0, aspect.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / aspect.width, bounds.height / aspect.height)
        let size = CGSize(width: aspect.width * scale, height: aspect.height * scale)
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) / 2,
            y: bounds.minY + (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    static func visibleNormalizedRect(forSelection rect: CGRect, aspect: CGSize, bounds: CGRect) -> CGRect? {
        let content = contentRect(aspect: aspect, in: bounds)
        let sel = rect.intersection(content)
        guard !sel.isNull, sel.width > 8, sel.height > 8,
              content.width > 1, content.height > 1 else { return nil }
        return CGRect(
            x: (sel.minX - content.minX) / content.width,
            y: 1 - (sel.maxY - content.minY) / content.height,
            width: sel.width / content.width,
            height: sel.height / content.height
        )
    }

    static func sourceRect(fromNormalizedVisibleRect normalized: CGRect, within visible: CGRect) -> CGRect? {
        let n = normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !n.isNull, n.width > 0, n.height > 0,
              visible.width > 1, visible.height > 1 else { return nil }
        let mapped = CGRect(
            x: visible.minX + n.minX * visible.width,
            y: visible.minY + n.minY * visible.height,
            width: n.width * visible.width,
            height: n.height * visible.height
        ).intersection(visible)
        guard !mapped.isNull, mapped.width > 1, mapped.height > 1 else { return nil }
        return mapped
    }

    static func remap(_ rect: CGRect, from oldBase: CGRect, to newBase: CGRect) -> CGRect? {
        guard oldBase.width > 1, oldBase.height > 1,
              newBase.width > 1, newBase.height > 1 else { return nil }
        let nx = (rect.minX - oldBase.minX) / oldBase.width
        let ny = (rect.minY - oldBase.minY) / oldBase.height
        let nw = rect.width / oldBase.width
        let nh = rect.height / oldBase.height
        let mapped = CGRect(
            x: newBase.minX + nx * newBase.width,
            y: newBase.minY + ny * newBase.height,
            width: nw * newBase.width,
            height: nh * newBase.height
        ).intersection(newBase)
        guard !mapped.isNull, mapped.width > 1, mapped.height > 1 else { return nil }
        return mapped
    }

    static func viewPointToVisibleNorm(_ point: CGPoint, aspect: CGSize, bounds: CGRect) -> CGPoint? {
        let content = contentRect(aspect: aspect, in: bounds)
        guard content.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - content.minX) / content.width,
            y: 1 - (point.y - content.minY) / content.height
        )
    }

    static func visibleNormToSourceNorm(_ p: CGPoint, zoom: CGFloat, anchor: CGPoint) -> CGPoint {
        let z = clampZoom(zoom)
        let half = 1 / (2 * z)
        let a = clampAnchor(anchor, zoom: z)
        return CGPoint(x: a.x - half + p.x / z, y: a.y - half + p.y / z)
    }


    static func sckRect(fromScreenRect r: CGRect, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: r.minX - f.minX,
                      y: f.maxY - r.maxY,
                      width: r.width, height: r.height)
    }

    static func screenRect(fromSCKRect r: CGRect, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: r.minX + f.minX,
                      y: f.maxY - r.minY - r.height,
                      width: r.width, height: r.height)
    }

    static func windowLocalRect(fromScreenRect r: CGRect, windowFrameTopLeft: CGRect,
                                primaryScreenMaxY: CGFloat) -> CGRect {
        let topLeft = CGRect(x: r.minX, y: primaryScreenMaxY - r.maxY, width: r.width, height: r.height)
        return CGRect(x: topLeft.minX - windowFrameTopLeft.minX,
                      y: topLeft.minY - windowFrameTopLeft.minY,
                      width: topLeft.width, height: topLeft.height)
    }

    static var primaryScreenMaxY: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
    }

    static func constrainToVisibleScreens(_ rect: CGRect) -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return rect }
        if screens.contains(where: { $0.visibleFrame.intersects(rect) }) { return rect }
        let target = (NSScreen.main ?? screens[0]).visibleFrame
        var r = rect
        r.origin.x = min(max(rect.minX, target.minX), target.maxX - rect.width)
        r.origin.y = min(max(rect.minY, target.minY), target.maxY - rect.height)
        return r
    }


    ///
    ///
    /// - Parameters:
    static func snappedWindowFrame(
        _ proposed: CGRect,
        in visibleFrame: CGRect,
        siblings: [CGRect],
        threshold: CGFloat = 12,
        gap: CGFloat = 0,
        edgeInset: CGFloat = 0
    ) -> CGRect {
        guard proposed.width > 0, proposed.height > 0,
              visibleFrame.width > 0, visibleFrame.height > 0,
              threshold >= 0 else { return proposed }

        var xDeltas = [
            visibleFrame.minX + edgeInset - proposed.minX,
            visibleFrame.maxX - edgeInset - proposed.maxX,
        ]
        var yDeltas = [
            visibleFrame.minY + edgeInset - proposed.minY,
            visibleFrame.maxY - edgeInset - proposed.maxY,
        ]

        for sibling in siblings where sibling.width > 0 && sibling.height > 0
            && visibleFrame.intersects(sibling) {
            if intervalsAreNear(proposed.minY, proposed.maxY, sibling.minY, sibling.maxY,
                                tolerance: gap + threshold) {
                xDeltas.append(contentsOf: [
                    sibling.minX - proposed.minX,
                    sibling.maxX - proposed.maxX,
                    sibling.minX - gap - proposed.maxX,
                    sibling.maxX + gap - proposed.minX,
                ])
            }
            if intervalsAreNear(proposed.minX, proposed.maxX, sibling.minX, sibling.maxX,
                                tolerance: gap + threshold) {
                yDeltas.append(contentsOf: [
                    sibling.minY - proposed.minY,
                    sibling.maxY - proposed.maxY,
                    sibling.minY - gap - proposed.maxY,
                    sibling.maxY + gap - proposed.minY,
                ])
            }
        }

        var result = proposed
        if let dx = closestSnapDelta(in: xDeltas, threshold: threshold) { result.origin.x += dx }
        if let dy = closestSnapDelta(in: yDeltas, threshold: threshold) { result.origin.y += dy }
        return result
    }

    private static func intervalsAreNear(_ aMin: CGFloat, _ aMax: CGFloat,
                                         _ bMin: CGFloat, _ bMax: CGFloat,
                                         tolerance: CGFloat) -> Bool {
        max(aMin, bMin) <= min(aMax, bMax) + tolerance
    }

    private static func closestSnapDelta(in candidates: [CGFloat], threshold: CGFloat) -> CGFloat? {
        candidates
            .filter { $0.isFinite && abs($0) <= threshold }
            .min { abs($0) < abs($1) }
    }

    ///
    static func indexOfScreen(containing frame: CGRect, screenFrames: [CGRect]) -> Int? {
        guard !screenFrames.isEmpty else { return nil }

        var bestIndex = 0
        var bestOverlap = overlapArea(screenFrames[0], frame)
        for index in screenFrames.indices.dropFirst() {
            let overlap = overlapArea(screenFrames[index], frame)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestIndex = index
            }
        }
        if bestOverlap > 0 { return bestIndex }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        var nearestIndex = 0
        var nearestDistance = squaredDistance(from: center, to: screenFrames[0])
        for index in screenFrames.indices.dropFirst() {
            let distance = squaredDistance(from: center, to: screenFrames[index])
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = index
            }
        }
        return nearestIndex
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }

        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }

        return dx * dx + dy * dy
    }


    #if DEBUG
    static func runSelfChecks() {
        let full = CGRect(x: 0, y: 0, width: 1000, height: 500)

        let r1 = sourceRect(zoom: 1, anchor: CGPoint(x: 0.5, y: 0.5), full: full)
        assert(abs(r1.width - 1000) < 0.001 && abs(r1.height - 500) < 0.001, "1x ")

        let r2 = sourceRect(zoom: 2, anchor: CGPoint(x: 0.5, y: 0.5), full: full)
        assert(abs(r2.width - 500) < 0.001 && abs(r2.minX - 250) < 0.001, "2x ")

        let r3 = sourceRect(zoom: 4, anchor: CGPoint(x: 0, y: 0), full: full)
        assert(r3.minX >= -0.001 && r3.minY >= -0.001, "")
        let r4 = sourceRect(zoom: 4, anchor: CGPoint(x: 1, y: 1), full: full)
        assert(r4.maxX <= full.maxX + 0.001 && r4.maxY <= full.maxY + 0.001, "")

        let a = anchor(CGPoint(x: 0.5, y: 0.5), pannedBy: CGSize(width: 5, height: 5), zoom: 2)
        assert(a.x <= 0.75 + 0.001 && a.y <= 0.75 + 0.001, " clamp")

        let pointer = CGPoint(x: 0.25, y: 0.25)
        let na = anchor(zoomingFrom: CGPoint(x: 0.5, y: 0.5), oldZoom: 1, to: 2, pointerNorm: pointer)
        assert(abs(na.x - 0.25) < 0.26, "")

        if let screen = NSScreen.main {
            let orig = CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 80, width: 300, height: 200)
            let back = screenRect(fromSCKRect: sckRect(fromScreenRect: orig, on: screen), on: screen)
            assert(abs(back.minX - orig.minX) < 0.001 && abs(back.minY - orig.minY) < 0.001,
                   "AppKit ↔ SCK ")
        }

        let c = contentRect(aspect: CGSize(width: 16, height: 9), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        assert(abs(c.width - 400) < 0.001 && c.height < 400, "contentRect ")

        let base = CGRect(x: 0, y: 0, width: 1600, height: 813)
        assert(trustedSourceSize(sampled: CGSize(width: 1092, height: 555),
                                 current: base, axSize: nil) == nil,
               "")
        assert(trustedSourceSize(sampled: CGSize(width: 1200, height: 813),
                                 current: base, axSize: nil) != nil,
               "")
        let picked = trustedSourceSize(sampled: CGSize(width: 1092, height: 555), current: base,
                                       axSize: CGSize(width: 1600, height: 813))
        assert(picked?.width == 1600, "AX  AX")
        assert(trustedSourceSize(sampled: CGSize(width: 800, height: 600),
                                 current: .zero, axSize: nil) != nil,
               "current ")

        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let nearRight = CGRect(x: 689, y: 200, width: 300, height: 180)
        let snappedRight = snappedWindowFrame(nearRight, in: visible, siblings: [])
        assert(abs(snappedRight.maxX - 1000) < 0.001, "")
        assert(snappedRight.size == nearRight.size, "")

        let sibling = CGRect(x: 700, y: 300, width: 200, height: 100)
        let nearAbove = CGRect(x: 702, y: 403, width: 200, height: 100)
        let snappedAbove = snappedWindowFrame(nearAbove, in: visible, siblings: [sibling])
        assert(abs(snappedAbove.maxX - sibling.maxX) < 0.001, "")
        assert(abs(snappedAbove.minY - sibling.maxY) < 0.001, "")

        let free = CGRect(x: 650, y: 650, width: 200, height: 100)
        let distant = CGRect(x: 649, y: 50, width: 200, height: 100)
        let unchanged = snappedWindowFrame(free, in: visible, siblings: [distant])
        assert(unchanged == free, "")

        let screenFrames = [
            CGRect(x: -1440, y: -200, width: 1440, height: 900),
            CGRect(x: 40, y: 0, width: 1920, height: 1080),
        ]
        assert(indexOfScreen(containing: CGRect(x: -300, y: 100, width: 300, height: 180),
                             screenFrames: screenFrames) == 0,
               "")
        assert(indexOfScreen(containing: CGRect(x: -20, y: 100, width: 300, height: 180),
                             screenFrames: screenFrames) == 1,
               "")
        assert(indexOfScreen(containing: CGRect(x: 14, y: 400, width: 24, height: 24),
                             screenFrames: screenFrames) == 1,
               "")
        assert(indexOfScreen(containing: visible, screenFrames: []) == nil,
               "")
        assert(squaredDistance(from: .zero, to: CGRect(x: -100, y: -50, width: 200, height: 100)) == 0,
               " 0")

        Log.debug("Geo ")
    }
    #endif
}
