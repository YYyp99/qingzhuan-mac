import AppKit

enum PathClipboard {
    @discardableResult
    static func copy(_ urls: [URL], to board: NSPasteboard = .general) -> Bool {
        guard !urls.isEmpty else { return false }
        board.clearContents()
        return board.setString(urls.map { $0.path }.joined(separator: "\n"), forType: .string)
    }
}

enum WheelAction {
    case convert(TargetFormat)
    case copyPath
    var label: String {
        switch self { case .convert(let format): return format.label; case .copyPath: return "Copy Path" }
    }
}

final class FormatWheel: NSView {
    var urls: [URL] = []
    var formats: [TargetFormat] = []
    var actions: [WheelAction] = []
    var hovered: Int?
    var onDrop: (([URL], WheelAction) -> Void)?
    let center = NSPoint(x: 190, y: 190)
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func configure(_ urls: [URL]) {
        self.urls = urls
        formats = ConversionEngine.formats(for: urls)
        actions = [.copyPath] + formats.map { .convert($0) }
        hovered = nil; needsDisplay = true
    }
    // Rounded annular sectors: drawing and drop hit testing share the same path.
    func sector(_ i: Int) -> NSBezierPath {
        let step = 360.0 / Double(max(1, actions.count))
        let middle = 90.0 - Double(i) * step
        let start = middle - step / 2 + 3.0
        let end = middle + step / 2 - 3.0
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: 166, startAngle: start, endAngle: end)
        let inner = NSPoint(x: center.x + 67 * cos(end * .pi / 180), y: center.y + 67 * sin(end * .pi / 180))
        path.line(to: inner)
        path.appendArc(withCenter: center, radius: 67, startAngle: end, endAngle: start, clockwise: true)
        path.close()
        path.lineJoinStyle = .round
        return path
    }
    func item(at point: NSPoint) -> Int? { actions.indices.first { sector($0).contains(point) } }
    func text(_ string: String, in rect: CGRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingMiddle
        (string as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
    }
    override func draw(_ dirtyRect: NSRect) {
        let disk = NSBezierPath(ovalIn: CGRect(x: 13, y: 13, width: 354, height: 354))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.10); shadow.shadowBlurRadius = 12; shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.set()
        NSColor(calibratedWhite: 0.94, alpha: 0.98).setFill(); disk.fill()
        NSGraphicsContext.restoreGraphicsState()
        for i in actions.indices {
            let selected = hovered == i
            let path = sector(i)
            let fill = selected ? NSColor(calibratedRed: 1, green: 0.29, blue: 0.015, alpha: 1) : NSColor(calibratedWhite: 0.965, alpha: 1)
            NSGradient(starting: fill, ending: selected ? fill : NSColor(calibratedWhite: 0.91, alpha: 1))!.draw(in: path, angle: -90)
            // A thick, round join softens all four corners while preserving the wedge shape.
            fill.setStroke(); path.lineWidth = 9; path.stroke()
            let angle = (90.0 - Double(i) * 360.0 / Double(actions.count)) * .pi / 180
            let x = center.x + cos(angle) * 117
            let y = center.y + sin(angle) * 117
            let color: NSColor = selected ? .white : NSColor(calibratedWhite: 0.08, alpha: 1)
            text(actions[i].label, in: CGRect(x: x - 47, y: y - 9, width: 94, height: 22), size: actions[i].label == "Copy Path" ? 13 : 16, color: color, weight: .semibold)
        }
        let hub = NSBezierPath(ovalIn: CGRect(x: 137, y: 137, width: 106, height: 106))
        NSColor.white.withAlphaComponent(0.9).setFill(); hub.fill()
        let title = hovered.map { actions[$0].label } ?? (urls.count == 1 ? urls[0].pathExtension.uppercased() : "\(urls.count) 个文件")
        text(title.isEmpty ? "文件" : title, in: CGRect(x: 142, y: 189, width: 96, height: 24), size: 14, color: .black, weight: .medium)
        let hint = hovered.map { if case .copyPath = actions[$0] { return "松开复制路径" }; return "松开转换" } ?? "拖入选择"
        text(hint, in: CGRect(x: 141, y: 168, width: 98, height: 18), size: 10, color: .gray)
    }
    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        configure(Self.fileURLs(sender.draggingPasteboard)); return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovered = item(at: convert(sender.draggingLocation, from: nil)); needsDisplay = true
        return hovered == nil ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hovered != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = item(at: convert(sender.draggingLocation, from: nil)), actions.indices.contains(index) else { return false }
        let files = Self.fileURLs(sender.draggingPasteboard)
        guard !files.isEmpty else { return false }
        onDrop?(files, actions[index]); return true
    }
}

