// Thin relay: forward every popup message to the native app handler
// (SafariWebExtensionHandler), which writes to the shared App Group store
// that the RTL app and Share extension use, then pushes to the sync Worker.
//
// This replaces the old menubar-app / browser.storage.sync path, which is
// dead (the localhost menubar app was removed when sync moved to the Worker).

// Safari routes native messages to the containing app regardless of the id,
// but the API wants one, so we pass the extension's identifier.
const APP_ID = "com.mdshear.ReadLater.Extension";

// Messages destined for the native handler. Anything else (e.g. the content
// script's "offlineExtracted" result) is left for the popup's own listener —
// we must NOT forward those to native, or the popup would never see them.
const NATIVE_ACTIONS = new Set([
    "getItems", "saveItem", "deleteItem", "toggleRead", "getToken", "setOffline",
]);

browser.runtime.onMessage.addListener((message) => {
    if (!NATIVE_ACTIONS.has(message?.action)) return; // let other listeners handle it
    // Returning the promise lets the popup await the native reply.
    return browser.runtime.sendNativeMessage(APP_ID, message);
});
