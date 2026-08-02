import AVFoundation
import ApplicationServices
import Foundation

@MainActor
final class PermissionService: ObservableObject {
  @Published private(set) var microphoneGranted = false
  @Published private(set) var accessibilityGranted = false

  init() {
    refresh()
  }

  func refresh() {
    microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    accessibilityGranted = AXIsProcessTrusted()
  }

  func requestMicrophone() async -> Bool {
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    refresh()
    return granted
  }

  func requestAccessibility() {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    refresh()
  }
}
