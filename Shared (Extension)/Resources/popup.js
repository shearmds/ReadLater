let allItems = [];
let currentFilter = "all";
let searchQuery = "";

const listEl = document.getElementById("list");
const emptyEl = document.getElementById("empty");
const searchEl = document.getElementById("search");
const saveBtn = document.getElementById("save-btn");

async function load() {
    const response = await browser.runtime.sendMessage({ action: "getItems" });
    allItems = response?.items ?? [];
    render();
}

function filtered() {
    return allItems.filter((item) => {
        if (currentFilter === "unread" && item.read) return false;
        if (currentFilter === "read" && !item.read) return false;
        if (searchQuery) {
            const q = searchQuery.toLowerCase();
            return item.title.toLowerCase().includes(q) || item.url.toLowerCase().includes(q);
        }
        return true;
    });
}

function faviconUrl(url) {
    try {
        const origin = new URL(url).origin;
        return `${origin}/favicon.ico`;
    } catch {
        return "";
    }
}

function render() {
    const items = filtered();
    listEl.innerHTML = "";

    if (items.length === 0) {
        emptyEl.classList.add("visible");
        return;
    }
    emptyEl.classList.remove("visible");

    for (const item of items) {
        const li = document.createElement("li");
        li.className = "item" + (item.read ? " is-read" : "");

        const favicon = document.createElement("img");
        favicon.className = "item-favicon";
        favicon.src = faviconUrl(item.url);
        favicon.onerror = () => { favicon.style.visibility = "hidden"; };

        const body = document.createElement("div");
        body.className = "item-body";

        const title = document.createElement("div");
        title.className = "item-title";
        title.textContent = item.title;

        const urlEl = document.createElement("div");
        urlEl.className = "item-url";
        try { urlEl.textContent = new URL(item.url).hostname; } catch { urlEl.textContent = item.url; }

        body.append(title, urlEl);

        const actions = document.createElement("div");
        actions.className = "item-actions";

        const readBtn = document.createElement("button");
        readBtn.title = item.read ? "Mark unread" : "Mark read";
        readBtn.textContent = item.read ? "↩" : "✓";
        readBtn.addEventListener("click", (e) => { e.stopPropagation(); toggleRead(item.url); });

        const deleteBtn = document.createElement("button");
        deleteBtn.title = "Remove";
        deleteBtn.textContent = "✕";
        deleteBtn.addEventListener("click", (e) => { e.stopPropagation(); deleteItem(item.url); });

        actions.append(readBtn, deleteBtn);
        li.append(favicon, body, actions);

        li.addEventListener("click", () => {
            browser.tabs.create({ url: item.url });
            if (!item.read) toggleRead(item.url);
        });

        listEl.appendChild(li);
    }
}

async function save() {
    const [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
    if (!tab?.url || tab.url.startsWith("about:")) return;

    const response = await browser.runtime.sendMessage({ action: "saveItem", url: tab.url, title: tab.title || tab.url });
    allItems = response?.items ?? allItems;

    saveBtn.textContent = "Saved!";
    saveBtn.classList.add("saved");
    setTimeout(() => { saveBtn.textContent = "+ Save"; saveBtn.classList.remove("saved"); }, 1500);
    render();
}

async function toggleRead(url) {
    const response = await browser.runtime.sendMessage({ action: "toggleRead", url });
    allItems = response?.items ?? allItems;
    render();
}

async function deleteItem(url) {
    const response = await browser.runtime.sendMessage({ action: "deleteItem", url });
    allItems = response?.items ?? allItems;
    render();
}

function exportData() {
    const json = JSON.stringify(allItems, null, 2);
    const blob = new Blob([json], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `read-later-${new Date().toISOString().slice(0, 10)}.json`;
    a.click();
    URL.revokeObjectURL(url);
}

function importData(file) {
    const reader = new FileReader();
    reader.onload = async (e) => {
        try {
            const imported = JSON.parse(e.target.result);
            if (!Array.isArray(imported)) throw new Error("Invalid format");

            const valid = imported.filter((i) => i.url && i.title);
            const existingUrls = new Set(allItems.map((i) => i.url));
            const newItems = valid.filter((i) => !existingUrls.has(i.url));

            for (const item of newItems) {
                await browser.runtime.sendMessage({ action: "saveItem", url: item.url, title: item.title });
            }
            await load();

            const msg = document.getElementById("import-msg");
            msg.textContent = `+${newItems.length} imported`;
            setTimeout(() => { msg.textContent = ""; }, 2500);
        } catch {
            const msg = document.getElementById("import-msg");
            msg.style.color = "#ff3b30";
            msg.textContent = "Invalid file";
            setTimeout(() => { msg.textContent = ""; msg.style.color = "#34c759"; }, 2500);
        }
    };
    reader.readAsText(file);
}

saveBtn.addEventListener("click", save);

searchEl.addEventListener("input", () => {
    searchQuery = searchEl.value.trim();
    render();
});

document.querySelectorAll(".filter").forEach((btn) => {
    btn.addEventListener("click", () => {
        document.querySelectorAll(".filter").forEach((b) => b.classList.remove("active"));
        btn.classList.add("active");
        currentFilter = btn.dataset.filter;
        render();
    });
});

document.getElementById("export-btn").addEventListener("click", exportData);
document.getElementById("import-input").addEventListener("change", (e) => {
    if (e.target.files[0]) importData(e.target.files[0]);
    e.target.value = "";
});

load();
