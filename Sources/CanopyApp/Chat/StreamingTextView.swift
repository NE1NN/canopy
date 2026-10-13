import AppKit
import CanopyCore

/// The block Claude is still writing, drawn by TextKit and updated in place. SwiftUI measured, drew, and scrolled to
/// the growing block again on every redraw, which cost about a third of a core while Claude wrote. It looks as
/// `MarkdownView` draws the block once it settles, so the handover does not show.
final class StreamingTextView: NSView, NSTextViewDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("chat-stream")
    /// The text is laid out in pages this tall, each its own text view, so a redraw repaints the last page's
    /// backing store rather than one as tall as the block.
    static let pageHeight: CGFloat = 80

    var openLink: (URL) -> Void = { _ in }
    private(set) var block: ChatBlock?
    private var lines: [ChatTextLine] = []
    /// The text last put in the storage, as built. TextKit swaps fonts in the storage for characters the system font
    /// lacks, such as emoji, so the storage itself never matches a newly built text.
    private var built = NSAttributedString()
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private var pages: [NSTextView] = []
    /// Each page's laid-out height, from the last `layoutPages`.
    private var pageHeights: [CGFloat] = []
    private let languageLabel = NSTextField(labelWithString: "")
    /// A code block's box, a quote's bar, or a rule, in a view of its own so a paragraph's row draws nothing but text.
    private let decoration = Decoration()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        storage.addLayoutManager(manager)
        decoration.isHidden = true
        addSubview(decoration)
        addPage()
        languageLabel.font = ChatStyle.AppKit.codeLabel
        languageLabel.textColor = ChatStyle.AppKit.tertiaryText
        languageLabel.isHidden = true
        addSubview(languageLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private func addPage() {
        let container = NSTextContainer(size: CGSize(width: 1, height: Self.pageHeight))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        manager.addTextContainer(container)
        let page = NSTextView(frame: .zero, textContainer: container)
        page.isEditable = false
        page.isSelectable = true
        page.drawsBackground = false
        page.textContainerInset = .zero
        page.isVerticallyResizable = false
        page.isHorizontallyResizable = false
        page.clipsToBounds = true
        page.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        page.delegate = self
        addSubview(page, positioned: .above, relativeTo: decoration)
        pages.append(page)
    }

    /// Lays the text out at `width` across as many pages as it needs, and returns its height.
    private func layoutPages(width: CGFloat) -> CGFloat {
        let size = CGSize(width: max(width, Self.minimumWidth), height: Self.pageHeight)
        for page in pages where page.textContainer?.size != size { page.textContainer?.size = size }
        // Text that got shorter, or a wider row, leaves pages with nothing on them.
        while pages.count > 1, let last = pages.last?.textContainer, manager.glyphRange(for: last).length == 0 {
            manager.removeTextContainer(at: manager.textContainers.count - 1)
            pages.removeLast().removeFromSuperview()
        }
        // Each page is filled in turn; one that takes nothing, as a line taller than a page would, ends it.
        while let last = pages.last?.textContainer {
            let laidOut = manager.glyphRange(for: last)
            guard laidOut.length > 0, NSMaxRange(laidOut) < manager.numberOfGlyphs else { break }
            addPage()
            pages.last?.textContainer?.size = size
        }
        guard storage.length > 0 else {
            pageHeights = pages.map { _ in 0 }
            return 0
        }
        pageHeights = pages.map { page in page.textContainer.map { manager.usedRect(for: $0).height } ?? 0 }
        return pageHeights.reduce(0, +)
    }

    /// Narrower than this, a layout pass has not given the row its width yet, and text would break a letter a line.
    static let minimumWidth: CGFloat = 40

    /// Changes the text in place, so TextKit lays out only what is new rather than SwiftUI making a new row.
    func show(_ block: ChatBlock) {
        guard block != self.block else { return }
        self.block = block
        lines = ChatTextLines.lines(for: block)
        let text = StreamingText.attributed(lines)
        StreamingText.replace(storage, was: built, with: text)
        built = text
        if case .code(let language?, _) = block {
            languageLabel.stringValue = language
            languageLabel.isHidden = false
        } else {
            languageLabel.isHidden = true
        }
        needsLayout = true
    }

    /// The row's height at `width`, with the space below it that every row has.
    static func height(of block: ChatBlock, width: CGFloat) -> CGFloat {
        let lines = ChatTextLines.lines(for: block)
        let text = StreamingText.attributed(lines)
        let parts = Parts(block: block, lines: lines, width: width) { textWidth in
            StreamingText.measurer.height(of: text, width: textWidth)
        }
        return ceil(parts.height) + ChatStyle.rowSpacing
    }

    /// The row's height at `width`, from this view's own layout, which drawing then reuses.
    func rowHeight(width: CGFloat) -> CGFloat {
        guard let block else { return 1 }
        let parts = Parts(block: block, lines: lines, width: width) { layoutPages(width: $0) }
        return ceil(parts.height) + ChatStyle.rowSpacing
    }

    override func layout() {
        super.layout()
        guard let block else { return }
        let parts = Parts(block: block, lines: lines, width: bounds.width, scale: window?.backingScaleFactor ?? 2) {
            layoutPages(width: $0)
        }
        var y = parts.text.minY
        for (page, height) in zip(pages, pageHeights) {
            page.frame = CGRect(x: parts.text.minX, y: y, width: parts.text.width, height: height)
            y += height
        }
        if !languageLabel.isHidden, let box = parts.decoration {
            languageLabel.sizeToFit()
            let size = languageLabel.frame.size
            languageLabel.frame = CGRect(
                x: box.maxX - 4 - size.width, y: box.minY + 6, width: size.width, height: size.height)
        }
        decoration.isHidden = parts.decoration == nil
        if let rect = parts.decoration {
            decoration.shape = Decoration.Shape(block)
            decoration.frame = rect
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        openLink(url)
        return true
    }

    private final class Decoration: NSView {
        enum Shape {
            case box, bar, line

            init(_ block: ChatBlock) {
                switch block {
                case .code: self = .box
                case .quote: self = .bar
                default: self = .line
                }
            }
        }

        var shape = Shape.line {
            didSet { if shape != oldValue { needsDisplay = true } }
        }

        override func draw(_ dirtyRect: NSRect) {
            switch shape {
            case .box:
                let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6.5, yRadius: 6.5)
                ChatStyle.AppKit.codeFill.setFill()
                box.fill()
                ChatStyle.AppKit.cardBorder.setStroke()
                box.lineWidth = 1
                box.stroke()
            case .bar:
                ChatStyle.AppKit.cardBorder.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
            case .line:
                ChatStyle.AppKit.cardBorder.setFill()
                bounds.fill()
            }
        }
    }

    /// Where a block's text and its box, bar, or rule go in a row `width` wide, as `ChatRowView` and `MarkdownView`
    /// place them.
    private struct Parts {
        var text: CGRect
        var decoration: CGRect?
        var height: CGFloat

        init(
            block: ChatBlock, lines: [ChatTextLine], width: CGFloat, scale: CGFloat = 2,
            textHeight: (CGFloat) -> CGFloat
        ) {
            let columnWidth = max(1, min(ChatStyle.columnWidth, width - 2 * ChatStyle.sidePadding))
            // Centered on the pixel grid, as SwiftUI centers the column.
            let x = ((width - columnWidth) / 2 * scale).rounded() / scale
            let top = lines.first?.spacingBefore ?? 0
            switch block {
            case .code:
                let height = textHeight(.greatestFiniteMagnitude)
                // Clipped at the box's border, as SwiftUI's scroll view clips it, rather than at the padding.
                text = CGRect(x: x + 12, y: 9, width: max(1, columnWidth - 13), height: height)
                decoration = CGRect(x: x, y: 0, width: columnWidth, height: height + 18)
                self.height = height + 18
            case .quote:
                let height = textHeight(max(1, columnWidth - 13))
                text = CGRect(x: x + 13, y: top, width: max(1, columnWidth - 13), height: height)
                decoration = CGRect(x: x, y: 0, width: 3, height: top + height)
                self.height = top + height
            case .rule:
                text = .zero
                decoration = CGRect(x: x, y: 4, width: columnWidth, height: 1)
                height = 9
            default:
                let height = textHeight(columnWidth)
                text = CGRect(x: x, y: top, width: columnWidth, height: height)
                decoration = nil
                self.height = top + height
            }
        }
    }
}

