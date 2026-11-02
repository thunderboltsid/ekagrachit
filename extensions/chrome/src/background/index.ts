/**
 * Service-worker entry point. MV3 requires listeners to be registered
 * synchronously at top level so Chrome can wake the worker for them.
 * Every handler is funnelled through the controller's serial queue.
 */
import { FocusController } from './controller.ts';

const controller = new FocusController();
const q = <T>(fn: () => Promise<T>) => void controller.serial(fn);

chrome.webNavigation.onCommitted.addListener((d) => q(() => controller.onNavigationCommitted(d.tabId, d.frameId, d.url)));
chrome.webNavigation.onHistoryStateUpdated.addListener((d) => q(() => controller.onSameDocumentNavigation(d.tabId, d.frameId, d.url)));
chrome.webNavigation.onReferenceFragmentUpdated.addListener((d) => q(() => controller.onSameDocumentNavigation(d.tabId, d.frameId, d.url)));
chrome.webNavigation.onErrorOccurred.addListener((d) => q(() => controller.onNavigationError(d.tabId, d.frameId, d.error)));

chrome.tabs.onCreated.addListener((tab) => q(() => controller.onTabCreated(tab)));
chrome.tabs.onRemoved.addListener((tabId, info) => q(() => controller.onTabRemoved(tabId, info.isWindowClosing)));
chrome.tabs.onDetached.addListener((tabId) => controller.noteTabDetached(tabId));
chrome.tabs.onAttached.addListener((tabId, info) => q(() => controller.onTabAttached(tabId, info.newWindowId)));
chrome.tabs.onReplaced.addListener((added, removed) => q(() => controller.onTabReplaced(added, removed)));

chrome.windows.onFocusChanged.addListener((windowId) => q(() => controller.onWindowFocusChanged(windowId)));
chrome.windows.onRemoved.addListener((windowId) => q(() => controller.onWindowRemoved(windowId)));
chrome.windows.onBoundsChanged.addListener((win) => q(() => controller.onWindowBoundsChanged(win)));

chrome.alarms.onAlarm.addListener((alarm) => q(() => controller.onAlarm(alarm.name)));
chrome.commands.onCommand.addListener((command) => {
  if (command === 'open-controls') void controller.openControls();
});

// Startup/installation hooks exist only to wake the worker; init() runs on module load.
chrome.runtime.onStartup.addListener(() => controller.bridge.connect());
chrome.runtime.onInstalled.addListener(() => controller.bridge.connect());

type UiRequest =
  | { type: 'ui/state' }
  | { type: 'ui/start'; target: string; minutes: number }
  | { type: 'ui/end'; sid: string }
  | { type: 'ui/activeTabUrl' };

chrome.runtime.onMessage.addListener((msg: UiRequest, sender, sendResponse) => {
  // Only accept messages from this extension's own pages.
  if (sender.id !== chrome.runtime.id || (sender.url && !sender.url.startsWith(chrome.runtime.getURL('')))) return false;
  const respond = (p: Promise<unknown>) => {
    p.then(sendResponse, (e) => sendResponse({ ok: false, error: String(e) }));
    return true;
  };
  switch (msg?.type) {
    case 'ui/state':
      return respond(controller.uiState());
    case 'ui/start':
      return respond(controller.requestStart(String(msg.target), Number(msg.minutes)));
    case 'ui/end':
      return respond(controller.requestEnd(String(msg.sid)).then(() => ({ ok: true })));
    case 'ui/activeTabUrl':
      return respond(
        chrome.tabs.query({ active: true, lastFocusedWindow: true }).then((tabs) => {
          const url = tabs[0]?.url ?? '';
          return /^https?:/.test(url) ? url : '';
        }),
      );
    default:
      return false;
  }
});

// Test hook: lets browser automation reach the controller. Harmless in
// production (only code running inside this extension's worker can access it).
(globalThis as unknown as { __ekagrachit: FocusController }).__ekagrachit = controller;
