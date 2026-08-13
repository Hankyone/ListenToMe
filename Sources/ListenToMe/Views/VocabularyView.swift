import SwiftUI

/// Words + writing controls: vocabulary, guidance, languages, and response timing.
struct VocabularyView: View {
  @ObservedObject var settings: SettingsStore
  @State private var term = ""
  @State private var oftenHeardAs = ""
  @State private var validationMessage = ""
  @State private var editingID: UUID?
  @State private var editTerm = ""
  @State private var editHeardAs = ""
  @State private var editValidationMessage = ""
  @State private var guidanceSavedFlash = false
  @FocusState private var guidanceFocused: Bool
  @State private var guidanceSaveTask: Task<Void, Never>?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 8) {
          Text("How your words come out.")
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
          Text(
            "Custom spellings, writing guidance, languages, and response timing all shape the transcript together."
          )
          .font(.system(size: 13))
          .foregroundStyle(AppTheme.secondaryText)
          .frame(maxWidth: 650, alignment: .leading)
        }

        guidanceSection
        responseAndLanguageSection
        customWordsSection
      }
      .padding(30)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(AppTheme.background)
  }

  private var guidanceSection: some View {
    WordsSection(title: "Writing guidance") {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          if guidanceSavedFlash {
            Label("Saved", systemImage: "checkmark.circle.fill")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(AppTheme.success)
              .transition(.opacity.combined(with: .move(edge: .trailing)))
          }
          Spacer()
          Button("Reset to default") {
            settings.resetBasePrompt()
            flashGuidanceSaved()
          }
          .buttonStyle(QuietButtonStyle())
          .disabled(settings.isUsingDefaultBasePrompt)
        }
        ZStack(alignment: .topLeading) {
          TextEditor(text: $settings.basePrompt)
            .font(.system(size: 13))
            .frame(minHeight: 100)
            .scrollContentBackground(.hidden)
            .padding(9)
            .focused($guidanceFocused)
            .background(
              ChamferedPlate(cut: 7)
                .fill(AppTheme.background)
            )
          if settings.basePrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
          {
            Text(
              "Optional. Leave empty (the default) or add notes for the live model — tone, punctuation, how you want French vs English to look."
            )
            .font(.system(size: 13))
            .foregroundStyle(AppTheme.faintText)
            .padding(.horizontal, 14)
            .padding(.vertical, 17)
            .allowsHitTesting(false)
          }
        }
        .onChange(of: settings.basePrompt) { _, _ in
          // Persists on every edit via SettingsStore; flash after a pause.
          scheduleGuidanceSavedFlash()
        }
        .onChange(of: guidanceFocused) { _, focused in
          if !focused {
            flashGuidanceSaved()
          }
        }
        Text(
          "Default is empty. Every take still sends the app in focus, your custom words, and spoken revisions (correction, scratch that, I mean, annule, je veux dire)."
        )
        .font(.system(size: 11))
        .foregroundStyle(AppTheme.faintText)
      }
    }
  }

  private func scheduleGuidanceSavedFlash() {
    guidanceSaveTask?.cancel()
    guidanceSaveTask = Task {
      try? await Task.sleep(nanoseconds: 700_000_000)
      guard !Task.isCancelled else { return }
      flashGuidanceSaved()
    }
  }

  private func flashGuidanceSaved() {
    guidanceSaveTask?.cancel()
    withAnimation(.easeOut(duration: 0.15)) {
      guidanceSavedFlash = true
    }
    Task {
      try? await Task.sleep(nanoseconds: 1_400_000_000)
      withAnimation(.easeOut(duration: 0.25)) {
        guidanceSavedFlash = false
      }
    }
  }

  private var responseAndLanguageSection: some View {
    WordsSection(title: "Response and language") {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Response")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppTheme.primaryText)
          Picker("Response", selection: $settings.delay) {
            ForEach(TranscriptionDelay.allCases) { delay in
              Text(delay.title).tag(delay)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          Text(settings.delay.explanation)
          .font(.system(size: 11))
          .foregroundStyle(AppTheme.faintText)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Expected languages")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppTheme.primaryText)
          ThemedTextField(
            placeholder: "en, fr",
            text: $settings.languageText,
            onSubmit: { settings.normalizeLanguageTextIfNeeded() },
            onEditingEnded: { settings.normalizeLanguageTextIfNeeded() }
          )
          .frame(maxWidth: 280)
          Text(
            settings.languageHints.message
              ?? "Comma-separated ISO codes (en, fr). Not regional tags like fr-CA. Empty for no hint."
          )
          .font(.system(size: 11))
          .foregroundStyle(
            settings.languageHints.message == nil
              ? AppTheme.faintText
              : (settings.languageHints.isBlocking
                ? AppTheme.accent
                : AppTheme.secondaryText)
          )
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var customWordsSection: some View {
    WordsSection(title: "Custom words") {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          "The first field is the spelling you want in the transcript. Add other spellings the model might hear, separated by commas — for example Anouar with Anwar, Anuar. These are hints, not hard replacements."
        )
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.secondaryText)

        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 6) {
            ThemedTextField(
              placeholder: "Correct spelling, such as Anouar",
              text: $term,
              onSubmit: addWord
            )
            ThemedTextField(
              placeholder: "Other spellings, such as Anwar, Anuar",
              text: $oftenHeardAs,
              onSubmit: addWord
            )
          }

          Button("Add Word") {
            addWord()
          }
          .buttonStyle(RecordActionButtonStyle())
          .disabled(
            term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        }

        if !validationMessage.isEmpty {
          Text(validationMessage)
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.accent)
        }

        if settings.vocabulary.isEmpty {
          Text("No custom words yet. Start with your name and the products you mention most.")
            .font(.system(size: 13))
            .foregroundStyle(AppTheme.secondaryText)
            .padding(.vertical, 8)
        } else {
          VStack(spacing: 8) {
            ForEach(settings.vocabulary) { item in
              vocabularyRow(item)
            }
          }
        }
      }
    }
  }

  private func vocabularyRow(_ item: VocabularyItem) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if editingID == item.id {
        VStack(alignment: .leading, spacing: 6) {
          ThemedTextField(
            placeholder: "Correct spelling, such as Anouar",
            text: $editTerm,
            onSubmit: saveEdit
          )
          ThemedTextField(
            placeholder: "Other spellings, such as Anwar, Anuar",
            text: $editHeardAs,
            onSubmit: saveEdit
          )
        }
        if !editValidationMessage.isEmpty {
          Text(editValidationMessage)
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.accent)
        }
        HStack(spacing: 12) {
          Spacer()
          Button("Cancel") {
            cancelEdit()
          }
          .buttonStyle(QuietButtonStyle())
          Button("Save") {
            saveEdit()
          }
          .buttonStyle(QuietButtonStyle())
          .disabled(
            VocabularyValidation.normalizedTerm(editTerm) == nil
          )
        }
      } else {
        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text(item.term)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(AppTheme.primaryText)
            if !item.oftenHeardAs.isEmpty {
              Text("Also heard as \(item.oftenHeardAs)")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondaryText)
            }
          }
          Spacer()
          Button("Edit") {
            beginEdit(item)
          }
          .buttonStyle(QuietButtonStyle())
          Button {
            if editingID == item.id {
              cancelEdit()
            }
            settings.removeVocabulary(id: item.id)
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(QuietButtonStyle(isDestructive: true))
          .accessibilityLabel("Delete \(item.term)")
        }
      }
    }
    .padding(12)
    .background(
      ChamferedPlate(cut: 7)
        .fill(AppTheme.background)
    )
  }

  private func addWord() {
    guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    if settings.addVocabulary(term: term, oftenHeardAs: oftenHeardAs) {
      term = ""
      oftenHeardAs = ""
      validationMessage = ""
    } else {
      validationMessage =
        "Use one unique term without angle brackets or line breaks."
    }
  }

  private func beginEdit(_ item: VocabularyItem) {
    editingID = item.id
    editTerm = item.term
    editHeardAs = item.oftenHeardAs
    editValidationMessage = ""
  }

  private func cancelEdit() {
    editingID = nil
    editTerm = ""
    editHeardAs = ""
    editValidationMessage = ""
  }

  private func saveEdit() {
    guard let id = editingID,
      let existing = settings.vocabulary.first(where: { $0.id == id })
    else {
      return
    }
    var updated = existing
    updated.term = editTerm
    updated.oftenHeardAs = editHeardAs
    if settings.updateVocabulary(updated) {
      cancelEdit()
    } else {
      editValidationMessage =
        "Use one unique term without angle brackets or line breaks."
    }
  }
}

private struct WordsSection<Content: View>: View {
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

