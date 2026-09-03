import XCTest

@testable import ListenToMe

final class RecordingStartupRegressionTests: XCTestCase {
  func testFirstReleaseDuringConnectingAlwaysFinishesAfterStartup() {
    for hasAudioSendTask in [false, true] {
      for isMicRecording in [false, true] {
        XCTAssertEqual(
          RecordingStopPolicy.decision(
            phase: .connecting,
            hasAudioSendTask: hasAudioSendTask,
            isMicRecording: isMicRecording,
            alreadyRequestedStop: false
          ),
          .finishAfterConnect
        )
      }
    }
  }

  func testSecondReleaseDuringConnectingAlwaysAborts() {
    for hasAudioSendTask in [false, true] {
      for isMicRecording in [false, true] {
        XCTAssertEqual(
          RecordingStopPolicy.decision(
            phase: .connecting,
            hasAudioSendTask: hasAudioSendTask,
            isMicRecording: isMicRecording,
            alreadyRequestedStop: true
          ),
          .abort
        )
      }
    }
  }
}
