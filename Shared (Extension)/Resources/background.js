// Thin relay: forward every popup message to the native app handler
// (SafariWebExtensionHandler), which writes to the shared App Group store
// that the RTL app and Share extension use, then pushes to the sync Worker.
//
// This replaces the old menubar-app / browser.storage.sync path, which is
// dead (the localhost menubar app was removed when sync moved to the Worker).

// Safari routes native messages to the containing app regardless of the id,
// but the API wants one, so we pass the extension's identifier.
const APP_ID = "com.mdshear.ReadLater.Extension";

browser.runtime.onMessage.addListener((message) => {
    // Returning the promise lets the popup await the native reply.
    return browser.runtime.sendNativeMessage(APP_ID, message);
});