/// Claude's text as TextKit draws it, in `MarkdownView`'s fonts, colors, and spacing.
@MainActor
enum StreamingText {
    /// Measures rows before their views exist.
    static let measurer = Measurer()

    @MainActor
    final class Measurer {
        private let storage = NSTextStorage()
        private let manager = NSLayoutManager()
        private let container = NSTextContainer()

        init() {
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }

        func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
            storage.setAttributedString(text)
            container.size = CGSize(
                width: max(width, StreamingTextView.minimumWidth), height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            return text.length > 0 ? manager.usedRect(for: container).height : 0
        }
    }

    /// Replaces only what changed from the first difference on, so TextKit keeps the layout of the text before it.
    /// `old` is the text the storage was last given, as it was built.
    static func replace(_ storage: NSTextStorage, was old: NSAttributedString, with text: NSAttributedString) {
        var common = (old.string.commonPrefix(with: text.string, options: .literal) as NSString).length
        // Markdown that closes, such as a second `**`, restyles what came before it.
        if common > 0,
            !old.attributedSubstring(from: NSRange(location: 0, length: common)).isEqual(
                to: text.attributedSubstring(from: NSRange(location: 0, length: common)))
        {
            common = 0
        }
        common = min(common, storage.length)
        let length = text.length
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: common, length: storage.length - common),
            with: text.attributedSubstring(from: NSRange(location: common, length: length - common)))
        storage.endEditing()
    }

    static func attributed(_ lines: [ChatTextLine]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        // Where each list depth's text starts, which a wide number like "10." pushes along, as SwiftUI's
        // HStack does.
        var indents: [CGFloat] = [0]
        var previousSpacing: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let base = font(for: line.style)
            let color = line.quoted ? ChatStyle.AppKit.secondaryText : ChatStyle.AppKit.primaryText
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = line.style == .code ? 3 : ChatStyle.textLineSpacing
            // TextKit also puts line spacing below a paragraph's last line, where SwiftUI's stacks put none.
            paragraph.paragraphSpacingBefore = index == 0 ? 0 : max(0, line.spacingBefore - previousSpacing)
            previousSpacing = paragraph.lineSpacing
            // SwiftUI rounds a line's height up, and TextKit to the nearest point.
            paragraph.minimumLineHeight = ceil(base.ascender - base.descender + base.leading)
            paragraph.lineBreakMode = line.style == .code ? .byClipping : .byWordWrapping
            var prefix = ""
            if line.depth > 0 {
                while indents.count <= line.depth { indents.append((indents.last ?? 0) + listIndent(markerWidth: 0)) }
                let parent = indents[line.depth - 1]
                if let marker = line.marker {
                    let markerWidth = ceil(
                        (marker as NSString).size(withAttributes: [.font: ChatStyle.AppKit.text]).width)
                    let column = max(markerColumn, markerWidth)
                    indents[line.depth] = parent + listIndent(markerWidth: markerWidth)
                    paragraph.tabStops = [
                        NSTextTab(textAlignment: .right, location: parent + listPadding + column),
                        NSTextTab(textAlignment: .left, location: indents[line.depth]),
                    ]
                    paragraph.firstLineHeadIndent = parent
                    prefix = "\t\(marker)\t"
                } else {
                    paragraph.firstLineHeadIndent = indents[line.depth]
                }
                paragraph.headIndent = indents[line.depth]
                indents.removeSubrange((line.depth + 1)...)
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: base, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            let start = result.length
            if !prefix.isEmpty {
                var markerAttributes = attributes
                markerAttributes[.font] = ChatStyle.AppKit.text
                markerAttributes[.foregroundColor] = ChatStyle.AppKit.secondaryText
                result.append(NSAttributedString(string: prefix, attributes: markerAttributes))
            }
            for run in line.text.runs {
                let string = String(line.text[run.range].characters)
                var runAttributes = attributes
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.code) {
                        runAttributes[.font] = ChatStyle.AppKit.mono
                        runAttributes[.backgroundColor] = ChatStyle.AppKit.inlineCode
                        runAttributes[.foregroundColor] = ChatStyle.AppKit.strongText
                    } else {
                        runAttributes[.font] = styled(
                            base, bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized))
                    }
                    if intent.contains(.strikethrough) {
                        runAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    }
                }
                if let link = run.link { runAttributes[.link] = link }
                result.append(NSAttributedString(string: string, attributes: runAttributes))
            }
            // A code block's lines and a hard line break start paragraphs of their own in TextKit, which go on from
            // where the text is indented, with no space above.
            let lineRange = NSRange(location: start, length: result.length - start)
            let newline = (result.string as NSString).range(of: "\n", options: .literal, range: lineRange)
            if newline.location != NSNotFound, let continuation = paragraph.mutableCopy() as? NSMutableParagraphStyle {
                continuation.firstLineHeadIndent = paragraph.headIndent
                continuation.paragraphSpacingBefore = 0
                result.addAttribute(
                    .paragraphStyle, value: continuation,
                    range: NSRange(location: NSMaxRange(newline), length: NSMaxRange(lineRange) - NSMaxRange(newline)))
            }
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return result
    }

    /// `MarkdownView`'s list: 4 points in, the marker right-aligned in at least 12, then 7 to the text.
    private static let listPadding: CGFloat = 4
    private static let markerColumn: CGFloat = 12
    private static let markerGap: CGFloat = 7

    private static func listIndent(markerWidth: CGFloat) -> CGFloat {
        listPadding + max(markerColumn, markerWidth) + markerGap
    }

    private static func font(for style: ChatTextLine.Style) -> NSFont {
        switch style {
        case .body: ChatStyle.AppKit.text
        case .heading(let level): ChatStyle.AppKit.heading(level)
        case .code: ChatStyle.AppKit.mono
        }
    }

    private static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var styled = bold ? NSFont.systemFont(ofSize: font.pointSize, weight: .semibold) : font
        if italic {
            styled =
                NSFont(descriptor: styled.fontDescriptor.withSymbolicTraits(.italic), size: styled.pointSize) ?? styled
        }
        return styled
    }
}
