// 漫译插件后台：按标签页排队调度（由 iOS App 的 AutoTranslator、PageTextTranslator 移植），
// 取图和截图交给 lib/capture.js，识别和翻译交给 Mac 小助手（lib/native.js）
import { captureVisible, cropToBase64, loadImage } from './lib/capture.js';
import * as helper from './lib/native.js';
import { injectInto, isDryRun, loadConfig, removeSite, siteSettings, syncScripts, updateSite } from './lib/sites.js';

const MAGENTA = '#E4007F';
// 截到空白的 canvas 过多久重截：先快后慢，网络慢时总共也能等 6 秒
const BLANK_RETRY_DELAYS = [1000, 2000, 3000];
// 网页文字一次请求最多合并多少段、多少字（和 MangaCore 的 WebTextTranslator 一致）
const TEXT_MAX_ITEMS = 40;
const TEXT_MAX_CHARACTERS = 1500;

/** 模型服务不可用（缺 Key、Key 无效、余额不足、连不上）：自动翻译和网页文字翻译都停下，等用户处理 */
let blocked = null;

// ---------- 标签页状态 ----------

const tabs = new Map();
let jobSeq = 0;

function tabFor(tabId) {
  let state = tabs.get(tabId);
  if (!state) {
    state = {
      tabId, windowId: null, doc: null, pageUrl: '', host: '', language: 'japanese', auto: false,
      // 图片自动翻译
      generation: 0, queue: [], inFlight: new Set(), handled: new Set(), blankRetries: new Map(), jobs: new Set(),
      // 网页文字翻译
      text: { doc: null, enabled: false, generation: 0, queue: [], inFlight: 0, inFlightItems: 0 },
      lastError: null,
    };
    tabs.set(tabId, state);
  }
  return state;
}

function hostOf(url) {
  try {
    const parsed = new URL(url);
    return /^https?:$/.test(parsed.protocol) ? parsed.hostname : '';
  } catch (error) {
    return '';
  }
}

/** 新文档或清除译文：丢掉排队和还没完成的结果 */
function resetImages(state) {
  state.generation += 1;
  state.queue = [];
  state.inFlight.clear();
  state.handled.clear();
  state.blankRetries.clear();
  helper.cancelJobs([...state.jobs]);
  state.jobs.clear();
  updateBadge(state);
}

function resetText(state) {
  state.text.generation += 1;
  state.text.queue = [];
  state.text.inFlight = 0;
  state.text.inFlightItems = 0;
  updateBadge(state);
}

async function applySite(state, pageUrl) {
  state.pageUrl = pageUrl;
  state.host = hostOf(pageUrl);
  const site = await siteSettings(state.host);
  state.auto = site.auto;
  state.text.enabled = site.pageText;
  if (state.language !== site.language) {
    state.language = site.language;
  }
  return site;
}

/** 发给标签页里的页面脚本；页面没有脚本或已经换页时抛错 */
async function tabSend(state, target, cmd, ...args) {
  const doc = target === 'overlay' ? state.doc : state.text.doc;
  const response = await chrome.tabs.sendMessage(state.tabId, { target, cmd, args, doc }, { frameId: 0 });
  if (!response?.ok) throw new Error(response?.error || '页面没有回应');
  return response.value;
}

function overlay(state, cmd, ...args) {
  return tabSend(state, 'overlay', cmd, ...args);
}

function updateBadge(state) {
  const count = state.queue.length + state.inFlight.size + state.text.queue.length + state.text.inFlightItems;
  const text = blocked && (state.auto || state.text.enabled) ? '!' : count > 0 ? String(Math.min(count, 99)) : '';
  chrome.action.setBadgeText({ tabId: state.tabId, text }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ tabId: state.tabId, color: MAGENTA }).catch(() => {});
}

function noteError(state, message) {
  state.lastError = { message, at: Date.now() };
}

// ---------- 服务不可用时暂停 ----------

function block(message, needsSettings) {
  if (blocked) return;
  blocked = { message, needsSettings, at: Date.now() };
  for (const state of tabs.values()) {
    state.queue = [];
    helper.cancelJobs([...state.jobs]);
    state.text.queue = [];
    updateBadge(state);
    if (state.auto || state.text.enabled) {
      overlay(state, 'toast', message + '，翻译已暂停。点浏览器右上角的漫译图标处理', 'error').catch(() => {});
    }
  }
}

