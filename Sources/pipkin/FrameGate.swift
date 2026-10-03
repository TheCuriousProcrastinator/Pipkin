import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

///
enum FrameGate {

    struct ContentGeometry: Equatable {
        let bufferSize: CGSize
        let visibleRectPixels: CGRect

        var hasPadding: Bool {
            visibleRectPixels.minX > 0.5
                || visibleRectPixels.minY > 0.5
                || abs(visibleRectPixels.maxX - bufferSize.width) > 0.5
                || abs(visibleRectPixels.maxY - bufferSize.height) > 0.5
        }
    }

    static let sampleStride = 16


    static func accept(_ sb: CMSampleBuffer) -> Bool {
        guard let status = status(sb) else { return true }
        return status == .complete
    }

    static func status(_ sb: CMSampleBuffer) -> SCFrameStatus? {
        guard let raw = attachments(sb)?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }


    ///
    static func fingerprint(_ sb: CMSampleBuffer) -> UInt64? {
        guard let px = CMSampleBufferGetImageBuffer(sb) else { return nil }
        guard CVPixelBufferGetPixelFormatType(px) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(px) else { return nil }
        guard CVPixelBufferLockBaseAddress(px, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return nil }

        let width = CVPixelBufferGetWidth(px)
        let height = CVPixelBufferGetHeight(px)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(px)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = max(1, sampleStride)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a offset basis

        var y = 0
        while y < height {
            let row = bytes + y * bytesPerRow
            var x = 0
            while x < width {
                let p = row + x * 4
                let v = UInt64(p[0]) | (UInt64(p[1]) << 8) | (UInt64(p[2]) << 16)
                hash = (hash ^ v) &* 0x100_0000_01b3
                x += stride
            }
            y += stride
        }
        hash = (hash ^ UInt64(width)) &* 0x100_0000_01b3
        hash = (hash ^ UInt64(height)) &* 0x100_0000_01b3
        return hash
    }


    static func contentRectPixelSize(_ sb: CMSampleBuffer) -> CGSize? {
        contentGeometry(sb)?.visibleRectPixels.size
    }

    static func contentGeometry(_ sb: CMSampleBuffer) -> ContentGeometry? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sb),
              let info = attachments(sb),
              let dict = info[.contentRect] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }

        let scaleFactor = positiveCGFloat(info[.scaleFactor]) ?? 1
        let contentScale = positiveCGFloat(info[.contentScale])
        let bufferSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let visible = resolvedVisibleRectPixels(
            contentRect: rect,
            scaleFactor: scaleFactor,
            contentScale: contentScale,
            bufferSize: bufferSize
        ) else { return nil }
        return ContentGeometry(bufferSize: bufferSize, visibleRectPixels: visible)
    }

    static func resolvedVisibleRectPixels(
        contentRect: CGRect,
        scaleFactor: CGFloat,
        contentScale: CGFloat?,
        bufferSize: CGSize
    ) -> CGRect? {
        guard bufferSize.width > 1, bufferSize.height > 1,
              contentRect.minX.isFinite, contentRect.minY.isFinite,
              contentRect.width.isFinite, contentRect.height.isFinite,
              contentRect.width > 1, contentRect.height > 1 else { return nil }

        var factors: [CGFloat] = [scaleFactor]
        if let contentScale, contentScale.isFinite, contentScale > 0 {
            factors.append(scaleFactor * contentScale)
            factors.append(contentScale)
        }
        factors.append(1)

        var unique: [CGFloat] = []
        for factor in factors where factor.isFinite && factor > 0 {
            if !unique.contains(where: { abs($0 - factor) < 0.0001 }) { unique.append(factor) }
        }

        let surfaceBounds = CGRect(origin: .zero, size: bufferSize)
        let tolerance: CGFloat = 2
        var candidates: [CGRect] = []
        for factor in unique {
            let candidate = CGRect(
                x: contentRect.minX * factor,
                y: contentRect.minY * factor,
                width: contentRect.width * factor,
                height: contentRect.height * factor
            )
            guard candidate.minX >= -tolerance, candidate.minY >= -tolerance,
                  candidate.maxX <= bufferSize.width + tolerance,
                  candidate.maxY <= bufferSize.height + tolerance else { continue }
            let clipped = candidate.intersection(surfaceBounds)
            guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { continue }
            candidates.append(clipped)
        }

        return candidates.max {
            ($0.width * $0.height) < ($1.width * $1.height)
        }
    }

    private static func positiveCGFloat(_ value: Any?) -> CGFloat? {
        let raw: Double?
        if let number = value as? NSNumber {
            raw = number.doubleValue
        } else if let number = value as? CGFloat {
            raw = Double(number)
        } else {
            raw = nil
        }
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        return CGFloat(raw)
    }

    static func dirtyRectCount(_ sb: CMSampleBuffer) -> Int? {
        guard let info = attachments(sb), let rects = info[.dirtyRects] as? NSArray else { return nil }
        return rects.count
    }


    private static func attachments(_ sb: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]] else { return nil }
        return array.first
    }
}
