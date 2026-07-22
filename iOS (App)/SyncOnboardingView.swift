import SwiftUI

/// First-launch explainer, shown once before the user ever sees an empty list.
/// Covers the two things people get wrong: the app works standalone with no
/// account, and linking devices/browsers means copying one Sync Key around —
/// it's not automatic. Mirrors the "Syncing your devices" FAQ section, but
/// surfaced immediately instead of waiting for someone to hit the website.
struct SyncOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appTheme") private var themeName: String = AppTheme.ocean.rawValue
    @State private var page = 0
    @State private var copied = false

    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .ocean }
    private var syncKey: String { ReadLaterStore.shared.syncToken }

    var body: some View {
        ZStack {
            theme.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    introPage.tag(0)
                    syncKeyPage.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    if page == 0 {
                        withAnimation { page = 1 }
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(page == 0 ? "Next" : "Got it")
                        .scaledFont(.headline, weight: .semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .background(theme.gradient, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .interactiveDismissDisabled()
    }

    private var introPage: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "text.book.closed.fill")
                .scaledFont(.largeTitle)
                .foregroundStyle(theme.gradient)
                .font(.system(size: 56))
            Text("Welcome to Research Sync")
                .scaledFont(.title2, weight: .bold)
            Text("Save pages here and read them later — no account, no sign-in. This app works completely on its own.")
                .scaledFont(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 36)
            Spacer()
            Spacer()
        }
    }

    private var syncKeyPage: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(theme.gradient)
                .font(.system(size: 48))
            Text("Want it on other devices?")
                .scaledFont(.title2, weight: .bold)
            Text("Copy your Sync Key below, then paste it into the browser extension or another device's Settings. Anything with the same key shares one list.")
                .scaledFont(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)

            Text(syncKey)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)

            Button {
                UIPasteboard.general.string = syncKey
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copied!" : "Copy Sync Key", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(PressableButtonStyle())
            .scaledFont(.subheadline, weight: .semibold)

            Text("You can always find this again later in Settings.")
                .scaledFont(.caption)
                .foregroundColor(.secondary)

            Spacer()
            Spacer()
        }
    }
}
