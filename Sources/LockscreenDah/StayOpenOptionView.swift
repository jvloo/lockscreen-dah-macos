import AppKit

/// Menu-item row backed by a custom view: clicking applies the option and
/// keeps the menu open (a plain NSMenuItem always dismisses on click). The
/// menu still closes on hover-away or clicking elsewhere, as usual.
final class StayOpenOptionView: NSView {
    enum Layout {
        /// Checkmark gutter like a native checkable menu (all-custom submenus).
        case standard
        /// No gutter — title aligns with native, non-checkable sibling rows;
        /// the checkmark squeezes into the leading padding.
        case tight
    }

    var onClick: (() -> Void)?

    var isChecked = false { didSet { needsDisplay = true } }
    private var isHighlighted = false { didSet { needsDisplay = true } }

    private let title: String
    private let indent: Bool
    private let layout: Layout
    private static let font = NSFont.menuFont(ofSize: 13)

    /// Draw with the same vibrant blending as native menu text — without this
    /// the labels look washed out next to real menu items.
    override var allowsVibrancy: Bool { true }

    init(title: String, indent: Bool = false, layout: Layout = .standard) {
        self.title = title
        self.indent = indent
        self.layout = layout
        let textWidth = (title as NSString)
            .size(withAttributes: [.font: Self.font]).width
        super.init(frame: NSRect(x: 0, y: 0, width: max(220, textWidth + 64), height: 22))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
    }

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            let highlight = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 5, dy: 1),
                xRadius: 4, yRadius: 4
            )
            NSColor.controlAccentColor.setFill()
            highlight.fill()
        }

        let textColor: NSColor = isHighlighted ? .white : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: textColor,
        ]

        let checkX: CGFloat
        let titleX: CGFloat
        switch layout {
        case .standard:
            checkX = 11 + (indent ? 12 : 0)
            titleX = checkX + 18
        case .tight:
            // Title aligns with native rows; the checkmark sits at the
            // trailing end like a toggle indicator.
            checkX = bounds.width - 24
            titleX = 15 + (indent ? 12 : 0)
        }
        if isChecked {
            ("✓" as NSString).draw(
                at: NSPoint(x: checkX, y: 3),
                withAttributes: attributes
            )
        }
        (title as NSString).draw(
            at: NSPoint(x: titleX, y: 3),
            withAttributes: attributes
        )
    }
}
