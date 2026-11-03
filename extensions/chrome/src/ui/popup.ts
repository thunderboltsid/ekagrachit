/** Extension popup / control window. Talks only to this extension's service worker. */
import type { UiState } from '../background/controller.ts';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const HOLD_MS = 2_000;

let minutes = 25;
let state: UiState | null = null;

function send<T>(msg: unknown): Promise<T> {
  return chrome.runtime.sendMessage(msg) as Promise<T>;
}

function showError(text: string | null): void {
  const el = $('error');
  el.hidden = !text;
  el.textContent = text ?? '';
}

function fmt(ms: number): string {
  const s = Math.max(0, Math.ceil(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const mm = String(m).padStart(h ? 2 : 1, '0');
  return `${h ? `${h}:` : ''}${mm}:${String(sec).padStart(2, '0')}`;
}

function bridgeText(s: UiState): [string, boolean] {
  switch (s.bridge) {
    case 'app_connected': return ['Mac app connected', false];
    case 'app_unavailable': return ['Mac app not running', true];
    case 'host_missing': return ['Native host not installed', true];
    case 'host_disconnected': return ['Native host disconnected', true];
    default: return ['Connecting…', false];
  }
}

async function refresh(): Promise<void> {
  state = await send<UiState>({ type: 'ui/state' });
  const [text, warn] = bridgeText(state);
  const bridge = $('bridge');
  bridge.textContent = text;
  bridge.classList.toggle('warn', warn);

  const active = state.session !== null;
  $('start').hidden = active;
  $('active').hidden = !active;
  if (state.session) {
    $('title').textContent = state.session.title;
    $('title').title = state.session.target;
    $('remaining').textContent = fmt(state.session.endsAt - Date.now());
    const n = state.session.parkedCount;
    $('parked').hidden = n === 0;
    $('parked').textContent = `${n} link${n === 1 ? '' : 's'} saved for after the session.`;
    const degraded = state.session.owner === 'native' && state.bridge !== 'app_connected';
    $('owner').textContent = state.session.owner === 'native'
      ? (degraded ? 'Mac app disconnected: only browser restrictions are enforced.' : 'Browser and desktop isolation active.')
      : 'Browser-only session (desktop is not obscured).';
  } else {
    $('mode').textContent = state.bridge === 'app_connected'
      ? 'The Mac app will dim everything else on screen.'
      : 'Browser-only mode: tabs and navigation are restricted; the rest of your screen stays as it is.';
  }
  if (state.lastError) showError(state.lastError);
  if (!state.session) {
    const later = (await chrome.storage.local.get('later')).later as { items?: unknown[] } | undefined;
    $('later-link').hidden = !later?.items?.length;
  }
}

function selectDuration(btn: HTMLButtonElement | null): void {
  for (const b of document.querySelectorAll<HTMLButtonElement>('.durations button')) {
    b.setAttribute('aria-checked', String(b === btn));
  }
  if (btn) {
    minutes = Number(btn.dataset.min);
    $<HTMLInputElement>('custom').value = '';
  }
}

function setupStart(): void {
  for (const b of document.querySelectorAll<HTMLButtonElement>('.durations button')) {
    b.addEventListener('click', () => selectDuration(b));
  }
  $<HTMLInputElement>('custom').addEventListener('input', (e) => {
    const v = Number((e.target as HTMLInputElement).value);
    if (v > 0) {
      selectDuration(null);
      minutes = v;
    }
  });
  $('start').addEventListener('submit', async (e) => {
    e.preventDefault();
    showError(null);
    const go = $<HTMLButtonElement>('go');
    go.disabled = true;
    try {
      const r = await send<{ ok: boolean; error?: string }>({ type: 'ui/start', target: $<HTMLInputElement>('url').value, minutes });
      if (!r.ok) showError(r.error ?? 'Could not start.');
      else if (!document.body.classList.contains('window')) window.close();
    } finally {
      go.disabled = false;
      await refresh();
    }
  });
  void send<string>({ type: 'ui/activeTabUrl' }).then((url) => {
    const input = $<HTMLInputElement>('url');
    if (url && !input.value) {
      input.value = url;
      input.select();
    }
  });
}

function setupHold(): void {
  const btn = $<HTMLButtonElement>('end');
  let timer: ReturnType<typeof setTimeout> | null = null;
  const start = () => {
    if (timer || !state?.session) return;
    btn.classList.add('holding');
    const sid = state.session.sid;
    timer = setTimeout(async () => {
      timer = null;
      btn.classList.remove('holding');
      await send({ type: 'ui/end', sid });
      await refresh();
    }, HOLD_MS);
  };
  const cancel = () => {
    if (timer) clearTimeout(timer);
    timer = null;
    btn.classList.remove('holding');
  };
  btn.addEventListener('pointerdown', start);
  btn.addEventListener('pointerup', cancel);
  btn.addEventListener('pointerleave', cancel);
  btn.addEventListener('keydown', (e) => {
    if ((e.key === ' ' || e.key === 'Enter') && !e.repeat) { e.preventDefault(); start(); }
  });
  btn.addEventListener('keyup', (e) => { if (e.key === ' ' || e.key === 'Enter') cancel(); });
  btn.addEventListener('blur', cancel);
}

if (new URLSearchParams(location.search).has('window')) document.body.classList.add('window');
setupStart();
setupHold();
void refresh();
setInterval(() => void refresh(), 1000);
