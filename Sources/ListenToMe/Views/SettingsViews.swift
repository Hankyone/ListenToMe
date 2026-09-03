import AppKit
import PermissionFlow
import SwiftUI

struct SettingsContentView: View {
  @ObservedObject var settings: SettingsStore
  @ObservedObject var permissions: PermissionService
  let updates: UpdateService

  @State private var apiKey = ""
  @State private var keyStatus = ""
  @State private var microphones: [MicrophoneInput] =
    MicrophoneInputCatalog
    .listInputs()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 30) {
        VStack(alignment: .leading, spacing: 7) {
          Text("Transcription setup")
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
        }

        keySection
        shortcutSection
        voiceSection
        permissionsSection
        updatesSection
      }
      .padding(30)
    }
    .frame(maxWidth: 720, alignment: .leading)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppTheme.background)
    .onAppear {
      // Field stays empty on purpose. Paste a key to set or replace it.
      apiKey = ""
      keyStatus = ""
      microphones = MicrophoneInputCatalog.listInputs()
      settings.refreshAPIKeyPresence()
      permissions.refresh()
      permissions.startVisibilityMonitoring()
    }
    .onDisappear {
      permissions.stopVisibilityMonitoring()
    }
    .onChange(of: settings.selectedProvider) { _, _ in
      apiKey = ""
      keyStatus = ""
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: NSApplication.didBecomeActiveNotification
      )
    ) { _ in
      permissions.refresh()
      microphones = MicrophoneInputCatalog.listInputs()
    }
  }

  private var keySection: some View {
    SettingsSection(title: "Transcription") {
      VStack(alignment: .leading, spacing: 12) {
        Picker("Provider", selection: $settings.selectedProvider) {
          ForEach(TranscriptionProvider.allCases) { provider in
            Text(provider.title).tag(provider)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 300)

        HStack(spacing: 12) {
          ThemedTextField(
            placeholder: settings.hasAPIKey(for: settings.selectedProvider) && apiKey.isEmpty
              ? "Key saved. Paste a new one to replace."
              : settings.selectedProvider.keyPlaceholder,
            text: $apiKey,
            isSecure: true,
            onSubmit: saveAPIKey
          )

          if settings.hasAPIKey(for: settings.selectedProvider),
            apiKey.isEmpty,
            keyStatus.isEmpty
          {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 16))
              .foregroundStyle(AppTheme.success)
              .accessibilityLabel("API key saved")
              .transition(.scale.combined(with: .opacity))
          }

          Button("Save Key") {
            saveAPIKey()
          }
          .buttonStyle(RecordActionButtonStyle())
        }
        .animation(
          .easeOut(duration: 0.18),
          value: settings.hasAPIKey(for: settings.selectedProvider)
        )

        if !keyStatus.isEmpty {
          Text(keyStatus)
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.secondaryText)
        } else if !settings.hasAPIKey(for: settings.selectedProvider) {
          Text("Paste a \(settings.selectedProvider.title) API key, then Save Key.")
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.secondaryText)
        }

        Button {
          NSWorkspace.shared.open(settings.selectedProvider.createKeyURL)
        } label: {
          Label(
            settings.selectedProvider.createKeyLabel,
            systemImage: "arrow.up.right.square"
          )
          .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.accent)
      }
    }
  }

  private var shortcutSection: some View {
    SettingsSection(title: "Shortcut") {
      VStack(alignment: .leading, spacing: 12) {
        HotkeyRecorderView(settings: settings)

        VStack(alignment: .leading, spacing: 8) {
          Toggle(
            "Tap to keep listening (press again to finish)",
            isOn: $settings.tapStartsHandsFree
          )
          .toggleStyle(.checkbox)

          Toggle(
            "Hold to talk (release to finish)",
            isOn: $settings.holdIsPushToTalk
          )
          .toggleStyle(.checkbox)

          Toggle(
            "Space while holding locks hands-free",
            isOn: $settings.spaceLocksHandsFree
          )
          .toggleStyle(.checkbox)
          .disabled(
            !settings.holdIsPushToTalk || settings.hotkey.usesSpaceKey
          )

          if settings.hotkey.usesSpaceKey {
            Text("Space-lock is off because the shortcut already uses Space.")
              .font(.system(size: 11))
              .foregroundStyle(AppTheme.faintText)
          }

          Toggle(
            "Show the recording panel while listening",
            isOn: $settings.showRecordingOverlay
          )
          .toggleStyle(.checkbox)

          if settings.showRecordingOverlay {
            VStack(alignment: .leading, spacing: 6) {
              Picker("Panel size", selection: $settings.overlayLayout) {
                ForEach(OverlayLayout.allCases) { layout in
                  Text(layout.title).tag(layout)
                }
              }
              .labelsHidden()
              .pickerStyle(.segmented)
              .frame(maxWidth: 280)
            }
            .padding(.leading, 22)
          }

          Toggle(
            "Play a sound when listening starts and stops",
            isOn: $settings.playDictationSounds
          )
          .toggleStyle(.checkbox)

          Toggle(
            "Pause media while listening",
            isOn: $settings.pauseMediaWhileListening
          )
          .toggleStyle(.checkbox)
        }
      }
    }
  }

  private var voiceSection: some View {
    SettingsSection(title: "Microphone") {
      VStack(alignment: .leading, spacing: 16) {
        MicrophonePriorityEditor(
          settings: settings,
          microphones: microphones
        )

        if settings.selectedProvider == .openAI {
          VStack(alignment: .leading, spacing: 6) {
            Text("Noise reduction")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(AppTheme.primaryText)
            Picker("", selection: $settings.micProfile) {
              ForEach(MicProfile.allCases) { profile in
                Text(profile.title).tag(profile)
              }
            }
            .labelsHidden()
            .frame(width: 200)
          }
        }
      }
    }
  }

  private var updatesSection: some View {
    SettingsSection(title: "Updates") {
      VStack(alignment: .leading, spacing: 12) {
        Text("ListenToMe \(UpdateService.shortVersion)")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(AppTheme.secondaryText)
        Button("Check for Updates…") {
          updates.checkForUpdates(nil)
        }
        .buttonStyle(RecordActionButtonStyle())
      }
    }
  }

  private var permissionsSection: some View {
    SettingsSection(title: "Mac permissions") {
      VStack(alignment: .leading, spacing: 16) {
        PermissionGuidanceRow(
          title: "Microphone",
          detail: "Needed to hear you.",
          pane: .microphone,
          granted: permissions.microphoneGranted
        )

        PermissionGuidanceRow(
          title: "Accessibility",
          detail: permissions.accessibilityGranted
            ? "Paste is allowed."
            : "Enable ListenToMe, then quit and reopen the app.",
          pane: .accessibility,
          granted: permissions.accessibilityGranted
        )
      }
    }
  }

  private func saveAPIKey() {
    let provider = settings.selectedProvider
    do {
      try settings.saveAPIKey(apiKey, for: provider)
      keyStatus =
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "API key removed"
        : "\(provider.title) API key saved"
      apiKey = ""
    } catch {
      keyStatus = error.localizedDescription
    }
  }
}

