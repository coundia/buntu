import Foundation
import CoreGraphics

public enum MultiViewLayoutKind: String, CaseIterable, Identifiable, Sendable {
    case auto
    case sideBySide
    case grid2x2
    case onePlusThree

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .sideBySide: return "Côte à côte (1+1)"
        case .grid2x2: return "Grille (2×2)"
        case .onePlusThree: return "Focus (1+3)"
        }
    }

    public var iconName: String {
        switch self {
        case .auto: return "rectangle.3.group"
        case .sideBySide: return "rectangle.split.2x1"
        case .grid2x2: return "square.grid.2x2"
        case .onePlusThree: return "rectangle.inset.filled.and.cursorarrow"
        }
    }
}

public struct MultiViewLayout: Sendable {
    /// Pure calculation of tile frames within `containerSize` for a given tile count and layout.
    public static func calculateFrames(
        count: Int,
        in containerSize: CGSize,
        layout: MultiViewLayoutKind = .auto,
        activeTileIndex: Int = 0,
        gutter: CGFloat = 4
    ) -> [CGRect] {
        guard count > 0, containerSize.width > 0, containerSize.height > 0 else {
            return []
        }

        if count == 1 {
            return [CGRect(origin: .zero, size: containerSize)]
        }

        let effectiveLayout = resolveLayout(layout, forCount: count)

        switch effectiveLayout {
        case .sideBySide:
            return calculateSideBySide(count: count, in: containerSize, gutter: gutter)
        case .grid2x2:
            return calculateGrid2x2(count: count, in: containerSize, gutter: gutter)
        case .onePlusThree:
            return calculateOnePlusThree(count: count, in: containerSize, activeIndex: activeTileIndex, gutter: gutter)
        case .auto:
            return calculateGrid2x2(count: count, in: containerSize, gutter: gutter)
        }
    }

    private static func resolveLayout(_ kind: MultiViewLayoutKind, forCount count: Int) -> MultiViewLayoutKind {
        if kind != .auto {
            if kind == .onePlusThree && count <= 2 {
                return .sideBySide
            }
            return kind
        }
        switch count {
        case 2:
            return .sideBySide
        case 3, 4:
            return .grid2x2
        default:
            return .grid2x2
        }
    }

    private static func calculateSideBySide(count: Int, in size: CGSize, gutter: CGFloat) -> [CGRect] {
        let isLandscape = size.width >= size.height
        if isLandscape {
            let totalGutter = gutter * CGFloat(count - 1)
            let tileWidth = max(0, (size.width - totalGutter) / CGFloat(count))
            return (0..<count).map { i in
                let x = CGFloat(i) * (tileWidth + gutter)
                return CGRect(x: x, y: 0, width: tileWidth, height: size.height)
            }
        } else {
            let totalGutter = gutter * CGFloat(count - 1)
            let tileHeight = max(0, (size.height - totalGutter) / CGFloat(count))
            return (0..<count).map { i in
                let y = CGFloat(i) * (tileHeight + gutter)
                return CGRect(x: 0, y: y, width: size.width, height: tileHeight)
            }
        }
    }

    private static func calculateGrid2x2(count: Int, in size: CGSize, gutter: CGFloat) -> [CGRect] {
        let colWidth = max(0, (size.width - gutter) / 2)
        let rowHeight = max(0, (size.height - gutter) / 2)

        if count == 2 {
            return calculateSideBySide(count: 2, in: size, gutter: gutter)
        }

        if count == 3 {
            let top0 = CGRect(x: 0, y: 0, width: colWidth, height: rowHeight)
            let top1 = CGRect(x: colWidth + gutter, y: 0, width: colWidth, height: rowHeight)
            let bottomWidth = colWidth
            let bottomX = (size.width - bottomWidth) / 2
            let bottom0 = CGRect(x: bottomX, y: rowHeight + gutter, width: bottomWidth, height: rowHeight)
            return [top0, top1, bottom0]
        }

        let t0 = CGRect(x: 0, y: 0, width: colWidth, height: rowHeight)
        let t1 = CGRect(x: colWidth + gutter, y: 0, width: colWidth, height: rowHeight)
        let t2 = CGRect(x: 0, y: rowHeight + gutter, width: colWidth, height: rowHeight)
        let t3 = CGRect(x: colWidth + gutter, y: rowHeight + gutter, width: colWidth, height: rowHeight)
        return [t0, t1, t2, t3]
    }

    private static func calculateOnePlusThree(count: Int, in size: CGSize, activeIndex: Int, gutter: CGFloat) -> [CGRect] {
        let isLandscape = size.width >= size.height
        let active = min(max(0, activeIndex), count - 1)
        let otherCount = count - 1

        if isLandscape {
            let mainWidth = max(0, (size.width - gutter) * 0.68)
            let sideWidth = max(0, size.width - mainWidth - gutter)
            let mainFrame = CGRect(x: 0, y: 0, width: mainWidth, height: size.height)

            let sideGutterTotal = gutter * CGFloat(max(0, otherCount - 1))
            let sideHeight = otherCount > 0 ? max(0, (size.height - sideGutterTotal) / CGFloat(otherCount)) : size.height

            var result: [CGRect] = Array(repeating: .zero, count: count)
            result[active] = mainFrame

            var currentSideIndex = 0
            for i in 0..<count {
                if i == active { continue }
                let y = CGFloat(currentSideIndex) * (sideHeight + gutter)
                result[i] = CGRect(x: mainWidth + gutter, y: y, width: sideWidth, height: sideHeight)
                currentSideIndex += 1
            }
            return result
        } else {
            let mainHeight = max(0, (size.height - gutter) * 0.60)
            let bottomHeight = max(0, size.height - mainHeight - gutter)
            let mainFrame = CGRect(x: 0, y: 0, width: size.width, height: mainHeight)

            let bottomGutterTotal = gutter * CGFloat(max(0, otherCount - 1))
            let bottomWidth = otherCount > 0 ? max(0, (size.width - bottomGutterTotal) / CGFloat(otherCount)) : size.width

            var result: [CGRect] = Array(repeating: .zero, count: count)
            result[active] = mainFrame

            var currentBottomIndex = 0
            for i in 0..<count {
                if i == active { continue }
                let x = CGFloat(currentBottomIndex) * (bottomWidth + gutter)
                result[i] = CGRect(x: x, y: mainHeight + gutter, width: bottomWidth, height: bottomHeight)
                currentBottomIndex += 1
            }
            return result
        }
    }
}
