import AppKit
import PermissionFlow
import SwiftUI

struct SettingsContentView: View {
  @ObservedObject var settings: SettingsStore
  @ObservedObject var permissions: PermissionService

  @State private var apiKey = ""
  @State private var keyStatus = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 30) {
        VStack(alignment: .leading, spacing: 7) {
          Text("One model. Your words.")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
          Text(
            "Your own API key, light polish, and a history you can replay or reprocess."
          )
          .font(.system(size: 13))
          .foregroundStyle(AppTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        }

        keySection
        shortcutSection
        voiceSection
        permissionsSection
      }
      .padding(24)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppTheme.background)
    .onAppear {
      // Field stays empty on purpose — paste a key to set or replace it.
      apiKey = ""
      keyStatus = ""
      settings.refreshAPIKeyPresence()
      permissions.refresh()
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
    SettingsSection(title: "Voice and context") {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Writing guidance")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(AppTheme.primaryText)
            Spacer()
            Button("Reset to default") {
              settings.resetBasePrompt()
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(settings.isUsingDefaultBasePrompt)
          }
          TextEditor(text: $settings.basePrompt)
            .font(.system(size: 13))
            .frame(minHeight: 92)
            .scrollContentBackground(.hidden)
            .padding(9)
            .background(
              ChamferedPlate(cut: 7)
                .fill(AppTheme.background)
            )
          Text(
            "Sent with every dictation, along with your custom words and the app you are speaking into."
          )
          .font(.system(size: 11))
          .foregroundStyle(AppTheme.faintText)
        }

        Picker("Response", selection: $settings.delay) {
          ForEach(TranscriptionDelay.allCases) { delay in
            Text(delay.title).tag(delay)
          }
        }
        .pickerStyle(.segmented)
        .disabled(settings.apiProvider != .openAI)

        Text(
          settings.apiProvider == .openAI
            ? settings.delay.explanation
            : "Response timing applies to OpenAI live transcription only."
        )
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.secondaryText)

        HStack(spacing: 24) {
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
            .frame(width: 170)
            .disabled(settings.apiProvider != .openAI)
            Text(
              settings.apiProvider == .openAI
                ? settings.micProfile.explanation
                : "Noise reduction is applied by OpenAI live sessions only."
            )
            .font(.system(size: 11))
            .foregroundStyle(AppTheme.faintText)
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Expected languages")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(AppTheme.primaryText)
            ThemedTextField(
              placeholder: "en, fr",
              text: $settings.languageText
            )
            .frame(width: 170)
            Text("Comma-separated codes. Empty for no hint.")
              .font(.system(size: 11))
              .foregroundStyle(AppTheme.faintText)
          }
        }
      }
    }
  }

  private var permissionsSection: some View {
    SettingsSection(title: "Mac permissions") {
      VStack(alignment: .leading, spacing: 16) {
        Text(
          "Grant opens the right System Settings pane. For Accessibility, a floating panel lets you drag ListenToMe into the list."
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
          detail:
            "Needed to paste into the app where you started, and for hold-a-modifier shortcuts",
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
          promptForAccessibilityTrust: pane == .accessibility
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
    }
  }
}