private struct MicrophoneVolumeControl: View {
  let deviceUID: String

  @State private var value = 1.0
  @State private var snapshot: MicrophoneVolumeSnapshot?
  @State private var isEditing = false

  var body: some View {
    HStack(spacing: 6) {
      if let snapshot {
        Slider(
          value: Binding(
            get: { value },
            set: setVolume
          ),
          in: 0...1,
          step: 0.01,
          onEditingChanged: { editing in
            isEditing = editing
            if !editing { refresh() }
          }
        )
        .controlSize(.small)
        .disabled(!snapshot.isWritable)
        .accessibilityLabel("Microphone input volume")
        .accessibilityValue(percentage)

        Text(percentage)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(AppTheme.secondaryText)
          .frame(width: 34, alignment: .trailing)
      }
    }
    .onAppear(perform: refresh)
    .task(id: deviceUID) {
      refresh()
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch {
          break
        }
        if !isEditing { refresh() }
      }
    }
  }

  private var percentage: String {
    "\(Int((value * 100).rounded()))%"
  }

  private func setVolume(_ newValue: Double) {
    value = newValue
    guard snapshot?.isWritable == true else { return }
    do {
      try MicrophoneVolumeService.setScalar(Float(newValue), forUID: deviceUID)
    } catch {
      refresh()
    }
  }

  private func refresh() {
    snapshot = MicrophoneVolumeService.snapshot(forUID: deviceUID)
    if let snapshot {
      value = Double(snapshot.scalar)
    }
  }
}

private struct MicrophonePriorityEditor: View {
  @ObservedObject var settings: SettingsStore
  let microphones: [MicrophoneInput]
  @State private var deviceToAdd = MicrophoneInput.systemDefaultID

  private var nameByID: [String: String] {
    Dictionary(uniqueKeysWithValues: microphones.map { ($0.id, $0.name) })
  }

