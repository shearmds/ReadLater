const MENUBAR_URL = 'http://localhost:57832';

// Migrate any existing items from storage.local into storage.sync on first run
migrateFromLocal();
// On startup: pull Mac-side items into storage.sync (macOS only, iOS fails silently)
pullFromMenuBar();
// Re-pull every 5 minutes to catch Mac-side changes
setInterval(pullFromMenuBar, 5 * 60 * 1000);

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    handleMessage(message).then(sendResponse);
    return true;
});

// When iCloud syncs a storage.sync change from another device, push it to the menu bar
browser.storage.onChanged.addListener((changes, area) => {
    if (area === 'sync' && changes.readLater) {
        pushToMenuBar(changes.readLater.newValue ?? []);
    }
});

async function handleMessage(message) {
    const { action } = message;
    const { readLater = [] } = await browser.storage.sync.get('readLater');

    switch (action) {
        case 'getItems': {
            // Pull latest from menu bar app (no-op on iOS or when app not running)
            await pullFromMenuBar();
            const { readLater: fresh = [] } = await browser.storage.sync.get('readLater');
            return { items: fresh };
        }

        case 'saveItem': {
            const { url, title } = message;
            if (readLater.some(i => i.url === url)) return { items: readLater };
            const now = Date.now();
            const updated = [{ url, title, savedAt: now, read: false, updatedAt: now }, ...readLater];
            await browser.storage.sync.set({ readLater: updated });
            return { items: updated };
        }

        case 'deleteItem': {
            const updated = readLater.filter(i => i.url !== message.url);
            await browser.storage.sync.set({ readLater: updated });
            return { items: updated };
        }

        case 'toggleRead': {
            const now = Date.now();
            const updated = readLater.map(i =>
                i.url === message.url ? { ...i, read: !i.read, updatedAt: now } : i
            );
            await browser.storage.sync.set({ readLater: updated });
            return { items: updated };
        }

        default:
            return { items: readLater };
    }
}

// Push local items to menu bar app (one-way; no storage.sync write to avoid loops)
async function pushToMenuBar(items) {
    try {
        const controller = new AbortController();
        setTimeout(() => controller.abort(), 3000);
        await fetch(`${MENUBAR_URL}/sync`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ items }),
            signal: controller.signal
        });
    } catch {
        // Not on Mac or menu bar not running — silently ignore
    }
}

// Pull merged items from menu bar app into storage.sync
async function pullFromMenuBar() {
    try {
        const controller = new AbortController();
        setTimeout(() => controller.abort(), 3000);
        const response = await fetch(`${MENUBAR_URL}/items`, { signal: controller.signal });
        if (!response.ok) return;
        const { items: serverItems } = await response.json();
        const { readLater: localItems = [] } = await browser.storage.sync.get('readLater');
        const merged = mergeItems(localItems, serverItems);
        await browser.storage.sync.set({ readLater: merged });
    } catch {
        // Not on Mac or menu bar not running — silently ignore
    }
}

async function migrateFromLocal() {
    const { readLater: syncItems = [] } = await browser.storage.sync.get('readLater');
    if (syncItems.length > 0) return; // Already have sync data, nothing to migrate
    const { readLater: localItems = [] } = await browser.storage.local.get('readLater');
    if (localItems.length > 0) {
        await browser.storage.sync.set({ readLater: localItems });
    }
}

function mergeItems(a, b) {
    const map = {};
    for (const item of a) map[item.url] = item;
    for (const item of b) {
        if (map[item.url]) {
            const existingTime = Math.max(map[item.url].updatedAt ?? 0, map[item.url].savedAt ?? 0);
            const itemTime = Math.max(item.updatedAt ?? 0, item.savedAt ?? 0);
            const winner = itemTime > existingTime ? item : map[item.url];
            const loser  = itemTime > existingTime ? map[item.url] : item;
            // Always preserve imageUrl from whichever side has it
            map[item.url] = { ...winner, imageUrl: winner.imageUrl ?? loser.imageUrl };
        } else {
            map[item.url] = item;
        }
    }
    return Object.values(map).sort((a, b) => b.savedAt - a.savedAt);
}
