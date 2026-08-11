import AppKit

enum StatusMenuIcon {
  private static let accent = NSColor(
    calibratedRed: 0.760,
    green: 0.375,
    blue: 0.270,
    alpha: 1
  )

  /// Idle: template waveform (menu bar paints it light).
  /// Active: orange waveform — not a black `record.circle.fill` blob.
  static func statusImage(isActive: Bool) -> NSImage? {
    image(
      systemName: "waveform",
      accessibilityDescription: isActive ? "Listening" : "ListenToMe",
      tint: isActive ? accent : nil
    )
  }

  /// Bake SF Symbols into a fixed bitmap. Template when `tint` is nil so the
  /// menu bar can adapt; colored (non-template) when tinted for the live state.
  static func image(
    systemName: String,
    accessibilityDescription: String,
    tint: NSColor? = nil
  ) -> NSImage? {
    guard
      let symbol = NSImage(
        systemSymbolName: systemName,
        accessibilityDescription: accessibilityDescription
      )
    else {
      return nil
    }

    let configured =
      symbol.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
      ) ?? symbol

    let size = NSSize(width: 16, height: 16)
    if let tint {
      return tintedSymbol(configured, size: size, tint: tint)
    }

    let baked = NSImage(size: size)
    baked.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    configured.draw(
      in: NSRect(origin: .zero, size: size),
      from: .zero,
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high]
    )
    baked.unlockFocus()
    baked.isTemplate = true
    return baked
  }

  private static func tintedSymbol(
    _ symbol: NSImage,
    size: NSSize,
    tint: NSColor
  ) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    let rect = NSRect(origin: .zero, size: size)
    symbol.draw(
      in: rect,
      from: .zero,
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high]
    )
    tint.set()
    rect.fill(using: .sourceAtop)
    image.unlockFocus()
    image.isTemplate = false
    return image
  }
}
