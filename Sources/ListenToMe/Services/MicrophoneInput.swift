import CoreAudio
import Foundation

struct MicrophoneInput: Identifiable, Hashable, Sendable {
  /// Empty UID means “follow the system default input”.
  static let systemDefaultID = ""

  let id: String
  let name: String
  let deviceID: AudioDeviceID

  var isSystemDefault: Bool { id == Self.systemDefaultID }

  static func systemDefault() -> MicrophoneInput {
    MicrophoneInput(
      id: systemDefaultID,
      name: "System Default",
      deviceID: 0
    )
  }
}

enum MicrophoneInputCatalog {
  static func listInputs() -> [MicrophoneInput] {
    var devices = [MicrophoneInput.systemDefault()]
    for deviceID in allDeviceIDs() where inputChannelCount(deviceID) > 0 {
      let uid = stringProperty(
        deviceID,
        selector: kAudioDevicePropertyDeviceUID
      ) ?? "device-\(deviceID)"
      let name =
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
        ?? "Microphone \(deviceID)"
      devices.append(
        MicrophoneInput(id: uid, name: name, deviceID: deviceID)
      )
    }
    return devices
  }

  static func deviceID(forUID uid: String) -> AudioDeviceID? {
    guard !uid.isEmpty else { return nil }
    return listInputs().first(where: { $0.id == uid })?.deviceID
  }

  private static func allDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize
      ) == noErr
    else {
      return []
    }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        &deviceIDs
      ) == noErr
    else {
      return []
    }
    return deviceIDs
  }

  private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        == noErr,
      dataSize > 0
    else {
      return 0
    }

    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(dataSize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }

    guard
      AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &dataSize,
        raw
      ) == noErr
    else {
      return 0
    }

    let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private static func stringProperty(
    _ deviceID: AudioDeviceID,
    selector: AudioObjectPropertySelector
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &dataSize,
        pointer
      )
    }
    guard status == noErr, let value else { return nil }
    return value as String
  }
}
