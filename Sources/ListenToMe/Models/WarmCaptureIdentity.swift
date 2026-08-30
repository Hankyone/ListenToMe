import CoreAudio
import Foundation

enum WarmCaptureIdentity {
  /// A warm AVAudioEngine is only reusable when the requested UID still maps
  /// to the same HAL device object. USB replug and sleep assign a new
  /// AudioDeviceID to the same UID; promoting the old graph captures silence.
  static func canReuse(
    warmedUID: String?,
    warmedDeviceID: AudioDeviceID?,
    requestedUID: String,
    liveDeviceID: AudioDeviceID?
  ) -> Bool {
    guard let warmedUID,
      let warmedDeviceID,
      let liveDeviceID,
      warmedDeviceID != kAudioObjectUnknown,
      liveDeviceID != kAudioObjectUnknown
    else {
      return false
    }
    return warmedUID == requestedUID && warmedDeviceID == liveDeviceID
  }
}