  private var addableDevices: [MicrophoneInput] {
    microphones.filter { !settings.microphonePriorityUIDs.contains($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(settings.microphonePriorityUIDs.enumerated()), id: \.offset) {
        index,
        uid in
        HStack(spacing: 10) {
          Text("\(index + 1).")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(AppTheme.faintText)
            .frame(width: 22, alignment: .trailing)
          Text(displayName(for: uid))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppTheme.primaryText)
            .lineLimit(1)
            .frame(minWidth: 72, maxWidth: 200, alignment: .leading)
          if !isCurrentlyAvailable(uid) && uid != MicrophoneInput.systemDefaultID {
            Text("Unplugged")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(AppTheme.accent)
          }
          if isCurrentlyAvailable(uid) || uid == MicrophoneInput.systemDefaultID {
            MicrophoneVolumeControl(deviceUID: uid)
              .frame(width: 148)
          }
          Spacer(minLength: 8)
          Button {
            settings.moveMicrophonePriority(from: index, direction: -1)
          } label: {
            Image(systemName: "chevron.up")
          }
          .buttonStyle(QuietButtonStyle())
          .disabled(index == 0)
          .accessibilityLabel("Move up")

          Button {
            settings.moveMicrophonePriority(from: index, direction: 1)
          } label: {
            Image(systemName: "chevron.down")
          }
          .buttonStyle(QuietButtonStyle())
          .disabled(index == settings.microphonePriorityUIDs.count - 1)
          .accessibilityLabel("Move down")

          Button {
            settings.removeMicrophoneFromPriority(at: index)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(QuietButtonStyle(isDestructive: true))
          .disabled(
            settings.microphonePriorityUIDs.count == 1
              && uid == MicrophoneInput.systemDefaultID
          )
          .accessibilityLabel("Remove")
        }
        .padding(.vertical, 4)
      }

      if !addableDevices.isEmpty {
        HStack(spacing: 10) {
          Picker("Add microphone", selection: $deviceToAdd) {
            ForEach(addableDevices) { device in
              Text(device.name).tag(device.id)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 260, alignment: .leading)
          .onAppear {
            deviceToAdd = addableDevices.first?.id ?? MicrophoneInput.systemDefaultID
          }
          .onChange(of: addableDevices.map(\.id)) { _, ids in
            if !ids.contains(deviceToAdd) {
              deviceToAdd = ids.first ?? MicrophoneInput.systemDefaultID
            }
          }

          Button("Add") {
            settings.addMicrophoneToPriority(deviceToAdd)
          }
          .buttonStyle(QuietButtonStyle())
        }
      }

      Text(
        "Active now: \(displayName(for: settings.preferredMicrophoneUID(from: microphones)))"
      )
      .font(.system(size: 11))
      .foregroundStyle(AppTheme.faintText)
    }
  }

  private func displayName(for uid: String) -> String {
    if uid == MicrophoneInput.systemDefaultID {
      return "System Default"
    }
    return nameByID[uid] ?? "Unknown microphone"
  }

  private func isCurrentlyAvailable(_ uid: String) -> Bool {
    microphones.contains(where: { $0.id == uid })
  }
}

private struct SettingsSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(AppTheme.primaryText)
      content
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          ChamferedPlate(cut: 10)
            .fill(AppTheme.surface)
            .overlay(
              ChamferedPlate(cut: 10)
                .fill(AppTheme.plateSheen)
            )
        )
    }
  }
}

private struct PermissionGuidanceRow: View {
  let title: String
  let detail: String
  let pane: PermissionFlowPane
  let granted: Bool

  private var appURL: URL { Bundle.main.bundleURL }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(
        systemName: granted
          ? "checkmark.circle.fill"
          : "exclamationmark.circle"
      )
      .foregroundStyle(granted ? AppTheme.success : AppTheme.accent)
      .font(.system(size: 16))

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
          Text(granted ? "Allowed" : "Not allowed")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(granted ? AppTheme.success : AppTheme.accent)
        }
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(AppTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      PermissionFlowButton(
        pane: pane,
        suggestedAppURLs: [appURL],
        configuration: PermissionFlowConfiguration(
          requiredAppURLs: [appURL],
          // Also show the system trust prompt so the app appears in the list.
          promptForAccessibilityTrust: true
        )
      ) { state in
        HStack(spacing: 6) {
          Image(systemName: state.systemImage)
            .foregroundStyle(
              state.isGranted ? AppTheme.success : AppTheme.accent
            )
          Text(state.defaultTitle)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(AppTheme.primaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
          ChamferedPlate(cut: 6)
            .fill(AppTheme.raisedSurface)
        )
      }
      .buttonStyle(.plain)
      // Remount when our observed grant flips so PermissionFlow's button
      // label doesn't stay stuck on the pre-grant state.
      .id("\(pane)-\(granted)")
    }
  }
}
