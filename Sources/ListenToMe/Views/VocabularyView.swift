import SwiftUI

struct VocabularyView: View {
  @ObservedObject var settings: SettingsStore
  @State private var term = ""
  @State private var oftenHeardAs = ""
  @State private var validationMessage = ""
  @State private var editingItem: VocabularyItem?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Words worth getting right.")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(AppTheme.primaryText)
          .lineLimit(2)
          .minimumScaleFactor(0.85)
        Text(
          "Names and product terms are sent as hints with every dictation. They are not hard replacements."
        )
        .font(.system(size: 13))
        .foregroundStyle(AppTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 24)
      .padding(.top, 18)
      .padding(.bottom, 16)

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 12) {
          addFields
          addButton
        }
        VStack(alignment: .leading, spacing: 10) {
          addFields
          addButton
        }
      }
      .padding(.horizontal, 24)

      if !validationMessage.isEmpty {
        Text(validationMessage)
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.accent)
          .padding(.horizontal, 24)
          .padding(.top, 8)
      }

      if settings.vocabulary.isEmpty {
        ContentUnavailableView(
          "No custom words yet",
          systemImage: "text.book.closed",
          description: Text(
            "Start with your name, company names, and the products you mention most."
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
      } else {
        List(settings.vocabulary) { item in
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
              vocabularyText(item)
              Spacer(minLength: 8)
              vocabularyActions(item)
            }
            VStack(alignment: .leading, spacing: 10) {
              vocabularyText(item)
              HStack(spacing: 10) {
                vocabularyActions(item)
                Spacer(minLength: 0)
              }
            }
          }
          .padding(.vertical, 8)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .padding(.top, 14)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(AppTheme.background)
    .sheet(item: $editingItem) { item in
      VocabularyEditorSheet(item: item) { updated in
        settings.updateVocabulary(updated)
      }
    }
  }

  private var addFields: some View {
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
  }

  private var addButton: some View {
    Button("Add Word") {
      addWord()
    }
    .buttonStyle(RecordActionButtonStyle())
    .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private func vocabularyText(_ item: VocabularyItem) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(item.term)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(AppTheme.primaryText)
        .lineLimit(2)
      if !item.oftenHeardAs.isEmpty {
        Text("May sound like “\(item.oftenHeardAs)”")
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.secondaryText)
          .lineLimit(2)
      }
    }
  }

  private func vocabularyActions(_ item: VocabularyItem) -> some View {
    HStack(spacing: 8) {
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
  }

  private func addWord() {
    guard
      !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
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
