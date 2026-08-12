import AppKit
import Carbon
import Foundation

struct HotkeySpec: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case keyCombo
    case modifierHold
  }

  var kind: Kind
  var keyCode: UInt32
  var carbonModifiers: UInt32

  static let standard = HotkeySpec(
    kind: .keyCombo,
    keyCode: UInt32(kVK_Space),
    carbonModifiers: UInt32(controlKey | optionKey)
  )

  static func keyCombo(keyCode: UInt32, nsModifiers: NSEvent.ModifierFlags) -> HotkeySpec {
    HotkeySpec(
      kind: .keyCombo,
      keyCode: keyCode,
      carbonModifiers: carbonFlags(from: nsModifiers)
    )
  }

  static func modifierHold(keyCode: UInt32) -> HotkeySpec {
    HotkeySpec(kind: .modifierHold, keyCode: keyCode, carbonModifiers: 0)
  }

  static func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if flags.contains(.control) { carbon |= UInt32(controlKey) }
    if flags.contains(.option) { carbon |= UInt32(optionKey) }
    if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
    if flags.contains(.command) { carbon |= UInt32(cmdKey) }
    return carbon
  }

  var nsModifiers: NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
    if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
    if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
    if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
    return flags
  }

  /// The flag a modifier-hold key raises in `flagsChanged` events.
  var heldModifierFlag: NSEvent.ModifierFlags? {
    guard kind == .modifierHold else { return nil }
    switch Int(keyCode) {
    case kVK_Command, kVK_RightCommand: return .command
    case kVK_Option, kVK_RightOption: return .option
    case kVK_Control, kVK_RightControl: return .control
    case kVK_Shift, kVK_RightShift: return .shift
    case kVK_Function: return .function
    default: return nil
    }
  }

  var display: String {
    switch kind {
    case .keyCombo:
      return modifierSymbols + KeyGlyphs.name(for: keyCode)
    case .modifierHold:
      return "Hold " + KeyGlyphs.name(for: keyCode)
    }
  }

  /// Space-to-lock can't share the same physical key as the primary shortcut.
  var usesSpaceKey: Bool {
    keyCode == UInt32(kVK_Space)
  }

  private var modifierSymbols: String {
    var symbols = ""
    if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
    if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
    if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
    if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
    return symbols
  }
}

enum KeyGlyphs {
  private static let functionKeyCodes: Set<Int> = [
    kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
    kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
    kVK_F16, kVK_F17, kVK_F18, kVK_F19,
  ]

  static func isFunctionKey(_ keyCode: UInt32) -> Bool {
    functionKeyCodes.contains(Int(keyCode))
  }

  static func name(for keyCode: UInt32) -> String {
    if let special = specialNames[Int(keyCode)] {
      return special
    }
    if let translated = translate(keyCode), !translated.isEmpty {
      return translated.uppercased()
    }
    return "Key \(keyCode)"
  }

  private static let specialNames: [Int: String] = [
    kVK_Space: "Space",
    kVK_Return: "Return",
    kVK_Tab: "Tab",
    kVK_Delete: "Delete",
    kVK_ForwardDelete: "⌦",
    kVK_Escape: "Esc",
    kVK_Home: "Home",
    kVK_End: "End",
    kVK_PageUp: "Page Up",
    kVK_PageDown: "Page Down",
    kVK_LeftArrow: "←",
    kVK_RightArrow: "→",
    kVK_UpArrow: "↑",
    kVK_DownArrow: "↓",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
    kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
    kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
    kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    kVK_Command: "Left ⌘",
    kVK_RightCommand: "Right ⌘",
    kVK_Option: "Left ⌥",
    kVK_RightOption: "Right ⌥",
    kVK_Control: "Left ⌃",
    kVK_RightControl: "Right ⌃",
    kVK_Shift: "Left ⇧",
    kVK_RightShift: "Right ⇧",
    kVK_Function: "Globe (fn)",
  ]

  private static func translate(_ keyCode: UInt32) -> String? {
    guard
      let source = TISCopyCurrentKeyboardLayoutInputSource()?
        .takeRetainedValue(),
      let layoutPointer = TISGetInputSourceProperty(
        source,
        kTISPropertyUnicodeKeyLayoutData
      )
    else {
      return nil
    }

    let layoutData = Unmanaged<CFData>
      .fromOpaque(layoutPointer)
      .takeUnretainedValue() as Data

    return layoutData.withUnsafeBytes { rawBuffer -> String? in
      guard
        let layout = rawBuffer.bindMemory(to: UCKeyboardLayout.self)
          .baseAddress
      else {
        return nil
      }

      var deadKeyState: UInt32 = 0
      var characters = [UniChar](repeating: 0, count: 4)
      var length = 0
      let status = UCKeyTranslate(
        layout,
        UInt16(keyCode),
        UInt16(kUCKeyActionDisplay),
        0,
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        characters.count,
        &length,
        &characters
      )
      guard status == noErr, length > 0 else { return nil }
      return String(utf16CodeUnits: characters, count: length)
    }
  }
}