/** 用户改了设置或点了重试：恢复翻译，让页面重新报图片和文字 */
async function unblock() {
  blocked = null;
  await helper.hello({ refresh: true }).catch(() => {});
  for (const state of tabs.values()) {
    updateBadge(state);
    if (state.auto) overlay(state, 'setAuto', true).catch(() => {});
    if (state.text.enabled) {
      tabSend(state, 'pageText', 'setEnabled', false)
        .then(() => tabSend(state, 'pageText', 'setEnabled', true)).catch(() => {});
    }
  }
}

// ---------- 图片自动翻译 ----------

async function limits() {
  if (await isDryRun()) return { imageLimit: 2, textLimit: 2 };
  try {
    return await helper.hello();
  } catch (error) {
    return { imageLimit: 1, textLimit: 1 };
  }
}

async function receiveCandidates(state, items) {
  if (!state.auto || blocked) return;
  // 每次扫描都整个替换队列：滚走了的图不再排队
  state.queue = items
    .filter((item) => !state.inFlight.has(item.id) && !state.handled.has(item.id))
    .sort((a, b) => a.distance - b.distance);
  await pump(state);
}

async function pump(state) {
  const { imageLimit } = await limits();
  while (state.auto && !blocked && state.inFlight.size < imageLimit && state.queue.length > 0) {
    const candidate = state.queue.shift();
    state.inFlight.add(candidate.id);
    const generation = state.generation;
    processImage(state, candidate, generation)
      .catch((error) => console.error('漫译：处理图片出错', error))
      .finally(() => {
        if (generation === state.generation) state.inFlight.delete(candidate.id);
        updateBadge(state);
        pump(state);
      });
  }
  updateBadge(state);
}

async function mark(state, id, value, generation) {
  if (generation !== state.generation) return;
  await overlay(state, 'markState', id, value).catch(() => {});
}

async function processImage(state, candidate, generation) {
  const dryRun = await isDryRun();
  const isCanvas = candidate.kind === 'canvas';
  const { language, host } = state;
  let image = null;
  try {
    if (isCanvas) {
      // canvas 先截图：缓存按截图内容算。截不到说明已经翻走了，去掉标记，等它再停到屏幕上
      image = await snapshotCanvas(state, candidate.id);
      if (!image) {
        await mark(state, candidate.id, null, generation);
        return;
      }
    } else {
      const cached = await helper.request('lookupImage', { src: candidate.src, language, dryRun });
      if (cached.items) {
        await render(state, candidate, cached.items, generation);
        return;
      }
    }
    if (generation !== state.generation) return;
    await mark(state, candidate.id, 'pending', generation);
    if (!image) {
      image = await loadImage(candidate.src, state.pageUrl, (src) => overlay(state, 'readImage', src));
    }
  } catch (error) {
    if (error instanceof helper.HelperError) {
      await mark(state, candidate.id, null, generation);
      block(error.message, true);
    } else {
      state.handled.add(candidate.id);
      await mark(state, candidate.id, 'failed', generation);
      noteError(state, '读取图片失败：' + (error?.message || error));
    }
    return;
  }
  if (generation !== state.generation) return;

  const job = `${state.tabId}-${generation}-${candidate.id}-${++jobSeq}`;
  state.jobs.add(job);
  const result = await new Promise((resolve) => {
    helper.startJob('translateImage', { job, image, src: candidate.src, isCanvas, host, language, dryRun }, (event) => {
      if (event.type === 'partial') {
        // 长图还有段没翻完、或者流式还在生成：先贴上已经翻好的，角标保持"翻译中"
        if (generation === state.generation) {
          overlay(state, 'renderImage', candidate.id, event.items)
            .then(() => overlay(state, 'markState', candidate.id, 'pending')).catch(() => {});
        }
      } else if (event.type !== 'working') {
        resolve(event);
      }
    });
  });
  state.jobs.delete(job);
  if (generation !== state.generation) return;
  if (result.type === 'done') {
    await render(state, candidate, result.items, generation);
  } else if (result.abandoned) {
    await mark(state, candidate.id, null, generation);
  } else if (result.stopsAll || result.disconnected) {
    // 去掉"翻译中"角标，问题解决后这张图还能重新翻译
    await mark(state, candidate.id, null, generation);
    block(result.message, Boolean(result.needsSettings));
  } else {
    state.handled.add(candidate.id);
    await mark(state, candidate.id, 'failed', generation);
    noteError(state, result.message);
  }
}

