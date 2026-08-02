import SwiftUI

struct WaveformView: View {
  let levels: [Float]
  var color: Color = AppTheme.accent
  var barWidth: CGFloat = 3
  var animated = false

  var body: some View {
    GeometryReader { proxy in
      let availableHeight = max(4, proxy.size.height)
      let count = max(1, levels.count)
      let slot = proxy.size.width / CGFloat(count)
      let resolvedWidth = min(barWidth, max(1.5, slot * 0.6))

      HStack(spacing: 0) {
        ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
          RoundedRectangle(cornerRadius: resolvedWidth / 2)
            .fill(color)
            .frame(
              width: resolvedWidth,
              height: max(
                resolvedWidth,
                availableHeight * CGFloat(min(1, max(0.04, level)))
              )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .animation(
        animated ? .easeOut(duration: 0.09) : nil,
        value: levels
      )
    }
    .accessibilityHidden(true)
  }
}

/// The brand mark: spoken sound arriving at a text cursor.
struct SpeechToCursorMark: View {
  var body: some View {
    HStack(spacing: 7) {
      WaveformView(
        levels: [0.22, 0.42, 0.72, 1, 0.72, 0.42, 0.22],
        barWidth: 3
      )
      .frame(width: 39, height: 28)

      Rectangle()
        .fill(AppTheme.primaryText)
        .frame(width: 2, height: 26)
        .overlay(alignment: .top) {
          Rectangle()
            .fill(AppTheme.primaryText)
            .frame(width: 8, height: 2)
        }
        .overlay(alignment: .bottom) {
          Rectangle()
            .fill(AppTheme.primaryText)
            .frame(width: 8, height: 2)
        }
    }
    .accessibilityLabel("ListenToMe")
  }
}

/// A slow idle swell for the waveform while the session opens: the bars are
/// alive but clearly not hearing yet. Runs on a timeline so the resting
/// state without motion is still a complete, visible waveform.
struct ConnectingWaveform: View {
  var color: Color = AppTheme.accentMuted
  var barWidth: CGFloat = 3

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      WaveformView(
        levels: (0..<24).map { index in
          let phase = time * 2.2 + Double(index) * 0.45
          return Float(0.10 + 0.08 * (1 + sin(phase)) / 2)
        },
        color: color,
        barWidth: barWidth
      )
    }
    .accessibilityHidden(true)
  }
}
