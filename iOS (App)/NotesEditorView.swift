import SwiftUI

struct NotesEditorView: View {
    let item: ReadLaterItem
    let onSave: (String) -> Void
    let onOpen: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notesText: String

    init(item: ReadLaterItem, onSave: @escaping (String) -> Void, onOpen: @escaping () -> Void) {
        self.item = item
        self.onSave = onSave
        self.onOpen = onOpen
        _notesText = State(initialValue: item.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.title)
                        .font(.headline)
                    Button {
                        onSave(notesText)
                        onOpen()
                        dismiss()
                    } label: {
                        HStack {
                            Text(item.url)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                }
                Section("Note") {
                    TextEditor(text: $notesText)
                        .frame(minHeight: 160)
                }
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(notesText)
                        dismiss()
                    }
                }
            }
        }
    }
}
