import SwiftUI

/// Rounded-rect meter: dim track, solid fill, and an opacity-tinted
/// attention zone from `attention` to the end — the quiet cue for "past
/// here things need care". `ticks` drop 1pt hairline notches at those
/// fractions (e.g. a harder boundary inside the zone).
struct MeterBar: View {
    var fraction: Double
    var color: Color
    var attention: Double = 0.9
    var ticks: [Double] = []
    var height: CGFloat = 7
    /// What VoiceOver announces for the meter ("Memory used", "Claude Personal, 5-hour").
    var accessibilityLabel: String = "Level"
    /// Overrides the default "N percent" value when the meter needs more context.
    var accessibilityValue: String? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                if attention < 1 {
                    Capsule().fill(color.opacity(0.16))
                        .frame(width: w * (1 - attention))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Capsule().fill(color)
                    .frame(width: w * min(1, max(0, fraction)))
                    .animation(.easeInOut(duration: 0.5), value: fraction)
                ForEach(ticks, id: \.self) { tick in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color(nsColor: .labelColor).opacity(0.45))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: w * min(1, max(0, tick)) - 0.75)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "\(Int((min(1, max(0, fraction)) * 100).rounded())) percent")
    }
}
