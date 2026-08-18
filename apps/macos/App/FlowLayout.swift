import SwiftUI

/// Lays out subviews left-to-right and wraps to the next row when they no longer
/// fit the proposed width. Every child keeps its ideal size, so button labels are
/// never truncated by a fixed-width toolbar.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            guard size.width.isFinite, size.height.isFinite else { continue }
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widestRow = max(widestRow, x)
        }
        return CGSize(width: proposal.width ?? widestRow, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var rows: [[(index: Int, size: CGSize)]] = []
        var current: [(index: Int, size: CGSize)] = []
        var rowWidth: CGFloat = 0
        for (subviewIndex, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            guard size.width.isFinite, size.height.isFinite else { continue }
            if rowWidth + size.width > bounds.width, !current.isEmpty {
                rows.append(current)
                current = []
                rowWidth = 0
            }
            current.append((index: subviewIndex, size: size))
            rowWidth += size.width + spacing
        }
        if !current.isEmpty { rows.append(current) }

        var y = bounds.minY
        for row in rows {
            let rowContentWidth = row.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, row.count - 1))
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - rowContentWidth
            default: x = bounds.minX
            }
            var rowHeight: CGFloat = 0
            for item in row {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + spacing
                rowHeight = max(rowHeight, item.size.height)
            }
            y += rowHeight + spacing
        }
    }
}
