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
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        ReadLaterStore.shared.syncWithCloud()
    }
}
