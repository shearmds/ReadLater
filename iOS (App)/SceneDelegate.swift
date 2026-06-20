import UIKit
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: ReadLaterView())
        self.window = window
        window.makeKeyAndVisible()

        // Cold launch from a widget tap delivers the URL here instead of via
        // scene(_:openURLContexts:).
        if let url = connectionOptions.urlContexts.first?.url {
            openFromWidget(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        openFromWidget(url)
    }

    private func openFromWidget(_ url: URL) {
        ReadLaterStore.shared.markRead(url: url.absoluteString)
        ReadLaterStore.shared.syncWithCloud()
        UIApplication.shared.open(url)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        ReadLaterStore.shared.syncWithCloud()
    }
}
