import AppKit
import ImageIO
import PDFKit
import CoreText

struct ConversionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum TargetFormat: String, CaseIterable {
    case png, jpg, heic, tiff, bmp, pdf, txt, rtf, html, docx
    var label: String { rawValue.uppercased() }
    var imageType: String? {
        switch self {
        case .png: return "public.png"
        case .jpg: return "public.jpeg"
        case .heic: return "public.heic"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        default: return nil
        }
    }
}

struct BatchResult {
    var outputs: [URL] = []
    var failures: [String] = []
}

final class ConversionEngine {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif", "avif"]
    static let documentExtensions: Set<String> = ["txt", "rtf", "html", "htm", "doc", "docx", "odt"]
    static let imageOutputs: [TargetFormat] = [.png, .jpg, .heic, .tiff, .bmp, .pdf]
    static let documentOutputs: [TargetFormat] = [.pdf, .docx, .rtf, .txt, .html]

    static func formats(for urls: [URL]) -> [TargetFormat] {
        guard !urls.isEmpty else { return [] }
        let encoders = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
        let candidates = urls.map { url -> [TargetFormat] in
            let ext = url.pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                return imageOutputs.filter { $0.imageType.map(encoders.contains) ?? true }
            }
            if ext == "pdf" { return [.png, .jpg, .txt, .docx] }
            if documentExtensions.contains(ext) { return documentOutputs }
            return []
        }
        return candidates[0].filter { format in candidates.allSatisfy { $0.contains(format) } }
    }

    static func detail(_ format: TargetFormat, for urls: [URL]) -> String {
        let pdfInput = urls.contains { $0.pathExtension.lowercased() == "pdf" }
        if pdfInput && [.txt, .docx].contains(format) { return "提取文字" }
        if pdfInput && format.imageType != nil { return "逐页导出" }
        if format == .pdf && urls.contains(where: { documentExtensions.contains($0.pathExtension.lowercased()) }) { return "正文基础排版" }
        if format == .jpg || format == .bmp { return "透明区域铺白" }
        return "本地转换"
    }

    func convert(_ urls: [URL], to format: TargetFormat, outputDirectory: URL? = nil) -> BatchResult {
        var result = BatchResult()
        for source in urls {
            do {
                guard source.isFileURL, (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true else {
                    throw ConversionFailure(message: "请拖入文件，暂不支持文件夹")
                }
                let destination = outputDirectory ?? source.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let scratch = destination.appendingPathComponent(".qingzhuan-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: scratch) }
                let staged = try convertOne(source, to: format, in: scratch)
                for file in staged {
                    let target = uniqueURL(in: destination, basename: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension)
                    try FileManager.default.moveItem(at: file, to: target)
                    result.outputs.append(target)
                }
            } catch { result.failures.append(source.lastPathComponent + "：" + error.localizedDescription) }
        }
        return result
    }

    private func uniqueURL(in folder: URL, basename: String, ext: String) -> URL {
        var n = 1
        var url = folder.appendingPathComponent(basename).appendingPathExtension(ext)
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appendingPathComponent(basename + "-\(n)").appendingPathExtension(ext)
        }
        return url
    }

    private func convertOne(_ source: URL, to format: TargetFormat, in scratch: URL) throws -> [URL] {
        let ext = source.pathExtension.lowercased()
        let output = scratch.appendingPathComponent(source.deletingPathExtension().lastPathComponent).appendingPathExtension(format.rawValue)
        if Self.imageExtensions.contains(ext) {
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw ConversionFailure(message: "无法解码此图片") }
            let count = CGImageSourceGetCount(imageSource)
            guard count > 0 else { throw ConversionFailure(message: "图片没有有效画面") }
            if format == .pdf {
                let images = try (0..<count).map { try loadImage(imageSource, index: $0) }
                try writeImagePDF(images, to: output)
            } else {
                guard count == 1 else { throw ConversionFailure(message: "多帧图片请转 PDF 以保留全部画面；暂不输出静态首帧") }
                try writeImage(loadImage(imageSource, index: 0), to: output, format: format)
            }
            return [output]
        }
        if ext == "pdf" {
            guard let pdf = PDFDocument(url: source), !pdf.isLocked else { throw ConversionFailure(message: "PDF 无法读取或需要密码") }
            if format.imageType != nil {
                var outputs: [URL] = []
                for i in 0..<pdf.pageCount {
                    guard let page = pdf.page(at: i) else { throw ConversionFailure(message: "PDF 页面读取失败") }
                    let bounds = page.bounds(for: .mediaBox)
                    guard bounds.width > 0 && bounds.height > 0 else { throw ConversionFailure(message: "PDF 页面尺寸无效") }
                    let scale = min(2.0, 4096.0 / max(bounds.width, bounds.height))
                    let size = NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
                    let thumbnail = page.thumbnail(of: size, for: .mediaBox)
                    guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ConversionFailure(message: "PDF 页面渲染失败") }
                    let file = scratch.appendingPathComponent(source.deletingPathExtension().lastPathComponent + String(format: "-page-%03d", i + 1)).appendingPathExtension(format.rawValue)
                    try writeImage(image, to: file, format: format)
                    outputs.append(file)
                }
                guard !outputs.isEmpty else { throw ConversionFailure(message: "PDF 没有页面") }
                return outputs
            }
            let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversionFailure(message: "没有可提取的文字；扫描 PDF 暂不支持 OCR") }
            if format == .txt { try text.write(to: output, atomically: true, encoding: .utf8) }
            else if format == .docx {
                let plain = scratch.appendingPathComponent("extracted.txt")
                try text.write(to: plain, atomically: true, encoding: .utf8)
                try textutil(plain, to: output, format: "docx")
            } else { throw ConversionFailure(message: "此 PDF 转换组合暂不支持") }
            return [output]
        }
        if Self.documentExtensions.contains(ext) {
            if format == .pdf {
                let rich = scratch.appendingPathComponent("intermediate.rtf")
                try textutil(source, to: rich, format: "rtf")
                let data = try Data(contentsOf: rich)
                let content = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                try writeTextPDF(content, to: output)
            } else if [.txt, .rtf, .html, .docx].contains(format) {
                try textutil(source, to: output, format: format.rawValue)
            } else { throw ConversionFailure(message: "此文档转换组合暂不支持") }
            return [output]
        }
        throw ConversionFailure(message: "暂不支持这个文件类型")
    }

    private func loadImage(_ source: CGImageSource, index: Int) throws -> CGImage {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0 && height > 0 && Int64(width) * Int64(height) <= 100_000_000 else { throw ConversionFailure(message: "图片尺寸过大或无效（上限 1 亿像素）") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { throw ConversionFailure(message: "图片解码失败") }
        return image
    }

    private func writeImage(_ image: CGImage, to url: URL, format: TargetFormat) throws {
        guard let type = format.imageType, let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { throw ConversionFailure(message: "系统暂不支持输出 \(format.label)") }
        var outputImage = image
        if format == .jpg || format == .bmp {
            guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ConversionFailure(message: "无法创建图片画布") }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = ctx.makeImage() else { throw ConversionFailure(message: "图片处理失败") }
            outputImage = flattened
        }
        CGImageDestinationAddImage(destination, outputImage, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionFailure(message: "编码失败，未生成可用文件") }
    }

    private func writeImagePDF(_ images: [CGImage], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ConversionFailure(message: "无法创建 PDF") }
        for image in images {
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: [bounds], length: MemoryLayout<CGRect>.size)] as CFDictionary)
            ctx.draw(image, in: bounds); ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private func writeTextPDF(_ input: NSAttributedString, to url: URL) throws {
        let content = NSMutableAttributedString(attributedString: input)
        if content.length == 0 { content.append(NSAttributedString(string: " ")) }
        let range = NSRange(location: 0, length: content.length)
        content.addAttribute(.foregroundColor, value: NSColor.black, range: range)
        let framesetter = CTFramesetterCreateWithAttributedString(content as CFAttributedString)
        guard let consumer = CGDataConsumer(url: url as CFURL), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ConversionFailure(message: "无法创建 PDF") }
        var offset = 0
        let paper = CGRect(x: 0, y: 0, width: 595, height: 842)
        while offset < content.length {
            guard offset < 10_000_000 else { throw ConversionFailure(message: "文档内容过长") }
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: [paper], length: MemoryLayout<CGRect>.size)] as CFDictionary)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), CGPath(rect: paper.insetBy(dx: 48, dy: 48), transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { ctx.endPDFPage(); ctx.closePDF(); throw ConversionFailure(message: "无法为文档分页") }
            CTFrameDraw(frame, ctx); ctx.endPDFPage(); offset += visible.length
        }
        ctx.closePDF()
    }

    private func textutil(_ source: URL, to destination: URL, format: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", format, "-noload", "-nostore", "-encoding", "UTF-8", "-output", destination.path, "--", source.path]
        let errorPipe = Pipe(); process.standardError = errorPipe; process.standardOutput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(45)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); throw ConversionFailure(message: "文档转换超时") }
        process.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 && FileManager.default.fileExists(atPath: destination.path) else {
            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ConversionFailure(message: detail.isEmpty ? "系统无法转换此文档" : String(detail.prefix(240)))
        }
    }
}
