import SwiftUI

/// Words + writing controls: vocabulary, guidance, languages, and response timing.
struct VocabularyView: View {
  @ObservedObject var settings: SettingsStore
  @State private var term = ""
  @State private var oftenHeardAs = ""
  @State private var validationMessage = ""
  @State private var editingItem: VocabularyItem?

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
    .sheet(item: $editingItem) { item in
      VocabularyEditorSheet(item: item) { updated in
        settings.updateVocabulary(updated)
      }
    }
  }

  private var guidanceSection: some View {
    WordsSection(title: "Writing guidance") {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Spacer()
          Button("Reset to default") {
            settings.resetBasePrompt()
          }
          .buttonStyle(QuietButtonStyle())
          .disabled(settings.isUsingDefaultBasePrompt)
        }
        TextEditor(text: $settings.basePrompt)
          .font(.system(size: 13))
          .frame(minHeight: 100)
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
          .disabled(settings.apiProvider != .openAI)
          Text(
            settings.apiProvider == .openAI
              ? settings.delay.explanation
              : "Response timing applies to OpenAI live transcription only."
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
          "Names and product terms are sent as hints with every dictation. They are not hard replacements."
        )
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.secondaryText)

        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 6) {
            ThemedTextField(
              placeholder: "Correct spelling, such as Claude",
              text: $term,
              onSubmit: addWord
            )
            ThemedTextField(
              placeholder: "Often heard as, such as cloud",
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
              HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(item.term)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)
                  if !item.oftenHeardAs.isEmpty {
                    Text("May sound like “\(item.oftenHeardAs)”")
                      .font(.system(size: 12))
                      .foregroundStyle(AppTheme.secondaryText)
                  }
                }
                Spacer()
                Button("Edit") {
                  editingItem = item
                }
                .buttonStyle(QuietButtonStyle())
                Button {
                  settings.removeVocabulary(id: item.id)
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(QuietButtonStyle(isDestructive: true))
                .accessibilityLabel("Delete \(item.term)")
              }
              .padding(12)
              .background(
                ChamferedPlate(cut: 7)
                  .fill(AppTheme.background)
              )
            }
          }
        }
      }
    }
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

private struct VocabularyEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var term: String
  @State private var oftenHeardAs: String
  let item: VocabularyItem
  let onSave: (VocabularyItem) -> Void

  init(item: VocabularyItem, onSave: @escaping (VocabularyItem) -> Void) {
    self.item = item
    self.onSave = onSave
    _term = State(initialValue: item.term)
    _oftenHeardAs = State(initialValue: item.oftenHeardAs)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Edit custom word")
        .font(.system(size: 20, weight: .semibold))
      Form {
        TextField("Correct spelling", text: $term)
        TextField("Often heard as", text: $oftenHeardAs)
      }
      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        Button("Save") {
          var updated = item
          updated.term = term
          updated.oftenHeardAs = oftenHeardAs
          onSave(updated)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(VocabularyValidation.normalizedTerm(term) == nil)
      }
    }
    .padding(24)
    .frame(width: 420)
  }
}