async function render(state, candidate, items, generation) {
  if (generation !== state.generation) return;
  const id = candidate.id;
  // canvas 没找到文字可能是还没画好（截到空白或加载图），过一会儿再截，最多再截三次
  const retries = state.blankRetries.get(id) || 0;
  if (candidate.kind === 'canvas' && items.length === 0 && retries < BLANK_RETRY_DELAYS.length) {
    state.blankRetries.set(id, retries + 1);
    await mark(state, id, 'waiting', generation);
    setTimeout(() => mark(state, id, null, generation), BLANK_RETRY_DELAYS[retries]);
    return;
  }
  state.handled.add(id);
  await overlay(state, 'renderImage', id, items).catch(() => {});
}

async function isActiveTab(state) {
  try {
    const tab = await chrome.tabs.get(state.tabId);
    state.windowId = tab.windowId;
    return tab.active;
  } catch (error) {
    return false;
  }
}

/** 截取 canvas 当前在屏幕上的区域。截图前藏起译文层；不是当前标签页或 canvas 已经不在原处时返回 null */
async function snapshotCanvas(state, id) {
  if (!(await isActiveTab(state))) return null;
  const frame = await overlay(state, 'prepareSnapshot', id).catch(() => null);
  if (!frame) return null;
  let bitmap;
  try {
    bitmap = await captureVisible(state.windowId);
  } finally {
    await overlay(state, 'show').catch(() => {});
  }
  // 截图期间切到了别的标签页，截到的不是这一页
  if (!(await isActiveTab(state))) return null;
  return await cropToBase64(bitmap, frame, frame);
}

// ---------- 只翻译这一屏 ----------

async function ensureScripts(tabId) {
  const ping = await chrome.tabs.sendMessage(tabId, { target: 'overlay', cmd: 'show', args: [] }, { frameId: 0 })
    .catch(() => null);
  if (ping?.ok) return;
  await injectInto(tabId);
  // 等页面脚本报到
  for (let i = 0; i < 20 && !tabs.get(tabId)?.doc; i++) await new Promise((resolve) => setTimeout(resolve, 50));
}

async function translateScreen(tabId) {
  const tab = await chrome.tabs.get(tabId);
  if (!hostOf(tab.url)) return { error: '这个页面不能翻译' };
  await ensureScripts(tabId);
  const state = tabFor(tabId);
  state.windowId = tab.windowId;
  await applySite(state, tab.url);
  const started = Date.now();
  const say = (text, kind) => overlay(state, 'toast', text, kind).catch(() => {});
  if (blocked) {
    await say(blocked.message + '，请先处理', 'error');
    return { error: blocked.message };
  }
  const geometry = await overlay(state, 'prepareScreen');
  let bitmap;
  try {
    bitmap = await captureVisible(state.windowId);
  } finally {
    await overlay(state, 'show').catch(() => {});
  }
  await say('正在识别这一屏…', 'progress');
  const { viewport } = geometry;
  const image = await cropToBase64(bitmap, { x: 0, y: 0, width: viewport.width, height: viewport.height }, geometry);
  if (!image) {
    await say('截图失败', 'error');
    return { error: '截图失败' };
  }
  const dryRun = await isDryRun();
  const job = `screen-${tabId}-${++jobSeq}`;
  const result = await new Promise((resolve) => {
    helper.startJob('translateScreen', { job, image, viewport, host: state.host, language: state.language, dryRun },
      (event) => {
        if (event.type === 'working') say('正在翻译这一屏…', 'progress');
        else resolve(event);
      });
  });
  if (result.type === 'screenDone') {
    if (result.blockCount === 0) {
      await say('这一屏没有找到文字');
    } else if (!(await overlay(state, 'renderScreen', viewport, result.overlay).catch(() => false))) {
      await say('翻译期间页面宽度变了，译文没有贴上，请再翻译一次');
    } else {
      const seconds = ((Date.now() - started) / 1000).toFixed(1);
      await say(result.overlay.length === 0
        ? '这一屏没有需要翻译的台词' : `这一屏翻译了 ${result.overlay.length} 处，用时 ${seconds} 秒`);
    }
    return { count: result.overlay.length };
  }
  if (result.stopsAll || result.disconnected) block(result.message, Boolean(result.needsSettings));
  await say(result.message, 'error');
  return { error: result.message };
}

// ---------- 网页文字翻译 ----------

const singleLine = (text) => text.split(/\s+/).filter(Boolean).join(' ');

