import AppKit
import PermissionFlow
import Sparkle
import SwiftUI

struct SettingsContentView: View {
  @ObservedObject var settings: SettingsStore
  @ObservedObject var permissions: PermissionService
  let updates: UpdateService

  @State private var apiKey = ""
  @State private var keyStatus = ""
  @State private var microphones: [MicrophoneInput] = MicrophoneInputCatalog
    .listInputs()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 30) {
        VStack(alignment: .leading, spacing: 7) {
          Text("One model. Your words.")
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
          Text(
            "Your own API key, light polish, and a history you can replay or reprocess."
          )
          .font(.system(size: 13))
          .foregroundStyle(AppTheme.secondaryText)
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
      // Field stays empty on purpose — paste a key to set or replace it.
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
    .onReceive(
      NotificationCenter.default.publisher(
        for: NSApplication.didBecomeActiveNotification
      )
    ) { _ in
      permissions.refresh()
    }
  }

  private var keySection: some View {
    SettingsSection(title: "API key") {
      VStack(alignment: .leading, spacing: 12) {
        Picker("Provider", selection: $settings.apiProvider) {
          ForEach(APIProvider.allCases) { provider in
            Text(provider.title).tag(provider)
          }
        }
        .pickerStyle(.segmented)
        .onChange(of: settings.apiProvider) { _, _ in
          apiKey = ""
          keyStatus = ""
        }

        Text(settings.apiProvider.dictationModeNote)
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 12) {
          ThemedTextField(
            placeholder: settings.apiProvider.keyPlaceholder,
            text: $apiKey,
            isSecure: true,
            onSubmit: saveAPIKey
          )
          Button("Save Key") {
            saveAPIKey()
          }
          .buttonStyle(RecordActionButtonStyle())
        }

        HStack(spacing: 8) {
          Image(
            systemName: settings.hasAPIKey
              ? "checkmark.circle.fill"
              : "circle"
          )
          .foregroundStyle(
            settings.hasAPIKey ? AppTheme.success : AppTheme.faintText
          )
          Text(
            keyStatus.isEmpty
              ? (settings.hasAPIKey
                ? "\(settings.apiProvider.title) key saved. Paste a new key to replace it."
                : "Paste your \(settings.apiProvider.title) API key here, then Save Key")
              : keyStatus
          )
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.secondaryText)
        }

        Button {
          NSWorkspace.shared.open(settings.apiProvider.createKeyURL)
        } label: {
          Label(
            settings.apiProvider.createKeyLabel,
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

        Text(
          "Esc cancels a dictation in progress. If you change apps while finishing, the transcript is copied to the clipboard instead of being pasted into the wrong place."
        )
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)

        Toggle(
          "Show the recording panel while listening",
          isOn: $settings.showRecordingOverlay
        )
        .toggleStyle(.checkbox)
      }
    }
  }

  private var voiceSection: some View {
    SettingsSection(title: "Microphone") {
      VStack(alignment: .leading, spacing: 16) {
        Text(
          "Try microphones in order. Docked with a USB mic? Put it first. Away from the desk? Built-in is used when the USB mic isn’t plugged in."
        )
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)

        MicrophonePriorityEditor(
          settings: settings,
          microphones: microphones
        )

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
          .disabled(settings.apiProvider != .openAI)
          Text(
            settings.apiProvider == .openAI
              ? settings.micProfile.explanation
              : "Noise reduction is applied by OpenAI live sessions only."
          )
          .font(.system(size: 11))
          .foregroundStyle(AppTheme.faintText)
        }

        Text("Writing guidance, languages, and response timing live under Words.")
          .font(.system(size: 11))
          .foregroundStyle(AppTheme.faintText)
      }
    }
  }

  private var updatesSection: some View {
    SettingsSection(title: "Updates") {
      VStack(alignment: .leading, spacing: 12) {
        Text("ListenToMe checks for updates automatically. You can also check now.")
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)

        Button("Check for Updates…") {
          updates.updaterController.checkForUpdates(nil)
        }
        .buttonStyle(RecordActionButtonStyle())
      }
    }
  }

  private var permissionsSection: some View {
    SettingsSection(title: "Mac permissions") {
      VStack(alignment: .leading, spacing: 16) {
        Text(
          "Grant opens the right System Settings pane. For Accessibility, enable the ListenToMe row (or drag the app in). After the toggle is on, quit ListenToMe from the menu bar and reopen — macOS often won’t trust a menu-bar app until relaunch. Turn off any extra ListenToMe copies in the list from old builds."
        )
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)

        PermissionGuidanceRow(
          title: "Microphone",
          detail: "Needed to hear your dictation",
          pane: .microphone,
          granted: permissions.microphoneGranted
        )

        PermissionGuidanceRow(
          title: "Accessibility",
          detail: permissions.accessibilityGranted
            ? "Paste and modifier shortcuts are allowed."
            : "Enable ListenToMe in Privacy & Security → Accessibility, then quit and reopen this app.",
          pane: .accessibility,
          granted: permissions.accessibilityGranted
        )
      }
    }
  }

  private func saveAPIKey() {
    do {
      try settings.saveAPIKey(apiKey)
      keyStatus =
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "API key removed"
        : "\(settings.apiProvider.title) API key saved"
      apiKey = ""
    } catch {
      keyStatus = error.localizedDescription
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
          if !isCurrentlyAvailable(uid) && uid != MicrophoneInput.systemDefaultID {
            Text("Unplugged")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(AppTheme.accent)
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
