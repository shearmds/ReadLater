// Slim, save-only popup. The full list/search/read UI lives in the native RTL
// app; here we just capture the current tab and hand it to the native handler
// (via background.js) which writes to the shared App Group store.

const saveBtn = document.getElementById("save-btn");
const statusEl = document.getElementById("status");
const titleEl = document.getElementById("page-title");

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

init();
