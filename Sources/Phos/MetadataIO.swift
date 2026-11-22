import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum MetadataIO {
    /// 构建导出图片的属性字典（保留原图 EXIF/TIFF/IPTC/GPS，按需剔除 GPS、注入版权、重置方向为 1）
    static func exportProperties(from sourceURL: URL?, settings: ExportSettings, outputSize: CGSize, utType: UTType) -> [CFString: Any] {
        var props: [CFString: Any] = [:]
        if utType == .jpeg || utType == .heic {
            props[kCGImageDestinationLossyCompressionQuality] = settings.quality
        }
        guard settings.preserveMetadata else {
            var tiff: [CFString: Any] = [kCGImagePropertyTIFFSoftware: "Phos"]
            let copy = settings.copyrightText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !copy.isEmpty { tiff[kCGImagePropertyTIFFCopyright] = copy }
            props[kCGImagePropertyTIFFDictionary] = tiff
            props[kCGImagePropertyOrientation] = 1
            return props
        }

        var sourceMeta: [CFString: Any] = [:]
        if let sourceURL, let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let raw = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            sourceMeta = raw
        }

        if var exif = sourceMeta[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = Int(outputSize.width.rounded())
            exif[kCGImagePropertyExifPixelYDimension] = Int(outputSize.height.rounded())
            props[kCGImagePropertyExifDictionary] = exif
        }

        var tiff = (sourceMeta[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFSoftware] = "Phos"
        let copy = settings.copyrightText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !copy.isEmpty {
            tiff[kCGImagePropertyTIFFCopyright] = copy
        }
        props[kCGImagePropertyTIFFDictionary] = tiff

        var iptc = (sourceMeta[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
        if !copy.isEmpty {
            iptc[kCGImagePropertyIPTCCopyrightNotice] = copy
        }
        if !iptc.isEmpty {
            props[kCGImagePropertyIPTCDictionary] = iptc
        }

        if !settings.stripGPS, let gps = sourceMeta[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty {
            props[kCGImagePropertyGPSDictionary] = gps
        }

        props[kCGImagePropertyOrientation] = 1
        props[kCGImagePropertyPixelWidth] = Int(outputSize.width.rounded())
        props[kCGImagePropertyPixelHeight] = Int(outputSize.height.rounded())
        return props
    }

    /// 尝试以 HDR / 广色域格式写出图像（JPEG 附加 ISO 21496-1 Gain Map 或 10-bit HEIC / 16-bit Display P3 TIFF）
    static func writeHDRIfSupported(_ img: CIImage, ctx: CIContext, to url: URL, utType: UTType,
                                    settings: ExportSettings, sourceURL: URL?) -> Bool {
        guard settings.exportHDR else { return false }
        let hdrLinearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? Engine.srgb
        let sdrP3 = CGColorSpace(name: CGColorSpace.displayP3) ?? Engine.srgb
        let props = exportProperties(from: sourceURL, settings: settings, outputSize: img.extent.size, utType: utType)

        if utType == .heic {
            // 先尝试 10-bit PQ HEIC，保留完整 HDR 高光动态范围
            let pqP3 = CGColorSpace(name: CGColorSpace.displayP3_PQ) ?? hdrLinearP3
            if let data = try? ctx.heif10Representation(of: img, colorSpace: pqP3, options: [:]) {
                if writeDataWithMetadata(data, utType: .heic, props: props, to: url) { return true }
            }
        }
        if utType == .jpeg {
            // macOS 15+ 支持利用 CIImageRepresentationOption.hdrImage 生成带 Gain Map 的兼容 HDR JPEG
            let sdrClamped = img.applyingFilter("CIColorClamp")
            if let data = ctx.jpegRepresentation(of: sdrClamped, colorSpace: sdrP3, options: [
                .hdrImage: img,
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): settings.quality
            ]) {
                if writeDataWithMetadata(data, utType: .jpeg, props: props, to: url) { return true }
            }
        }
        if utType == .tiff || utType == .png {
            guard let cg = ctx.createCGImage(img, from: img.extent, format: .RGBA16, colorSpace: hdrLinearP3),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil) else {
                return false
            }
            CGImageDestinationAddImage(dest, cg, props as CFDictionary)
            return CGImageDestinationFinalize(dest)
        }
        return false
    }

    private static func writeDataWithMetadata(_ data: Data, utType: UTType, props: [CFString: Any], to url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil) else {
            return (try? data.write(to: url, options: .atomic)) != nil
        }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
