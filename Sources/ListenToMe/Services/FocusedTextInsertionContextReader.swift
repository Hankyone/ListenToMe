import ApplicationServices
import Foundation

/// Reads a short local fragment around the selection plus accessibility labels
/// used to classify the field. Unsupported and secure fields return no context.
struct FocusedTextInsertionContextReader {
  private let maximumContextLength = 160

  func context(for target: TargetApplication) -> TextInsertionContext? {
    let systemWide = AXUIElementCreateSystemWide()
    var focusedObject: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        systemWide,
        kAXFocusedUIElementAttribute as CFString,
        &focusedObject
      ) == .success,
      let focusedObject
    else {
      return nil
    }

    let focused = focusedObject as! AXUIElement
    var focusedPID: pid_t = 0
    guard AXUIElementGetPid(focused, &focusedPID) == .success,
      focusedPID == target.processIdentifier
    else {
      return nil
    }

    if stringAttribute(kAXSubroleAttribute, from: focused)
      == kAXSecureTextFieldSubrole
    {
      return nil
    }

    guard let selection = selectedTextRange(from: focused) else {
      return nil
    }

    let beforeLength = min(selection.location, maximumContextLength)
    let before =
      string(
        in: CFRange(
          location: selection.location - beforeLength,
          length: beforeLength
        ),
        from: focused
      ) ?? ""

    let afterLocation = selection.location + selection.length
    let after = string(
      in: CFRange(location: afterLocation, length: 1),
      from: focused
    )?.first

    let field = FocusedTextFieldDescriptor(
      applicationName: target.name,
      bundleIdentifier: target.bundleIdentifier,
      role: stringAttribute(kAXRoleAttribute, from: focused),
      subrole: stringAttribute(kAXSubroleAttribute, from: focused),
      identifier: stringAttribute(kAXIdentifierAttribute, from: focused)
        ?? stringAttribute("AXDOMIdentifier", from: focused),
      title: stringAttribute(kAXTitleAttribute, from: focused),
      accessibilityDescription: stringAttribute(
        kAXDescriptionAttribute,
        from: focused
      ),
      help: stringAttribute(kAXHelpAttribute, from: focused),
      placeholder: stringAttribute("AXPlaceholderValue", from: focused)
    )

    return TextInsertionContext(
      characterAfterSelection: after,
      textBeforeSelection: before,
      field: field
    )
  }

  private func selectedTextRange(from element: AXUIElement) -> CFRange? {
    var rangeObject: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        &rangeObject
      ) == .success,
      let rangeObject,
      CFGetTypeID(rangeObject) == AXValueGetTypeID()
    else {
      return nil
    }

    let value = rangeObject as! AXValue
    guard AXValueGetType(value) == .cfRange else { return nil }

    var range = CFRange()
    guard AXValueGetValue(value, .cfRange, &range),
      range.location >= 0,
      range.length >= 0
    else {
      return nil
    }
    return range
  }

  private func string(
    in range: CFRange,
    from element: AXUIElement
  ) -> String? {
    guard range.location >= 0, range.length > 0 else { return "" }

    var mutableRange = range
    if let rangeValue = AXValueCreate(.cfRange, &mutableRange) {
      var stringObject: CFTypeRef?
      if AXUIElementCopyParameterizedAttributeValue(
        element,
        kAXStringForRangeParameterizedAttribute as CFString,
        rangeValue,
        &stringObject
      ) == .success,
        let value = stringObject as? String
      {
        return value
      }
    }

    guard let completeValue = stringAttribute(kAXValueAttribute, from: element)
    else {
      return nil
    }
    let text = completeValue as NSString
    guard range.location < text.length else { return nil }
    let safeRange = NSRange(
      location: range.location,
      length: min(range.length, text.length - range.location)
    )
    return text.substring(with: safeRange)
  }

  private func stringAttribute(
    _ attribute: String,
    from element: AXUIElement
  ) -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
      ) == .success
    else {
      return nil
    }
    return value as? String
  }
}
