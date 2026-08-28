import AudioToolbox
import CoreAudio
import Foundation

struct MicrophoneVolumeSnapshot: Equatable, Sendable {
  let scalar: Float
  let isWritable: Bool
}

enum MicrophoneVolumeService {
  enum ServiceError: LocalizedError {
    case unavailable
    case writeFailed

    var errorDescription: String? {
      switch self {
      case .unavailable:
        "This microphone does not expose an input volume control."
      case .writeFailed:
        "The microphone input volume could not be changed."
      }
    }
  }

  static func snapshot(forUID uid: String) -> MicrophoneVolumeSnapshot? {
    guard let deviceID = resolvedDeviceID(forUID: uid) else { return nil }
    let addresses = preferredVolumeAddresses(for: deviceID)
    let values = addresses.compactMap { readScalar(deviceID: deviceID, address: $0) }
    guard !values.isEmpty else { return nil }

    let average = values.reduce(0, +) / Float(values.count)
    let writable = addresses.contains {
      isWritable(deviceID: deviceID, address: $0)
    }
    return MicrophoneVolumeSnapshot(
      scalar: min(max(average, 0), 1),
      isWritable: writable
    )
  }

  static func setScalar(_ scalar: Float, forUID uid: String) throws {
    guard let deviceID = resolvedDeviceID(forUID: uid) else {
      throw ServiceError.unavailable
    }
    let writableAddresses = preferredVolumeAddresses(for: deviceID).filter {
      isWritable(deviceID: deviceID, address: $0)
    }
    guard !writableAddresses.isEmpty else {
      throw ServiceError.unavailable
    }

    var value = min(max(scalar, 0), 1)
    let size = UInt32(MemoryLayout<Float32>.size)
    for var address in writableAddresses {
      let status = AudioObjectSetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        size,
        &value
      )
      guard status == noErr else { throw ServiceError.writeFailed }
    }
  }

  private static func resolvedDeviceID(forUID uid: String) -> AudioDeviceID? {
    if !uid.isEmpty {
      return MicrophoneInputCatalog.deviceID(forUID: uid)
    }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
  }

  /// System Settings' input slider is virtual main volume (`vmvc`) on the
  /// input scope. It exists even when a USB mic has no master `volm` control.
  private static func preferredVolumeAddresses(
    for deviceID: AudioDeviceID
  ) -> [AudioObjectPropertyAddress] {
    let virtual = virtualMainVolumeAddress()
    if readScalar(deviceID: deviceID, address: virtual) != nil {
      return [virtual]
    }

    let master = channelVolumeAddress(element: kAudioObjectPropertyElementMain)
    if readScalar(deviceID: deviceID, address: master) != nil,
      isWritable(deviceID: deviceID, address: master)
    {
      return [master]
    }

    let channelCount = MicrophoneInputCatalog.inputChannelCount(deviceID)
    let channels: [AudioObjectPropertyAddress]
    if channelCount > 0 {
      channels = (1...channelCount).compactMap { channel in
        let address = channelVolumeAddress(
          element: AudioObjectPropertyElement(channel)
        )
        return readScalar(deviceID: deviceID, address: address) == nil
          ? nil
          : address
      }
    } else {
      channels = []
    }
    let writableChannels = channels.filter {
      isWritable(deviceID: deviceID, address: $0)
    }
    if !writableChannels.isEmpty { return writableChannels }

    if readScalar(deviceID: deviceID, address: master) != nil {
      return [master]
    }
    return channels
  }

  private static func virtualMainVolumeAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private static func channelVolumeAddress(
    element: AudioObjectPropertyElement
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyVolumeScalar,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: element
    )
  }

  private static func readScalar(
    deviceID: AudioDeviceID,
    address: AudioObjectPropertyAddress
  ) -> Float? {
    var address = address
    guard AudioObjectHasProperty(deviceID, &address) else { return nil }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &value
    )
    return status == noErr ? value : nil
  }

  private static func isWritable(
    deviceID: AudioDeviceID,
    address: AudioObjectPropertyAddress
  ) -> Bool {
    var address = address
    var settable = DarwinBoolean(false)
    return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr
      && settable.boolValue
  }
}
