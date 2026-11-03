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
chrome.webNavigation.onErrorOccurred.addListener((d) => q(() => controller.onNavigationError(d.tabId, d.frameId, d.error, d.url)));
chrome.webNavigation.onBeforeNavigate.addListener((d) => q(() => controller.onBeforeNavigate(d.tabId, d.frameId, d.url)));

chrome.tabs.onCreated.addListener((tab) => q(() => controller.onTabCreated(tab)));
chrome.tabs.onRemoved.addListener((tabId, info) => q(() => controller.onTabRemoved(tabId, info.isWindowClosing)));
chrome.tabs.onDetached.addListener((tabId) => controller.noteTabDetached(tabId));
chrome.tabs.onAttached.addListener((tabId, info) => q(() => controller.onTabAttached(tabId, info.newWindowId)));
chrome.tabs.onUpdated.addListener((tabId, info) => {
  if (info.title) q(() => controller.onTabTitle(tabId, info.title!));
});
chrome.tabs.onReplaced.addListener((added, removed) => q(() => controller.onTabReplaced(added, removed)));

chrome.windows.onFocusChanged.addListener((windowId) => q(() => controller.onWindowFocusChanged(windowId)));
chrome.windows.onRemoved.addListener((windowId) => q(() => controller.onWindowRemoved(windowId)));
chrome.windows.onBoundsChanged.addListener((win) => q(() => controller.onWindowBoundsChanged(win)));

chrome.alarms.onAlarm.addListener((alarm) => q(() => controller.onAlarm(alarm.name)));
// The toolbar button opens the Mac app's menu: there is one way to start a
// session, and it is the app. (No popup, no extension-side controls.)
chrome.action.onClicked.addListener((tab) => q(() => controller.onActionClicked(tab.url)));

// Startup/installation hooks exist only to wake the worker; init() runs on module load.
chrome.runtime.onStartup.addListener(() => controller.bridge.connect());
chrome.runtime.onInstalled.addListener(() => controller.bridge.connect());

// Test hook: lets browser automation reach the controller. Harmless in
// production (only code running inside this extension's worker can access it).
(globalThis as unknown as { __ekagrachit: FocusController }).__ekagrachit = controller;
