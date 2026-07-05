import SafariServices
import os.log

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        NSLog("ReadLater: SafariWebExtensionHandler.beginRequest called")
        let request = context.inputItems.first as? NSExtensionItem

        let message: Any?
        if #available(iOS 15.0, macOS 11.0, *) {
            message = request?.userInfo?[SFExtensionMessageKey]
        } else {
            message = request?.userInfo?["message"]
        }

        let response = NSExtensionItem()
        let reply = handle(message: message)

        if #available(iOS 15.0, macOS 11.0, *) {
            response.userInfo = [SFExtensionMessageKey: reply]
        } else {
            response.userInfo = ["message": reply]
        }

        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private func handle(message: Any?) -> [String: Any] {
        guard let msg = message as? [String: Any],
              let action = msg["action"] as? String else {
            return ["error": "invalid message"]
        }

        let store = ReadLaterStore.shared

        switch action {
        case "getItems":
            return ["items": store.toJSON()]

        case "saveItem":
            guard let url = msg["url"] as? String,
                  let title = msg["title"] as? String else {
                return ["error": "missing url or title"]
            }
            store.add(url: url, title: title)
            store.syncWithCloud()
            return ["items": store.toJSON()]

        case "deleteItem":
            guard let url = msg["url"] as? String else {
                return ["error": "missing url"]
            }
            store.delete(url: url)
            store.syncWithCloud()
            return ["items": store.toJSON()]

        case "toggleRead":
            guard let url = msg["url"] as? String else {
                return ["error": "missing url"]
            }
            store.toggleRead(url: url)
            store.syncWithCloud()
            return ["items": store.toJSON()]

        default:
            return ["error": "unknown action"]
        }
    }
}
