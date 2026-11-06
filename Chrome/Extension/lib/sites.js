// 每个网站的开关和原文语言，存在 chrome.storage.local。
// 页面脚本只登记到开着自动翻译或网页文字翻译的网站，其他网站上插件什么都不运行

const SCRIPT_FILES = ['content/overlay.js', 'content/pagetext.js'];
const SCRIPT_PREFIX = 'site:';

// App 里收录的韩漫平台（MangaSites.swift），打开时默认原文是韩语；其余默认日语
const KOREAN_DOMAINS = [
  'naver.com', 'kakao.com', 'lezhin.com', 'ridibooks.com', 'bomtoon.com', 'toptoon.com', 'toomics.com', 'mrblue.com',
];

export function defaultLanguage(host) {
  if (host.endsWith('.kr')) return 'korean';
  return KOREAN_DOMAINS.some((domain) => host === domain || host.endsWith('.' + domain)) ? 'korean' : 'japanese';
}

export async function loadConfig() {
  const { sites = {}, dryRun = false } = await chrome.storage.local.get(['sites', 'dryRun']);
  return { sites, dryRun };
}

export async function siteSettings(host) {
  const { sites } = await loadConfig();
  return { auto: false, pageText: false, language: defaultLanguage(host), ...(sites[host] || {}) };
}

export async function updateSite(host, patch) {
  const { sites } = await loadConfig();
  const next = { auto: false, pageText: false, language: defaultLanguage(host), ...(sites[host] || {}), ...patch };
  if (!next.auto && !next.pageText && next.language === defaultLanguage(host)) delete sites[host];
  else sites[host] = next;
  await chrome.storage.local.set({ sites });
  await syncScripts();
  return next;
}

export async function removeSite(host) {
  const { sites } = await loadConfig();
  delete sites[host];
  await chrome.storage.local.set({ sites });
  await syncScripts();
}

export async function isDryRun() {
  return (await loadConfig()).dryRun;
}

/** 按网站开关登记页面脚本：新开的网站登记，关掉的取消 */
export async function syncScripts() {
  const { sites } = await loadConfig();
  const wanted = new Set(Object.entries(sites).filter(([, site]) => site.auto || site.pageText).map(([host]) => host));
  const registered = await chrome.scripting.getRegisteredContentScripts();
  const stale = registered.filter((script) => script.id.startsWith(SCRIPT_PREFIX) &&
    !wanted.has(script.id.slice(SCRIPT_PREFIX.length))).map((script) => script.id);
  if (stale.length > 0) await chrome.scripting.unregisterContentScripts({ ids: stale });
  const have = new Set(registered.map((script) => script.id));
  const missing = [...wanted].filter((host) => !have.has(SCRIPT_PREFIX + host));
  if (missing.length > 0) {
    await chrome.scripting.registerContentScripts(missing.map((host) => ({
      id: SCRIPT_PREFIX + host,
      // 不写端口：本机测试页（localhost:端口）也能匹配
      matches: [`*://${host}/*`],
      js: SCRIPT_FILES,
      runAt: 'document_idle',
      allFrames: false,
      persistAcrossSessions: true,
    })));
  }
}

/** 给已经打开的标签页补注入页面脚本（脚本自己会防止重复运行） */
export async function injectInto(tabId) {
  await chrome.scripting.executeScript({ target: { tabId, frameIds: [0] }, files: SCRIPT_FILES });
}