final class App: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var home: NSWindow!
    var outputLabel: NSTextField!
    var resultText: NSTextView!
    var wheelPanel: NSPanel!
    var wheelView: FormatWheel!
    var timer: Timer?
    var wasDown = false
    var startPoint = NSEvent.mouseLocation
    var lastCompletedBoard = NSPasteboard(name: .drag).changeCount
    var lastOutput: URL?
    var isWorking = false
    let queue = DispatchQueue(label: "local.qingzhuan.converter", qos: .userInitiated)
    var chosenDirectory: URL? {
        UserDefaults.standard.string(forKey: "outputDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "轻转")
        let menu = NSMenu()
        for (title, action) in [("轻转 · 本地格式转换", #selector(showHome)), ("选择文件转换…", #selector(chooseFiles)), ("设置保存位置…", #selector(chooseOutput)), ("显示最近结果", #selector(revealOutput)), ("退出轻转", #selector(quit))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        statusItem.menu = menu
        let appMenu = NSMenu(); let root = NSMenuItem(); let submenu = NSMenu(); root.submenu = submenu; appMenu.addItem(root)
        submenu.addItem(withTitle: "显示轻转", action: #selector(showHome), keyEquivalent: "0").target = self
        submenu.addItem(withTitle: "退出轻转", action: #selector(quit), keyEquivalent: "q").target = self
        NSApp.mainMenu = appMenu
        wheelPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 380), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        wheelPanel.level = .floating; wheelPanel.isOpaque = false; wheelPanel.backgroundColor = .clear
        wheelPanel.hasShadow = true; wheelPanel.hidesOnDeactivate = false
        wheelPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        wheelView = FormatWheel(frame: NSRect(x: 0, y: 0, width: 380, height: 380)); wheelPanel.contentView = wheelView
        wheelView.onDrop = { [weak self] urls, action in
            self?.wheelPanel.orderOut(nil)
            switch action {
            case .convert(let format): self?.run(urls, format)
            case .copyPath: self?.copyPaths(urls)
            }
        }
        setupHome()
        showHome()
        timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in self?.pollDrag() }
        RunLoop.main.add(timer!, forMode: .eventTracking)
        RunLoop.main.add(timer!, forMode: .modalPanel)
    }
    func setupHome() {
        home = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 530), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        home.title = "轻转"; home.isReleasedWhenClosed = false; home.center()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 530)); home.contentView = container
        func label(_ value: String, _ frame: NSRect, _ size: CGFloat, _ bold: Bool = false) -> NSTextField {
            let l = NSTextField(labelWithString: value); l.frame = frame; l.font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular); container.addSubview(l); return l
        }
        _ = label("文件换个格式，工作继续。", NSRect(x: 32, y: 448, width: 600, height: 42), 28, true)
        _ = label("在 Finder 中拖动文件，按一下 Shift，再拖到目标格式或 Copy Path 上松开。", NSRect(x: 32, y: 408, width: 610, height: 28), 12)
        let info = label("图片：PNG / JPG / HEIC / WebP / TIFF / BMP 等\n文档：TXT / RTF / HTML / DOCX / DOC / ODT；PDF 可逐页转图片、提取文字。\n所有处理在本机完成；保留原文件、同名结果自动编号。", NSRect(x: 32, y: 306, width: 600, height: 88), 12)
        info.maximumNumberOfLines = 4; info.textColor = .secondaryLabelColor
        let note = label("文档转 PDF 为正文基础排版；PDF 转 Word 为文字提取。\n暂不提供扫描件 OCR、复杂文档排版还原；WebP 目前支持读入。", NSRect(x: 32, y: 246, width: 600, height: 50), 12)
        note.maximumNumberOfLines = 3; note.textColor = .secondaryLabelColor
        let button = NSButton(title: "选择文件转换…", target: self, action: #selector(chooseFiles)); button.bezelStyle = .rounded; button.frame = NSRect(x: 28, y: 192, width: 150, height: 36); container.addSubview(button)
        let output = NSButton(title: "保存位置…", target: self, action: #selector(chooseOutput)); output.bezelStyle = .rounded; output.frame = NSRect(x: 186, y: 192, width: 130, height: 36); container.addSubview(output)
        let reveal = NSButton(title: "显示结果", target: self, action: #selector(revealOutput)); reveal.bezelStyle = .rounded; reveal.frame = NSRect(x: 326, y: 192, width: 110, height: 36); container.addSubview(reveal)
        outputLabel = label("", NSRect(x: 32, y: 154, width: 595, height: 25), 11); outputLabel.lineBreakMode = .byTruncatingMiddle; updateOutputLabel()
        let scroll = NSScrollView(frame: NSRect(x: 32, y: 30, width: 595, height: 115)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        resultText = NSTextView(frame: scroll.bounds); resultText.isEditable = false; resultText.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular); resultText.string = "已就绪。拖动文件时轻按 Shift，选择目标格式或 Copy Path。"
        scroll.documentView = resultText; container.addSubview(scroll)
    }
    func pollDrag() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let point = NSEvent.mouseLocation
        let board = NSPasteboard(name: .drag)
        if down && !wasDown { startPoint = point }
        if !isWorking && down && !wheelPanel.isVisible && NSEvent.modifierFlags.contains(.shift) && board.changeCount != lastCompletedBoard && hypot(point.x - startPoint.x, point.y - startPoint.y) > 5 {
            let files = FormatWheel.fileURLs(board)
            if !files.isEmpty { showWheel(files, at: point) }
        }
        if !down && wasDown {
            lastCompletedBoard = board.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.wheelPanel.orderOut(nil) }
        }
        wasDown = down
    }
    func showWheel(_ urls: [URL], at point: NSPoint) {
        wheelView.configure(urls)
        guard !urls.isEmpty else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main!
        let bounds = screen.visibleFrame
        let origin = NSPoint(x: max(bounds.minX + 5, min(point.x - 190, bounds.maxX - 385)), y: max(bounds.minY + 5, min(point.y - 190, bounds.maxY - 385)))
        wheelPanel.setFrameOrigin(origin); wheelPanel.orderFrontRegardless()
    }
    func copyPaths(_ urls: [URL]) {
        let paths = urls.map { $0.path }.joined(separator: "\n")
        guard PathClipboard.copy(urls) else { resultText.string = "路径复制失败，请重试。"; return }
        resultText.string = "已复制 \(urls.count) 个文件的完整路径（多个路径按行分隔）。\n" + paths
    }
    func run(_ urls: [URL], _ format: TargetFormat) {
        guard !isWorking else { return }
        isWorking = true
        resultText.string = "正在将 \(urls.count) 个文件转换为 \(format.label)…"
        let output = chosenDirectory
        queue.async {
            let result = ConversionEngine().convert(urls, to: format, outputDirectory: output)
            DispatchQueue.main.async {
                self.isWorking = false
                self.lastOutput = result.outputs.last
                var text = "完成：\(result.outputs.count) 个输出文件；失败：\(result.failures.count) 个输入文件。\n"
                text += result.outputs.map { "✓ " + $0.path }.joined(separator: "\n")
                if !result.failures.isEmpty { text += "\n" + result.failures.map { "✗ " + $0 }.joined(separator: "\n") }
                self.resultText.string = text

            }
        }
    }
    @objc func chooseFiles() {
        guard !isWorking else { return }
        let open = NSOpenPanel(); open.allowsMultipleSelection = true; open.canChooseDirectories = false
        guard open.runModal() == .OK else { return }
        let urls = open.urls; let formats = ConversionEngine.formats(for: urls)

        let choose = NSAlert(); choose.messageText = "选择操作"; choose.informativeText = "\(urls.count) 个文件；原文件会保留。"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
        formats.forEach { popup.addItem(withTitle: $0.label + " · " + ConversionEngine.detail($0, for: urls)) }
        popup.addItem(withTitle: "Copy Path · 复制完整路径")
        choose.accessoryView = popup; choose.addButton(withTitle: "执行"); choose.addButton(withTitle: "取消")
        if choose.runModal() == .alertFirstButtonReturn {
            if popup.indexOfSelectedItem == formats.count { copyPaths(urls) }
            else { run(urls, formats[popup.indexOfSelectedItem]) }
        }
    }
    func updateOutputLabel() { outputLabel.stringValue = "保存到：" + (chosenDirectory?.path ?? "原文件同级目录") }
    @objc func chooseOutput() {
        let choose = NSAlert(); choose.messageText = "保存转换结果"; choose.addButton(withTitle: "选择文件夹…"); choose.addButton(withTitle: "原文件旁"); choose.addButton(withTitle: "取消")
        let result = choose.runModal()
        if result == .alertFirstButtonReturn {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url { UserDefaults.standard.set(url.path, forKey: "outputDirectory") }
        } else if result == .alertSecondButtonReturn { UserDefaults.standard.removeObject(forKey: "outputDirectory") }
        updateOutputLabel()
    }
    @objc func showHome() { home.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func revealOutput() { if let file = lastOutput { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
    @objc func quit() { NSApp.terminate(nil) }
    func alert(_ message: String) { let a = NSAlert(); a.messageText = message; a.runModal() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showHome(); return true }
}
@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = App()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}
