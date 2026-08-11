import SwiftUI

/// One warm, ink-on-clay system. The palette is deliberately narrow:
/// charcoal surfaces warmed toward umber, bone text, and a single terracotta
/// accent reserved for live, interactive moments. Depth comes from tone and
/// self-colored edges, not drawn borders or black blooms.
enum AppTheme {
  static let background = Color(red: 0.078, green: 0.072, blue: 0.066)
  static let sidebar = Color(red: 0.098, green: 0.090, blue: 0.082)
  static let surface = Color(red: 0.122, green: 0.112, blue: 0.102)
  static let raisedSurface = Color(red: 0.162, green: 0.148, blue: 0.132)
  static let edge = Color(red: 0.235, green: 0.215, blue: 0.192)

  static let accent = Color(red: 0.760, green: 0.375, blue: 0.270)
  static let accentMuted = Color(red: 0.520, green: 0.275, blue: 0.212)

  static let primaryText = Color(red: 0.952, green: 0.928, blue: 0.884)
  static let secondaryText = Color(red: 0.690, green: 0.650, blue: 0.595)
  static let faintText = Color(red: 0.480, green: 0.450, blue: 0.408)
  static let success = Color(red: 0.545, green: 0.700, blue: 0.510)

  /// A faint top-light wash for raised plates, so edges read as a lip
  /// catching light instead of a drawn outline.
  static let plateSheen = LinearGradient(
    colors: [
      Color.white.opacity(0.055),
      Color.white.opacity(0.012),
      Color.clear,
    ],
    startPoint: .top,
    endPoint: .bottom
  )
}

/// The house silhouette: a plate with opposing chamfered corners. Every
/// contained control in the app shares this cut.
struct ChamferedPlate: Shape {
  var cut: CGFloat = 10

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
    path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cut))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
    path.closeSubpath()
    return path
  }
}

/// Primary action: terracotta plate, chamfered. State changes are tonal;
/// the button never moves.
struct RecordActionButtonStyle: ButtonStyle {
  var isRecording = false

  func makeBody(configuration: Configuration) -> some View {
    StyledBody(configuration: configuration, isRecording: isRecording)
  }

  private struct StyledBody: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: Configuration
    let isRecording: Bool
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(
          isRecording
            ? AppTheme.primaryText
            : Color(red: 0.10, green: 0.06, blue: 0.045)
        )
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .background(
          ChamferedPlate(cut: 7)
            .fill(fillColor)
        )
        .overlay(
          ChamferedPlate(cut: 7)
            .stroke(
              isRecording ? AppTheme.edge : Color.white.opacity(0.14),
              lineWidth: 1
            )
        )
        .opacity(isEnabled ? 1 : 0.38)
        .onHover { hovering in
          isHovering = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var fillColor: Color {
      if isRecording {
        return configuration.isPressed
          ? AppTheme.raisedSurface.opacity(0.7)
          : AppTheme.raisedSurface
      }
      if configuration.isPressed {
        return AppTheme.accentMuted
      }
      return isHovering
        ? AppTheme.accent.opacity(0.88)
        : AppTheme.accent
    }
  }
}

/// Text entry on the house plate: quiet edge at rest, terracotta edge while
/// focused. Replaces the system rounded border and its blue focus ring.
struct ThemedTextField: View {
  let placeholder: String
  @Binding var text: String
  var isSecure = false
  var onSubmit: (() -> Void)?
  var onEditingEnded: (() -> Void)?
  @FocusState private var isFocused: Bool

  var body: some View {
    Group {
      if isSecure {
        SecureField(placeholder, text: $text)
      } else {
        TextField(placeholder, text: $text)
      }
    }
    .textFieldStyle(.plain)
    .font(.system(size: 13))
    .foregroundStyle(AppTheme.primaryText)
    .focused($isFocused)
    .focusEffectDisabled()
    .onSubmit {
      onSubmit?()
    }
    .onChange(of: isFocused) { _, focused in
      if !focused {
        onEditingEnded?()
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
      ChamferedPlate(cut: 7)
        .fill(AppTheme.background)
    )
    .overlay(
      ChamferedPlate(cut: 7)
        .stroke(
          isFocused
            ? AppTheme.accent.opacity(0.75)
            : AppTheme.edge.opacity(0.6),
          lineWidth: 1
        )
    )
    .animation(.easeOut(duration: 0.12), value: isFocused)
  }
}

/// Quiet secondary action: bare label that warms on hover. No box, no
/// underline animation, no movement.
struct QuietButtonStyle: ButtonStyle {
  var isDestructive = false

  func makeBody(configuration: Configuration) -> some View {
    StyledBody(configuration: configuration, isDestructive: isDestructive)
  }

  private struct StyledBody: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: Configuration
    let isDestructive: Bool
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(labelColor)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onHover { hovering in
          isHovering = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var labelColor: Color {
      if isDestructive {
        return isHovering || configuration.isPressed
          ? AppTheme.accent
          : AppTheme.secondaryText
      }
      return isHovering || configuration.isPressed
        ? AppTheme.primaryText
        : AppTheme.secondaryText
    }
  }
}
