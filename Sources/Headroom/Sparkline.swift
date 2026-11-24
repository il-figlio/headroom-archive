import SwiftUI

/// Micro sparkline: a rounded polyline across the frame's width with a
/// translucent fill underneath. Values are normalized to the series' own
/// min/max; an empty series draws nothing, a single or constant series
/// draws a flat midline so the shape still reads as a baseline.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let points = normalized(in: geo.size)
            if !points.isEmpty {
                area(points, in: geo.size)
                    .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                line(points)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                if let last = points.last {
                    Circle().fill(color)
                        .frame(width: lineWidth + 2, height: lineWidth + 2)
                        .position(last)
                }
            }
        }
    }

    /// Maps the series into view coordinates, inset by the stroke width so
    /// caps and peaks never clip against the edge.
    private func normalized(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let low = values.min() ?? 0
        let range = (values.max() ?? 0) - low
        let inset = lineWidth + 1
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        let step = values.count > 1 ? width / CGFloat(values.count - 1) : 0
        return values.enumerated().map { index, value in
            let fraction = range > 0 ? (value - low) / range : 0.5
            return CGPoint(x: values.count > 1 ? inset + step * CGFloat(index) : size.width / 2,
                           y: inset + height * (1 - fraction))
        }
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    /// Closed silhouette under the polyline for the translucent fill.
    private func area(_ points: [CGPoint], in size: CGSize) -> Path {
        var path = line(points)
        path.addLine(to: CGPoint(x: points.last?.x ?? size.width, y: size.height))
        path.addLine(to: CGPoint(x: points.first?.x ?? 0, y: size.height))
        path.closeSubpath()
        return path
    }
}
