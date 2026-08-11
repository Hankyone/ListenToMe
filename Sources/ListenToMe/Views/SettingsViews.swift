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
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
          Text(
            "OpenAI live transcription with your own API key. Nothing else runs."
          )
          .font(.system(size: 13))
          .foregroundStyle(AppTheme.secondaryText)
        }

        keySection
        shortcutSection
        voiceSection
        permissionsSection
      }
      .padding(30)
      .frame(maxWidth: 720, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppTheme.background)
    .onAppear {
      // Field stays empty on purpose — paste a key to set or replace it.
      apiKey = ""
      permissions.refresh()
    }
  }

  private var keySection: some View {
    SettingsSection(title: "OpenAI API key") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          ThemedTextField(
            placeholder: "OpenAI API key",
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
                ? "Saved in ListenToMe. Paste a new key to replace it."
                : "Paste your OpenAI Platform API key here, then Save Key")
              : keyStatus
          )
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.secondaryText)
        }
      }
    }
  }

  private var shortcutSection: some View {
    SettingsSection(title: "Shortcut") {
      VStack(alignment: .leading, spacing: 12) {
        HotkeyRecorderView(settings: settings)

        Text(
          "Esc cancels a dictation in progress. If you change apps while OpenAI is finishing, the transcript is copied to the clipboard instead of being pasted into the wrong place."
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
          Text("Writing guidance")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppTheme.primaryText)
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
            "Sent with every dictation, along with your custom words and the name of the app you are speaking into."
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

        Text(settings.delay.explanation)
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
            Text(settings.micProfile.explanation)
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
      VStack(spacing: 14) {
        PermissionRow(
          title: "Microphone",
          detail: "Needed to hear your dictation",
          granted: permissions.microphoneGranted,
          buttonTitle: permissions.microphoneGranted ? "Allowed" : "Allow"
        ) {
          Task {
            _ = await permissions.requestMicrophone()
          }
        }

        PermissionRow(
          title: "Accessibility",
          detail:
            "Needed to paste into the app where you started, and for hold-a-modifier shortcuts",
          granted: permissions.accessibilityGranted,
          buttonTitle: permissions.accessibilityGranted ? "Allowed" : "Allow"
        ) {
          permissions.requestAccessibility()
        }
      }
    }
  }

  private func saveAPIKey() {
    do {
      try settings.saveAPIKey(apiKey)
      keyStatus =
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "API key removed"
        : "API key saved"
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

private struct PermissionRow: View {
  let title: String
  let detail: String
  let granted: Bool
  let buttonTitle: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: granted ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(granted ? AppTheme.success : AppTheme.faintText)
        .font(.system(size: 16))

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(AppTheme.primaryText)
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(AppTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()

      Button(buttonTitle, action: action)
        .buttonStyle(QuietButtonStyle())
        .disabled(granted)
    }
  }
}
