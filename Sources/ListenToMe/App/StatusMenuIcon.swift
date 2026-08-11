import AppKit

enum StatusMenuIcon {
  /// Bake SF Symbols into a fixed template bitmap. macOS 26/27 hide raw
  /// symbol images on `NSMenuItem` by default; a non-symbol rep stays visible.
  static func image(systemName: String, accessibilityDescription: String) -> NSImage? {
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
    let baked = NSImage(size: size)
    baked.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    let drawRect = NSRect(origin: .zero, size: size)
    configured.draw(
      in: drawRect,
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
}