async function receiveText(state, doc, items) {
  if (!state.text.enabled || blocked) return;
  if (state.text.doc !== doc) {
    resetText(state);
    state.text.doc = doc;
  }
  const generation = state.text.generation;
  const dryRun = await isDryRun();
  let hits = [];
  let misses = items;
  if (!dryRun) {
    try {
      const { translations } = await helper.request('lookupText', {
        texts: items.map((item) => singleLine(item.text)), language: state.language,
      });
      hits = items.map((item, index) => ({ id: item.id, text: translations[index] })).filter((hit) => hit.text);
      misses = items.filter((item, index) => !translations[index]);
    } catch (error) {
      if (error instanceof helper.HelperError && error.disconnected) {
        block(error.message, true);
        return;
      }
    }
  }
  if (generation !== state.text.generation) return;
  if (hits.length > 0) tabSend(state, 'pageText', 'apply', hits).catch(() => {});
  // 新报上来的和还在排队的一起按远近排，近的先翻
  state.text.queue = [...state.text.queue, ...misses].sort((a, b) => a.distance - b.distance);
  await pumpText(state);
}

async function pumpText(state) {
  const { textLimit } = await limits();
  const text = state.text;
  while (text.enabled && !blocked && text.inFlight < textLimit && text.queue.length > 0) {
    // 同样的文字（比如每部作品下面的"免费"）只算一次
    const batch = [];
    const distinct = new Set();
    let characters = 0;
    while (text.queue.length > 0) {
      const line = singleLine(text.queue[0].text);
      const isNew = !distinct.has(line);
      if (batch.length > 0 && isNew &&
          (distinct.size >= TEXT_MAX_ITEMS || characters + line.length > TEXT_MAX_CHARACTERS)) break;
      batch.push(text.queue.shift());
      if (isNew) {
        distinct.add(line);
        characters += line.length;
      }
    }
    text.inFlight += 1;
    text.inFlightItems += batch.length;
    const generation = text.generation;
    processText(state, batch, generation).finally(() => {
      if (generation === text.generation) {
        text.inFlight -= 1;
        text.inFlightItems -= batch.length;
      }
      updateBadge(state);
      pumpText(state);
    });
  }
  updateBadge(state);
}

async function processText(state, batch, generation) {
  const dryRun = await isDryRun();
  try {
    const { translations } = await helper.request('translateText', {
      texts: batch.map((item) => item.text), host: state.host, language: state.language, dryRun,
    });
    if (generation !== state.text.generation) return;
    const results = [];
    const missing = [];
    batch.forEach((item, index) => {
      if (translations[index]) results.push({ id: item.id, text: translations[index] });
      else missing.push(item.id);
    });
    if (results.length > 0) await tabSend(state, 'pageText', 'apply', results).catch(() => {});
    // 模型漏掉的编号保持原文
    if (missing.length > 0) await tabSend(state, 'pageText', 'failed', missing).catch(() => {});
  } catch (error) {
    if (generation !== state.text.generation) return;
    if (error.stopsAll || error.disconnected) {
      block(error.message, Boolean(error.needsSettings));
    } else {
      noteError(state, '网页文字翻译失败：' + error.message);
      await tabSend(state, 'pageText', 'failed', batch.map((item) => item.id)).catch(() => {});
    }
  }
}

// ---------- 设置变化 ----------

/** 换了模型服务或原文语言：清掉已经贴的译文，按新设置重新翻译 */
async function resetTab(state) {
  resetImages(state);
  resetText(state);
  await overlay(state, 'clear').catch(() => {});
  await tabSend(state, 'pageText', 'reset').catch(() => {});
}

async function setSite(host, patch, tabId) {
  const before = await siteSettings(host);
  const site = await updateSite(host, patch);
  if ((site.auto || site.pageText) && tabId !== undefined) {
    await injectInto(tabId).catch(() => {});
  }
  for (const state of tabs.values()) {
    if (state.host !== host) continue;
    state.auto = site.auto;
    state.text.enabled = site.pageText;
    if (before.language !== site.language) {
      state.language = site.language;
      await resetTab(state);
    }
    if (!site.auto) {
      state.queue = [];
      helper.cancelJobs([...state.jobs]);
    }
    if (!site.pageText) resetText(state);
    await overlay(state, 'setAuto', site.auto).catch(() => {});
    await tabSend(state, 'pageText', 'setEnabled', site.pageText).catch(() => {});
    updateBadge(state);
  }
  return site;
}

// 设置页改了模型服务：比较前后的当前服务，变了就全部重新翻译
const SETTINGS_REQUESTS = new Set(['saveService', 'deleteService', 'setActive', 'setKey', 'clearKey', 'setSendImage']);

