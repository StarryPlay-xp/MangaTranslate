// 漫译：网页文字翻译的页面脚本（由 iOS App 的 PageTextScript 移植），和 overlay.js 在同一个隔离环境里。
// 找出屏幕附近（上方半屏到下方 2 屏）含日文、韩文的文字报给后台，收到译文后原地替换；
// 原文都记在脚本里，关掉开关时换回原文。滚动、网页新加载内容、点开菜单后再找一次
(() => {
  if (window.__mangaPageText) return;
  // 每个文档一个编号，换页后旧页面的结果对不上就丢掉
  const doc = Math.random().toString(36).slice(2);
  // 假名、汉字、谚文；纯英文、数字和符号不用翻译
  const sourcePattern = /[\u3040-\u30ff\u31f0-\u31ff\uff66-\uff9f\u1100-\u11ff\u3130-\u318f\uac00-\ud7af\u3400-\u4dbf\u4e00-\u9fff]/;
  const skipTags = new Set([
    'SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TEXTAREA', 'SELECT', 'OPTION', 'CODE', 'PRE', 'KBD', 'SAMP',
    'IFRAME', 'CANVAS', 'svg', 'math',
  ]);
  // 漫画译文层和提示条是插件自己贴的中文
  const ownIds = new Set(['__manga_translate_layer', '__mt_toast']);
  const maxItemsPerScan = 300;

  let enabled = false;
  let nextId = 0;
  let scanTimer = null;
  // 编号 → { target, attr, original, shown, translation, state }；attr 为 null 表示文字节点本身
  const entries = new Map();
  const entryIds = new WeakMap();  // 文字节点或元素 → 编号（元素按属性分开记）

  const post = (message) => {
    try {
      chrome.runtime.sendMessage({ ...message, doc }).catch(() => {});
    } catch (error) {}
  };

  const read = (entry) => entry.attr ? (entry.target.getAttribute(entry.attr) || '') : entry.target.data;
  const write = (entry, value) => {
    entry.shown = value;
    if (read(entry) === value) return;
    if (entry.attr) entry.target.setAttribute(entry.attr, value);
    else entry.target.data = value;
  };
  // 保留原文前后的空白，免得译文和旁边的文字粘在一起
  const withSpacing = (original, text) =>
    original.match(/^\s*/)[0] + text + original.match(/\s*$/)[0];

  const acceptNode = (node) => {
    if (node.nodeType !== Node.ELEMENT_NODE) return NodeFilter.FILTER_ACCEPT;
    if (skipTags.has(node.nodeName) || ownIds.has(node.id) || node.isContentEditable ||
        node.getAttribute('translate') === 'no' || node.classList.contains('notranslate')) {
      return NodeFilter.FILTER_REJECT;
    }
    return NodeFilter.FILTER_SKIP;
  };

  // 离屏幕多远（CSS 像素）；看不见或太远时返回 null
  const distanceOf = (element) => {
    if (!element || element.getClientRects().length === 0) return null;
    const rect = element.getBoundingClientRect();
    const viewWidth = window.innerWidth;
    const viewHeight = window.innerHeight;
    if (rect.bottom < -viewHeight * 0.5 || rect.top > viewHeight * 2) return null;
    // 左右滑动的轮播里离得很远的那几页先不管
    if (rect.right < -viewWidth || rect.left > viewWidth * 2) return null;
    return Math.max(0, rect.top - viewHeight, -rect.bottom);
  };

  // 网页自己改了已经记下的文字（比如换了一批推荐作品），就当作新文字重新翻译
  const knownEntry = (key) => {
    const id = entryIds.get(key);
    const entry = id && entries.get(id);
    if (!entry) return null;
    if (read(entry) === entry.shown) return entry;
    entries.delete(id);
    entryIds.delete(key);
    return null;
  };

  const collect = (target, attr, element, items) => {
    const text = attr ? (target.getAttribute(attr) || '') : target.data;
    const trimmed = text.trim();
    if (!trimmed || trimmed.length > 2000 || !sourcePattern.test(trimmed)) return;
    const distance = element ? distanceOf(element) : 0;
    if (distance === null) return;
    const id = ++nextId;
    entries.set(id, { target, attr, original: text, shown: text, translation: null, state: 'sent' });
    entryIds.set(target, id);
    items.push({ id: String(id), text: trimmed, distance });
  };

  const scan = () => {
    scanTimer = null;
    if (!enabled || !document.body) return;
    const items = [];
    // 标题：标签页上显示的也是它
    const title = document.querySelector('title');
    if (title && title.firstChild && title.firstChild.nodeType === Node.TEXT_NODE &&
        !knownEntry(title.firstChild)) {
      collect(title.firstChild, null, null, items);
    }
    const walker = document.createTreeWalker(
      document.body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, { acceptNode });
    for (let node = walker.nextNode(); node && items.length < maxItemsPerScan; node = walker.nextNode()) {
      if (knownEntry(node)) continue;
      collect(node, null, node.parentElement, items);
    }
    // 搜索框的提示文字和按钮上的字
    for (const element of document.querySelectorAll(
      'input[placeholder], textarea[placeholder], input[type=submit][value], input[type=button][value]')) {
      if (items.length >= maxItemsPerScan) break;
      const attr = element.hasAttribute('placeholder') ? 'placeholder' : 'value';
      if (knownEntry(element)) continue;
      collect(element, attr, element, items);
    }
    if (items.length > 0) post({ type: 'pageText', items });
    // 一次报不完的，过一会儿接着报
    if (items.length >= maxItemsPerScan) schedule(1500);
  };

  const schedule = (delay = 300) => {
    if (!enabled || scanTimer) return;
    scanTimer = setTimeout(scan, delay);
  };

  // 网页加内容、改文字时再找；只看增删节点和文字变化，不看属性，免得动画让它一直扫描
  const observer = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      if (mutation.type === 'characterData') {
        const entry = knownEntry(mutation.target);
        if (entry) continue;  // 是自己换上去的译文
      }
      schedule(400);
      return;
    }
  });

  window.addEventListener('scroll', () => schedule(300), { passive: true, capture: true });
  window.addEventListener('resize', () => schedule(300), { passive: true });
  // 点开下拉菜单、展开简介之后，新露出来的文字也翻译
  document.addEventListener('click', () => schedule(500), { capture: true, passive: true });

  const api = {
    setEnabled(on) {
      if (on === enabled) return;
      enabled = on;
      if (on) {
        for (const [id, entry] of entries) {
          if (read(entry) !== entry.shown) { entries.delete(id); continue; }
          if (entry.translation !== null) write(entry, withSpacing(entry.original, entry.translation));
          // 关掉期间后台已经丢掉了排队的请求，重新报
          else if (entry.state === 'sent') { entries.delete(id); entryIds.delete(entry.target); }
        }
        observer.observe(document.documentElement, { childList: true, characterData: true, subtree: true });
        scan();
      } else {
        observer.disconnect();
        clearTimeout(scanTimer);
        scanTimer = null;
        for (const entry of entries.values()) {
          if (read(entry) === entry.shown) write(entry, entry.original);
        }
      }
    },

    apply(list) {
      for (const item of list) {
        const entry = entries.get(Number(item.id));
        if (!entry) continue;
        entry.translation = item.text;
        entry.state = 'done';
        if (enabled && read(entry) === entry.shown) write(entry, withSpacing(entry.original, item.text));
      }
    },

    // 没翻译成功的留着原文，这一页不再重试
    failed(ids) {
      for (const id of ids) {
        const entry = entries.get(Number(id));
        if (entry) entry.state = 'failed';
      }
    },

    // 换了模型服务或原文语言：恢复原文，全部重新翻译
    reset() {
      for (const entry of entries.values()) {
        if (read(entry) === entry.shown) write(entry, entry.original);
      }
      entries.clear();
      if (enabled) scan();
    },
  };
  window.__mangaPageText = api;

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message?.target !== 'pageText') return false;
    if (message.doc && message.doc !== doc) {
      sendResponse({ ok: false, error: 'stale' });
      return false;
    }
    const handler = api[message.cmd];
    if (!handler) {
      sendResponse({ ok: false, error: 'unknown command' });
      return false;
    }
    try {
      sendResponse({ ok: true, value: handler(...(message.args || [])) });
    } catch (error) {
      sendResponse({ ok: false, error: String(error) });
    }
    return false;
  });

  const announce = () => {
    try {
      chrome.runtime.sendMessage({ type: 'pageTextReady', doc, pageUrl: location.href })
        .then((state) => api.setEnabled(Boolean(state?.pageText)))
        .catch(() => {});
    } catch (error) {}
  };
  announce();
  window.addEventListener('pageshow', (event) => { if (event.persisted) announce(); });
})();
