import AppKit
import ImageIO
import PDFKit
import Darwin

@main
struct Tests {
    static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let out = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ctx = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: 80, height: 40))
        ctx.setFillColor(CGColor(red: 1, green: 0.3, blue: 0.05, alpha: 1)); ctx.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
        let image = ctx.makeImage()!
        let input = root.appendingPathComponent("测试图片 with spaces.PNG")
        let dest = CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil); precondition(CGImageDestinationFinalize(dest))
        let original = try Data(contentsOf: input)
        let engine = ConversionEngine()
        var checks = 0
        func check(_ value: Bool, _ title: String) {
            precondition(value, title); checks += 1; print("PASS \(title)")
        }
        for format: TargetFormat in [.jpg, .png, .tiff, .bmp, .heic] {
            let result = engine.convert([input], to: format, outputDirectory: out)
            check(result.failures.isEmpty && result.outputs.count == 1, "PNG → \(format.label) real conversion")
            check(result.outputs[0].deletingPathExtension().lastPathComponent == input.deletingPathExtension().lastPathComponent, "filename stem preserved for \(format.label)")
            let source = CGImageSourceCreateWithURL(result.outputs[0] as CFURL, nil)!
            check(CGImageSourceGetType(source)! as String == format.imageType!, "\(format.label) internal format matches extension")
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            check(decoded.width == 80 && decoded.height == 40, "\(format.label) dimensions preserved")
            if format == .jpg {
                let rgb = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                rgb.draw(decoded, in: CGRect(x: 0, y: 0, width: 80, height: 40))
                let bytes = rgb.data!.assumingMemoryBound(to: UInt8.self)
                check(bytes[0] > 240 && bytes[1] > 240 && bytes[2] > 240, "transparent area flattened to white in JPEG")
            }
        }
        let again = engine.convert([input], to: .jpg, outputDirectory: out)
        check(again.outputs.count == 1 && again.outputs[0].lastPathComponent.hasSuffix("-2.jpg"), "existing output is not overwritten")
        check(try Data(contentsOf: input) == original, "original file is unchanged")
        let pdfImage = engine.convert([input], to: .pdf, outputDirectory: out)
        check(pdfImage.failures.isEmpty && PDFDocument(url: pdfImage.outputs[0])?.pageCount == 1, "image → valid PDF")
        let inputText = root.appendingPathComponent("说明.txt")
        let text = "你好，轻转。Unicode conversion test.\n" + (0..<180).map { "Document line \($0): preserve readable body text." }.joined(separator: "\n")
        try text.write(to: inputText, atomically: true, encoding: .utf8)
        let docx = engine.convert([inputText], to: .docx, outputDirectory: out)
        check(docx.failures.isEmpty && docx.outputs.count == 1, "TXT → DOCX")
        check(try Data(contentsOf: docx.outputs[0]).prefix(2) == Data([0x50,0x4b]), "DOCX is a ZIP package, not renamed text")
        let roundtrip = engine.convert(docx.outputs, to: .txt, outputDirectory: out)
        check(try roundtrip.failures.isEmpty && String(contentsOf: roundtrip.outputs[0], encoding: .utf8).contains("你好，轻转"), "DOCX → TXT keeps Chinese text")
        let pdf = engine.convert(docx.outputs, to: .pdf, outputDirectory: out)
        check(pdf.failures.isEmpty && pdf.outputs.count == 1, "DOCX → PDF basic body layout")
        let document = PDFDocument(url: pdf.outputs[0])!
        check(document.pageCount > 1 && (document.string ?? "").contains("Document line 179"), "PDF pagination retains final line")
        let extracted = engine.convert(pdf.outputs, to: .txt, outputDirectory: out)
        check(try extracted.failures.isEmpty && String(contentsOf: extracted.outputs[0], encoding: .utf8).contains("Document line 179"), "PDF → TXT extracts all pages")
        let pages = engine.convert(pdf.outputs, to: .png, outputDirectory: out)
        check(pages.failures.isEmpty && pages.outputs.count == document.pageCount, "PDF → PNG outputs every page")
        for format: TargetFormat in [.rtf, .html] {
            let rich = engine.convert([inputText], to: format, outputDirectory: out)
            check(rich.failures.isEmpty && rich.outputs.count == 1, "TXT → \(format.label)")
            let plain = engine.convert(rich.outputs, to: .txt, outputDirectory: out)
            check(try plain.failures.isEmpty && String(contentsOf: plain.outputs[0], encoding: .utf8).contains("你好，轻转"), "\(format.label) → TXT preserves Chinese")
        }
        let noText = engine.convert(pdfImage.outputs, to: .txt, outputDirectory: out)
        check(noText.outputs.isEmpty && noText.failures.count == 1, "scanned/image-only PDF reports OCR limitation instead of exporting empty text")
        let gif = root.appendingPathComponent("two-frames.gif")
        let gifDest = CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, 2, nil)!
        CGImageDestinationAddImage(gifDest, image, nil); CGImageDestinationAddImage(gifDest, image, nil)
        check(CGImageDestinationFinalize(gifDest), "two-frame fixture generated")
        let gifImage = engine.convert([gif], to: .jpg, outputDirectory: out)
        check(gifImage.outputs.isEmpty && gifImage.failures.count == 1, "multiframe image is not silently truncated")
        let gifPDF = engine.convert([gif], to: .pdf, outputDirectory: out)
        check(gifPDF.failures.isEmpty && PDFDocument(url: gifPDF.outputs[0])?.pageCount == 2, "multiframe image → PDF preserves every frame")
        let bad = root.appendingPathComponent("corrupt.jpg"); try Data("not an image".utf8).write(to: bad)
        let mixed = engine.convert([bad, input], to: .jpg, outputDirectory: out)
        check(mixed.failures.count == 1 && mixed.outputs.count == 1, "batch reports corrupt input and continues")
        let sibling = engine.convert([input], to: .jpg)
        check(sibling.failures.isEmpty && sibling.outputs.count == 1 && sibling.outputs[0].deletingLastPathComponent() == input.deletingLastPathComponent(), "default output is next to the original, with no extra folder")
        check(try Data(contentsOf: input) == original, "sibling output still preserves the original")
        print("\(checks) checks passed. Fixture folder: \(root.path)")
    }
}