async function helperRequest(type, payload) {
  const before = helper.helperStatus.hello?.service;
  const result = await helper.request(type, payload);
  if (SETTINGS_REQUESTS.has(type)) {
    const after = (await helper.hello({ refresh: true })).service;
    const changed = !before || before.id !== after.id || JSON.stringify(before.config) !== JSON.stringify(after.config);
    if (changed || type === 'setSendImage') {
      for (const state of tabs.values()) await resetTab(state);
    }
    await unblock();
  }
  return result;
}

// ---------- 消息 ----------

async function popupState(tabId) {
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  const host = tab ? hostOf(tab.url) : '';
  const state = tabs.get(tabId);
  let status = null;
  try {
    status = await helper.hello();
  } catch (error) {
    status = null;
  }
  let usage = null;
  if (status?.service?.hasPricing) usage = await helper.request('usage').catch(() => null);
  return {
    host,
    site: host ? await siteSettings(host) : null,
    dryRun: await isDryRun(),
    helper: { connected: Boolean(status), error: helper.helperStatus.error, hello: status },
    blocked,
    pending: state ? state.queue.length + state.inFlight.size + state.text.queue.length + state.text.inFlightItems : 0,
    lastError: state?.lastError || null,
    usage,
  };
}

const handlers = {
  // 页面脚本
  async overlayReady(message, sender) {
    const state = tabFor(sender.tab.id);
    state.windowId = sender.tab.windowId;
    if (state.doc !== message.doc) {
      resetImages(state);
      state.doc = message.doc;
    }
    const site = await applySite(state, message.pageUrl);
    if (site.auto && !blocked) helper.request('warmup').catch(() => {});
    return { auto: site.auto };
  },
  async candidates(message, sender) {
    const state = tabFor(sender.tab.id);
    state.windowId = sender.tab.windowId;
    // 后台重启过，或者报到消息还没到
    if (state.doc !== message.doc) {
      resetImages(state);
      state.doc = message.doc;
      await applySite(state, message.pageUrl);
    }
    await receiveCandidates(state, message.items);
  },
  async pageTextReady(message, sender) {
    const state = tabFor(sender.tab.id);
    resetText(state);
    state.text.doc = message.doc;
    const site = await applySite(state, message.pageUrl);
    return { pageText: site.pageText };
  },
  async pageText(message, sender) {
    const state = tabFor(sender.tab.id);
    if (!state.host) await applySite(state, sender.tab.url);
    await receiveText(state, message.doc, message.items);
  },

  // 弹出面板和设置页
  popupState: (message) => popupState(message.tabId),
  setSite: (message) => setSite(message.host, message.patch, message.tabId),
  removeSite: async (message) => {
    await removeSite(message.host);
    for (const state of tabs.values()) {
      if (state.host !== message.host) continue;
      state.auto = false;
      state.text.enabled = false;
      resetImages(state);
      resetText(state);
      await overlay(state, 'setAuto', false).catch(() => {});
      await tabSend(state, 'pageText', 'setEnabled', false).catch(() => {});
    }
  },
  listSites: async () => (await loadConfig()).sites,
  setDryRun: async (message) => {
    await chrome.storage.local.set({ dryRun: Boolean(message.dryRun) });
    for (const state of tabs.values()) await resetTab(state);
    await unblock();
    return { dryRun: Boolean(message.dryRun) };
  },
  translateScreen: (message) => translateScreen(message.tabId),
  clearPage: async (message) => {
    const state = tabs.get(message.tabId);
    if (!state) return {};
    resetImages(state);
    await overlay(state, 'clear').catch(() => {});
    return {};
  },
  retry: async () => {
    await unblock();
    return {};
  },
  helper: (message) => helperRequest(message.request, message.payload || {}),
  helperStatus: async () => {
    try {
      const status = await helper.hello({ refresh: true });
      return { connected: true, hello: status };
    } catch (error) {
      return { connected: false, error: error.message };
    }
  },
};

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const handler = handlers[message?.type];
  if (!handler) return false;
  Promise.resolve()
    .then(() => handler(message, sender))
    .then((value) => sendResponse(value), (error) => sendResponse({ error: error?.message || String(error) }));
  return true;
});

chrome.tabs.onRemoved.addListener((tabId) => {
  const state = tabs.get(tabId);
  if (!state) return;
  helper.cancelJobs([...state.jobs]);
  tabs.delete(tabId);
});

chrome.runtime.onInstalled.addListener(() => { syncScripts().catch(console.error); });
chrome.runtime.onStartup.addListener(() => { syncScripts().catch(console.error); });
