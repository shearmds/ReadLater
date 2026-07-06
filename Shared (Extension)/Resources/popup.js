// Slim, save-only popup. The full list/search/read UI lives in the native RTL
// app; here we just capture the current tab and hand it to the native handler
// (via background.js) which writes to the shared App Group store.

const saveBtn = document.getElementById("save-btn");
const saveOfflineBtn = document.getElementById("save-offline-btn");
const statusEl = document.getElementById("status");
const titleEl = document.getElementById("page-title");

const WORKER_URL = "https://readlater-sync.shearm.workers.dev";
const OFFLINE_MIN_LENGTH = 1500; // below this = paywalled stub / not a real article
const OFFLINE_PAYLOAD_VERSION = 1;

let currentTab = null;

async function init() {
    const [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
    currentTab = tab;

    if (!tab?.url || tab.url.startsWith("about:") || tab.url.startsWith("safari-web-extension:")) {
        titleEl.textContent = "No page to save.";
        saveBtn.disabled = true;
        return;
    }

    titleEl.textContent = tab.title || tab.url;

    // If it's already saved, reflect that instead of offering a duplicate save.
    try {
        const res = await browser.runtime.sendMessage({ action: "getItems" });
        const items = res?.items ?? [];
        if (items.some((i) => i.url === tab.url && !i.deleted)) {
            markSaved("Already in your list.");
        }
    } catch {
        // getItems is best-effort; saving still works.
    }
}

function markSaved(text) {
    saveBtn.textContent = "✓ Saved";
    saveBtn.classList.add("saved");
    saveBtn.disabled = true;
    statusEl.textContent = text ?? "";
}

saveBtn.addEventListener("click", async () => {
    if (!currentTab?.url) return;
    saveBtn.disabled = true;
    saveBtn.textContent = "Saving…";
    statusEl.textContent = "";

    try {
        const res = await browser.runtime.sendMessage({
            action: "saveItem",
            url: currentTab.url,
            title: currentTab.title || currentTab.url,
        });
        if (res?.error) throw new Error(res.error);
        markSaved("Saved to RTL.");
    } catch {
        saveBtn.disabled = false;
        saveBtn.textContent = "+ Save this page";
        statusEl.textContent = "Couldn't save — try again.";
    }
});

// --- Offline capture --------------------------------------------------------
// Strong capture on iPhone: inject the extractor into the live page, sanitize,
// encrypt with a key derived from the sync token, upload the ciphertext to the
// Worker, and flag the item offline:"saved" so the app pulls + caches it.

saveOfflineBtn.addEventListener("click", async () => {
    if (!currentTab?.url) return;
    setBusy("Reading page…");

    try {
        const article = await extractCurrentPage();
        if (!article.ok || (article.length || 0) < OFFLINE_MIN_LENGTH) {
            // Save the link anyway; just mark the body unavailable offline.
            await sendNative({ action: "saveItem", url: currentTab.url, title: currentTab.title || currentTab.url });
            await sendNative({ action: "setOffline", url: currentTab.url, status: "unavailable" });
            markSaved("Saved — but this page can’t be read offline.");
            return;
        }

        setBusy("Saving offline…");
        // Create/refresh the item first so setOffline has something to flag.
        await sendNative({ action: "saveItem", url: currentTab.url, title: article.title || currentTab.title || currentTab.url });

        const { token } = await sendNative({ action: "getToken" });
        if (!token) throw new Error("no token");

        const wire = await encryptEnvelope(currentTab.url, article, token);
        const ok = await uploadBody(currentTab.url, wire, token);
        if (!ok) throw new Error("upload failed");

        await sendNative({ action: "setOffline", url: currentTab.url, status: "saved" });
        markSaved("Saved & available offline.");
    } catch (e) {
        saveOfflineBtn.disabled = false;
        saveBtn.disabled = false;
        statusEl.textContent = "Couldn’t save offline — try again.";
    }
});

function setBusy(text) {
    saveBtn.disabled = true;
    saveOfflineBtn.disabled = true;
    saveOfflineBtn.textContent = "…";
    statusEl.textContent = text;
}

function sendNative(message) {
    return browser.runtime.sendMessage(message);
}

// Injects the self-contained extractor (content.js = Readability + DOMPurify +
// snippet) into the active tab and waits for it to message the result back.
function extractCurrentPage() {
    return new Promise((resolve) => {
        const timer = setTimeout(() => {
            browser.runtime.onMessage.removeListener(listener);
            resolve({ ok: false, reason: "timeout" });
        }, 15000);
        function listener(msg) {
            if (msg?.action === "offlineExtracted") {
                clearTimeout(timer);
                browser.runtime.onMessage.removeListener(listener);
                resolve(msg.article || { ok: false, reason: "no-article" });
            }
        }
        browser.runtime.onMessage.addListener(listener);
        browser.scripting
            .executeScript({ target: { tabId: currentTab.id }, files: ["content.js"] })
            .catch((e) => {
                clearTimeout(timer);
                browser.runtime.onMessage.removeListener(listener);
                resolve({ ok: false, reason: String(e) });
            });
    });
}

// --- Crypto: HKDF-SHA256 -> AES-256-GCM (see readlater-sync/CRYPTO.md) -------

async function deriveKey(token) {
    const enc = new TextEncoder();
    const ikm = await crypto.subtle.importKey("raw", enc.encode(token), "HKDF", false, ["deriveKey"]);
    return crypto.subtle.deriveKey(
        { name: "HKDF", hash: "SHA-256", salt: enc.encode("rtl-offline-v1"), info: enc.encode("body") },
        ikm,
        { name: "AES-GCM", length: 256 },
        false,
        ["encrypt"],
    );
}

function bytesToB64(bytes) {
    let bin = "";
    for (const b of bytes) bin += String.fromCharCode(b);
    return btoa(bin);
}

// Encrypts the article envelope; wire = base64( iv(12) || ciphertext||tag ).
async function encryptEnvelope(url, article, token) {
    const envelope = JSON.stringify({
        v: OFFLINE_PAYLOAD_VERSION,
        url,
        title: article.title || "",
        siteName: article.siteName || "",
        excerpt: article.excerpt || "",
        length: article.length || 0,
        html: article.html || "",
        capturedAt: Date.now(),
    });
    const key = await deriveKey(token);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(envelope));
    const out = new Uint8Array(iv.length + ct.byteLength);
    out.set(iv, 0);
    out.set(new Uint8Array(ct), iv.length);
    return bytesToB64(out);
}

async function uploadBody(url, wire, token) {
    const res = await fetch(`${WORKER_URL}/body`, {
        method: "PUT",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({ url, ciphertext: wire, meta: { v: OFFLINE_PAYLOAD_VERSION } }),
    });
    return res.ok;
}

init();
