/**
 * "Saved for later": links the user reached for during a focus session.
 * Stored locally only, removed by "Clear" or after 7 days. Rendered with
 * textContent only (URLs are untrusted strings).
 */
interface Later { items: string[]; title: string; endedAt: number }
const TTL_MS = 7 * 24 * 3600_000;
const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

async function load(): Promise<Later | null> {
  const v = (await chrome.storage.local.get('later')).later as Later | undefined;
  if (!v || !Array.isArray(v.items) || Date.now() - v.endedAt > TTL_MS) {
    await chrome.storage.local.remove('later');
    return null;
  }
  return v;
}

function render(later: Later | null): void {
  const list = $('items');
  list.replaceChildren();
  const items = later?.items ?? [];
  $('empty').hidden = items.length > 0;
  $('actions').hidden = items.length === 0;
  $('intro').textContent = later && items.length
    ? `While you focused on ${later.title}, you reached for ${items.length === 1 ? 'this link' : `these ${items.length} links`}. Nothing was lost — open them now, or whenever you're ready.`
    : '';
  for (const raw of items) {
    let url: URL;
    try { url = new URL(raw); } catch { continue; }
    const li = document.createElement('li');
    const text = document.createElement('div');
    const host = document.createElement('div');
    host.className = 'host';
    host.textContent = url.hostname;
    const path = document.createElement('div');
    path.className = 'path';
    path.textContent = (url.pathname + url.search).slice(0, 300);
    path.title = url.href;
    text.append(host, path);
    const open = document.createElement('button');
    open.type = 'button';
    open.textContent = 'Open';
    open.setAttribute('aria-label', `Open ${url.hostname}${url.pathname}`);
    open.addEventListener('click', () => {
      void chrome.tabs.create({ url: url.href, active: false });
      li.classList.add('opened');
    });
    li.append(text, open);
    list.append(li);
  }
}

async function main(): Promise<void> {
  const later = await load();
  render(later);
  $('open-all').addEventListener('click', async () => {
    for (const u of later?.items ?? []) await chrome.tabs.create({ url: u, active: false });
    $('status').textContent = 'Opened in background tabs.';
  });
  $('copy').addEventListener('click', async () => {
    await navigator.clipboard.writeText((later?.items ?? []).join('\n'));
    $('status').textContent = 'Copied.';
  });
  $('clear').addEventListener('click', async () => {
    await chrome.storage.local.remove('later');
    render(null);
    $('status').textContent = 'Cleared.';
  });
}

void main();
