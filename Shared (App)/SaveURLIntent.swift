import AppIntents

@available(iOS 16.0, *)
struct SaveURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Save URL to ReadLater"
    static var description = IntentDescription("Saves a URL to your Read Later list.")

    @Parameter(title: "URL", description: "The URL to save.")
    var url: URL

    @Parameter(title: "Title", description: "Optional title for the page.", default: "")
    var title: String

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$url) to ReadLater") {
            \.$title
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let resolvedTitle = title.isEmpty ? url.host ?? url.absoluteString : title
        await MainActor.run {
            ReadLaterStore.shared.add(url: url.absoluteString, title: resolvedTitle)
        }
        return .result(value: true)
    }
}

@available(iOS 16.0, *)
struct ReadLaterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveURLIntent(),
            phrases: [
                "Save to \(.applicationName)",
                "Add to \(.applicationName)",
                "Read later with \(.applicationName)"
            ],
            shortTitle: "Save to ReadLater",
            systemImageName: "book"
        )
    }
}
