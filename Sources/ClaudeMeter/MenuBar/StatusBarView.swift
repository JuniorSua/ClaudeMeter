import AppKit

/// Custom status item content: symbol + usage text + tiny fullness meter.
/// Hit testing is disabled so clicks fall through to the status button.
final class StatusBarView: NSView {
    enum Content: Equatable {
        /// Single line of text with an optional trailing meter.
        case single(text: String, percentage: Double?)
        /// Two tiny stacked percentages (session over weekly). No meter —
        /// each value is tinted by its own fullness color when elevated.
        case stacked(MenuBarFormatter.StackedDisplay)
    }

    var content: Content = .single(text: "◆ …", percentage: nil) {
        didSet {
            if content != oldValue { refresh() }
        }
    }

    private let meterWidth: CGFloat = 40
    private let meterHeight: CGFloat = 4
    private let padding: CGFloat = 6
    private let stackedPadding: CGFloat = 4
    private let meterGap: CGFloat = 6

    private func singleAttributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ])
    }

    private func stackedAttributed(_ text: String, percent: Double) -> NSAttributedString {
        // Keep the menu bar monochrome until a limit is actually filling up.
        let color: NSColor = percent >= 60 ? MeterColor.nsColor(for: percent) : .labelColor
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: color
        ])
    }

    override var intrinsicContentSize: NSSize {
        switch content {
        case .single(let text, let percentage):
            let textWidth = ceil(singleAttributed(text).size().width)
            var width = padding + textWidth + padding
            if percentage != nil {
                width += meterGap + meterWidth
            }
            return NSSize(width: width, height: NSStatusBar.system.thickness)
        case .stacked(let display):
            let top = stackedAttributed(display.topText, percent: display.topPercent).size().width
            let bottom = stackedAttributed(display.bottomText, percent: display.bottomPercent).size().width
            let width = stackedPadding + ceil(max(top, bottom)) + stackedPadding
            return NSSize(width: width, height: NSStatusBar.system.thickness)
        }
    }

    private func refresh() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case .single(let text, let percentage):
            drawSingle(text: text, percentage: percentage)
        case .stacked(let display):
            drawStacked(display)
        }
    }

    private func drawSingle(text: String, percentage: Double?) {
        let string = singleAttributed(text)
        let textSize = string.size()
        let textY = (bounds.height - textSize.height) / 2
        string.draw(at: NSPoint(x: padding, y: textY))

        guard let percentage else { return }
        let fraction = CGFloat(max(0, min(percentage, 100)) / 100)
        let meterX = padding + ceil(textSize.width) + meterGap
        let meterY = (bounds.height - meterHeight) / 2
        let track = NSRect(x: meterX, y: meterY, width: meterWidth, height: meterHeight)

        let radius = meterHeight / 2
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        if fraction > 0 {
            let fillWidth = max(meterHeight, meterWidth * fraction)
            let fill = NSRect(x: meterX, y: meterY, width: fillWidth, height: meterHeight)
            MeterColor.nsColor(for: percentage).setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }
    }

    private func drawStacked(_ display: MenuBarFormatter.StackedDisplay) {
        let top = stackedAttributed(display.topText, percent: display.topPercent)
        let bottom = stackedAttributed(display.bottomText, percent: display.bottomPercent)
        let topSize = top.size()
        let bottomSize = bottom.size()
        let lineGap: CGFloat = 0
        let totalHeight = topSize.height + lineGap + bottomSize.height
        let startY = (bounds.height - totalHeight) / 2

        // AppKit's unflipped coordinates: bottom line first.
        bottom.draw(at: NSPoint(x: (bounds.width - bottomSize.width) / 2, y: startY))
        top.draw(at: NSPoint(x: (bounds.width - topSize.width) / 2, y: startY + bottomSize.height + lineGap))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
