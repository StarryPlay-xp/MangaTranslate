// 漫译：找图、贴译文的页面脚本（由 iOS App 的 OverlayScript 移植）。
// 运行在插件自己的隔离环境里，网页自己的脚本看不到也改不了这些函数。
// - 按图片翻译（自动模式）：找出屏幕附近的漫画图片报给后台，再把译文按比例贴在图片上，跟着图片移动和缩放。
//   画在 canvas 上的页面等它完整停在屏幕上再报，由后台截取那块区域
// - 按屏幕翻译："只翻译这一屏"的结果按文档坐标绝对定位
(() => {
  if (window.__mangaTranslate) return;
  // 每个文档一个编号：换页后后台丢掉旧页面还没完成的结果
  const doc = Math.random().toString(36).slice(2);
  const layerId = '__manga_translate_layer';
  const layer = () => {
    let el = document.getElementById(layerId);
    if (!el) {
      el = document.createElement('div');
      el.id = layerId;
      el.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none;';
      document.documentElement.appendChild(el);
    }
    return el;
  };
  const fontFamily = '-apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif';

  // 从最大字号往下试，直到文字完全放进框里
  const fit = (el, maxSize) => {
    let size = Math.max(Math.round(maxSize), 8);
    el.style.fontSize = size + 'px';
    while (size > 8 && (el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1)) {
      size -= 1;
      el.style.fontSize = size + 'px';
    }
  };

  const textStyle = [
    'position:absolute', 'box-sizing:border-box', 'display:flex', 'align-items:center',
    'justify-content:center', 'text-align:center', 'padding:2px', 'overflow:hidden', 'border-radius:6px',
    'background:#fff', 'color:#111', 'line-height:1.25', 'font-family:' + fontFamily,
    'font-weight:600', 'word-break:break-all', 'pointer-events:auto', 'transition:opacity 0.15s',
    'cursor:pointer', 'margin:0', 'letter-spacing:0', 'text-shadow:none',
  ].join(';');

  // 拟声词、标题这类大字：半透明白底的小标签贴在原文左上角，底色只包住译文，不挡画面；一律横排
  const labelStyle = [
    'position:absolute', 'box-sizing:border-box', 'width:max-content', 'padding:1px 6px',
    'border-radius:6px', 'background:rgba(255,255,255,0.82)', 'box-shadow:0 0 0 1px rgba(0,0,0,0.18)',
    'color:#111', 'line-height:1.3', 'font-family:' + fontFamily,
    'font-weight:700', 'text-align:left', 'word-break:break-all', 'pointer-events:auto',
    'transition:opacity 0.15s', 'cursor:pointer', 'margin:0', 'letter-spacing:0', 'text-shadow:none',
  ].join(';');
  // 和 MangaCore 的 OverlayItem.labelFontRatio、labelMinFont 一致
  const labelFontRatio = 0.05;
  const labelMinFont = 13;

  // 小标签的字号和最大宽度跟着图片（或屏幕）宽度走；超出右边、下边时往回挪
  const placeLabel = (el, left, top, fontSize, maxWidth, areaWidth, areaHeight) => {
    el.style.fontSize = Math.max(Math.round(fontSize), labelMinFont) + 'px';
    el.style.maxWidth = Math.round(maxWidth) + 'px';
    el.style.left = Math.max(0, Math.min(left, areaWidth - el.offsetWidth)) + 'px';
    el.style.top = Math.max(0, Math.min(top, areaHeight - el.offsetHeight)) + 'px';
  };

  // 点一下译文可以临时看原文，再点一下恢复。盖住原文时，周围是纯色就铺同样的底色（白气泡、黑底说明框），
  // 看起来像直接换了字；没有底色信息时用白底黑字
  const textBox = (item) => {
    const el = document.createElement('div');
    el.textContent = item.text;
    el.style.cssText = item.label ? labelStyle : textStyle + (item.vertical ? ';writing-mode:vertical-rl' : '');
    if (!item.label && item.background) {
      el.style.background = item.background;
      el.style.color = item.textColor || '#111';
    }
    el.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      el.style.opacity = el.style.opacity === '0' ? '1' : '0';
    });
    return el;
  };

  // 翻译中的小标记：白底黑框的小气泡，里面三个点依次闪烁；系统开了"减弱动态效果"时不闪。
  // 网页底部的提示条：漫画分镜风，几秒后自动消失
  const style = document.createElement('style');
  style.textContent = `
    @keyframes __mt_blink { 0%, 80%, 100% { opacity: .2 } 40% { opacity: 1 } }
    .__mt_badge { position: absolute; top: 10px; right: 10px; display: flex; gap: 3px; padding: 6px 7px;
      background: #fff; border: 1.5px solid #000; border-radius: 10px 10px 10px 2px;
      opacity: 0; transition: opacity .25s; pointer-events: none; }
    .__mt_badge span { width: 4px; height: 4px; border-radius: 50%; background: #000;
      animation: __mt_blink 1.2s infinite; }
    .__mt_badge span:nth-child(2) { animation-delay: .2s; }
    .__mt_badge span:nth-child(3) { animation-delay: .4s; }
    #__mt_toast { position: fixed; left: 50%; bottom: 28px; transform: translateX(-50%); z-index: 2147483647;
      max-width: min(520px, 90vw); padding: 10px 16px; background: #fff; color: #000; border: 2px solid #000;
      box-shadow: 4px 4px 0 #000; font: 600 14px/1.45 ${fontFamily}; letter-spacing: 0; text-align: left;
      pointer-events: none; opacity: 0; transition: opacity .2s; white-space: pre-line; }
    #__mt_toast.__mt_error { border-color: #E4007F; box-shadow: 4px 4px 0 #E4007F; }
    #__mt_toast.__mt_show { opacity: 1; }
    @media (prefers-reduced-motion: reduce) { .__mt_badge span { animation: none; opacity: .6; } }
  `;
  (document.head || document.documentElement).appendChild(style);

  let toastTimer = null;
  const toast = (text, kind) => {
    let el = document.getElementById('__mt_toast');
    if (!el) {
      el = document.createElement('div');
      el.id = '__mt_toast';
      document.documentElement.appendChild(el);
    }
    el.textContent = '漫译：' + text;
    el.className = (kind === 'error' ? '__mt_error ' : '') + '__mt_show';
    clearTimeout(toastTimer);
    // 进度提示一直显示到下一条提示
    if (kind !== 'progress') toastTimer = setTimeout(() => { el.className = ''; }, kind === 'error' ? 6000 : 3500);
  };

  // ---------- 按图片翻译 ----------
  const images = new Map();  // 图片编号 → { img, box, texts, width }
  let autoEnabled = false;
  let nextId = 0;
  let scanTimer = null;
  let scanDue = 0;
  let repositionQueued = false;

  const post = (message) => {
    try {
      chrome.runtime.sendMessage({ ...message, doc }).catch(() => {});
    } catch (error) {}
  };

  // 图片或 canvas
  const elementById = (id) => document.querySelector(`[data-mt-id="${CSS.escape(id)}"]`);

  // 屏幕上实际看到的区域（触控板双指放大后只是页面的一部分），坐标和 getBoundingClientRect 一致
  const visibleArea = () => {
    const v = window.visualViewport;
    return v
      ? { left: v.offsetLeft, top: v.offsetTop, width: v.width, height: v.height }
      : { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight };
  };
  const fullyVisible = (rect, area) =>
    rect.left >= area.left - 2 && rect.top >= area.top - 2 &&
    rect.right <= area.left + area.width + 2 && rect.bottom <= area.top + area.height + 2;
  const rectKey = (rect) => [rect.left, rect.top, rect.width, rect.height].map(Math.round).join(',');
  // canvas 编号 → 上次看到的位置和从什么时候起没再动过
  const canvasMoves = new Map();

  // 左右两边的图和屏幕上的漫画页原图尺寸相差不到 10%，就当作同一话的相邻页
  const samePageSize = (a, b) =>
    Math.abs(a.naturalWidth - b.naturalWidth) <= b.naturalWidth * 0.1 &&
    Math.abs(a.naturalHeight - b.naturalHeight) <= b.naturalHeight * 0.1;

  // 找出屏幕上和下方 3 屏以内、已经加载好的大图，按离屏幕的远近报给后台。
  // 左右翻页的阅读器把各页横着排开：屏幕左右两侧外面的图，只有和屏幕上的漫画页一样大、
  // 离屏幕不到 2.5 屏宽（前后各约 3 页）的才提前翻，排在屏幕上的图之后；尺寸不同的（广告页、推荐位）翻到了再说。
  // canvas 只在完整停在屏幕上 0.15 秒后才报，还在动（翻页动画）就 0.1 秒后再看。
  // 显示宽度不到屏幕短边一半的不算漫画页
  const scan = () => {
    scanTimer = null;
    if (!autoEnabled) return;
    const viewWidth = window.innerWidth;
    const viewHeight = window.innerHeight;
    const minPageWidth = Math.min(viewWidth, viewHeight) * 0.5;
    const items = [];
    const pages = [];
    for (const img of document.images) {
      if (!img.complete || img.naturalWidth < 300 || img.naturalHeight < 200) continue;
      const rect = img.getBoundingClientRect();
      if (rect.width < minPageWidth || rect.height < 100) continue;
      // 又矮、原图又小的多半是封面；又矮、放在链接里的多半是推广横幅
      if (rect.height < 200 && (img.naturalWidth < 600 || img.closest('a[href]'))) continue;
      if (rect.bottom < 0) continue;
      pages.push({ img, rect, onScreen: rect.right > 0 && rect.left < viewWidth });
    }
    // 已经翻好的也算，用来认出它左右两边的相邻页
    const shown = pages.filter((page) => page.onScreen).map((page) => page.img);
    for (const { img, rect, onScreen } of pages) {
      if (img.dataset.mtState) continue;
      let distance;
      if (onScreen) {
        distance = Math.max(0, rect.top - viewHeight);
        if (distance > viewHeight * 3) continue;
      } else {
        if (rect.top >= viewHeight || rect.bottom <= 0) continue;
        const gap = rect.left >= viewWidth ? rect.left - viewWidth : -rect.right;
        if (gap >= viewWidth * 2.5 || !shown.some((other) => samePageSize(img, other))) continue;
        distance = gap + 1;
      }
      if (!img.dataset.mtId) img.dataset.mtId = String(++nextId);
      items.push({ id: img.dataset.mtId, src: img.currentSrc || img.src, distance });
    }

    const now = performance.now();
    const area = visibleArea();
    let moving = false;
    for (const canvas of document.querySelectorAll('canvas')) {
      if (canvas.dataset.mtState || canvas.width < 300 || canvas.height < 200) continue;
      const rect = canvas.getBoundingClientRect();
      if (rect.width < minPageWidth || rect.height < 200) continue;
      if (!canvas.dataset.mtId) canvas.dataset.mtId = String(++nextId);
      const id = canvas.dataset.mtId;
      const key = rectKey(rect);
      const seen = canvasMoves.get(id);
      if (!seen || seen.key !== key) {
        canvasMoves.set(id, { key, since: now });
        moving = true;
      } else if (fullyVisible(rect, area)) {
        if (now - seen.since >= 150) items.push({ id, src: '', distance: 0, kind: 'canvas' });
        else moving = true;
      }
    }
    post({ type: 'candidates', items, pageUrl: location.href });
    if (moving) scheduleScan(100);
  };
  // 已经约好的扫描比这次要求的晚，就提前到这次要求的时间
  const scheduleScan = (delay = 250) => {
    if (!autoEnabled) return;
    const due = performance.now() + delay;
    if (scanTimer) {
      if (due >= scanDue) return;
      clearTimeout(scanTimer);
    }
    scanDue = due;
    scanTimer = setTimeout(scan, delay);
  };

  // 让译文层对齐图片当前的位置和大小；图片宽度变了就重新排字号
  const place = (id, entry) => {
    if (!entry.img.isConnected) {
      entry.box.remove();
      images.delete(id);
      return;
    }
    const rect = entry.img.getBoundingClientRect();
    const style = entry.box.style;
    // 完全在页面左右两侧外面的（左右翻页时别的页）先藏起来，免得把网页撑宽
    const offscreen = rect.right <= 0 || rect.left >= document.documentElement.clientWidth;
    style.display = offscreen ? 'none' : '';
    if (offscreen) return;
    style.left = (rect.left + window.scrollX) + 'px';
    style.top = (rect.top + window.scrollY) + 'px';
    style.width = rect.width + 'px';
    style.height = rect.height + 'px';
    if (Math.abs(rect.width - entry.width) > 1) {
      entry.width = rect.width;
      for (const [el, item] of entry.texts) {
        if (item.label) {
          placeLabel(
            el, item.x * rect.width, item.y * rect.height,
            Math.min(item.fontScale, labelFontRatio) * rect.width,
            Math.min(Math.max(item.width * rect.width, rect.width * 0.35), rect.width * 0.9),
            rect.width, rect.height);
        } else {
          fit(el, item.fontScale * rect.width);
        }
      }
    }
  };
  const reposition = () => {
    for (const [id, entry] of images) place(id, entry);
  };
  const requestReposition = () => {
    if (repositionQueued || images.size === 0) return;
    repositionQueued = true;
    requestAnimationFrame(() => {
      repositionQueued = false;
      reposition();
    });
  };

  const entryFor = (id) => {
    const img = elementById(id);
    if (!img) return null;
    let entry = images.get(id);
    if (!entry) {
      const box = document.createElement('div');
      box.style.cssText = 'position:absolute;pointer-events:none;';
      layer().appendChild(box);
      entry = { img, box, texts: [], width: 0 };
      images.set(id, entry);
    }
    entry.img = img;
    return entry;
  };

  const onPageChange = () => {
    scheduleScan();
    requestReposition();
  };
  document.addEventListener('scroll', onPageChange, { capture: true, passive: true });
  window.addEventListener('resize', onPageChange);

  // "只翻译这一屏"的译文按文档坐标定位：版面宽度变了（调整窗口大小）网页会重新排版，
  // 译文就对不上了，清掉并提示。触控板双指缩放不改版面宽度，不算
  let layoutWidth = document.documentElement.clientWidth;
  window.addEventListener('resize', () => {
    const width = document.documentElement.clientWidth;
    if (Math.abs(width - layoutWidth) < 1) return;
    layoutWidth = width;
    const root = document.getElementById(layerId);
    if (!root) return;
    const stale = [...root.children].filter((el) => el.dataset.top !== undefined);
    if (stale.length === 0) return;
    for (const el of stale) el.remove();
    toast('窗口宽度变了，网页重新排版，"只翻译这一屏"的译文已清除');
  });
  document.addEventListener('load', (event) => {
    if (event.target instanceof HTMLImageElement) onPageChange();
  }, true);
  new MutationObserver(onPageChange).observe(document.documentElement, { childList: true, subtree: true });

  // 左右翻页的阅读器多半用 transform 移动页面，不触发滚动事件：鼠标、键盘操作和动画之后的 1 秒里每一帧都对齐译文
  let trackUntil = 0;
  let tracking = false;
  const trackFrame = () => {
    reposition();
    if (performance.now() < trackUntil) {
      requestAnimationFrame(trackFrame);
    } else {
      tracking = false;
    }
  };
  // 过渡或动画刚结束多半是翻页停下了，马上看一次 canvas 停稳没有
  const onInteraction = (event) => {
    scheduleScan(event.type === 'transitionend' || event.type === 'animationend' ? 30 : 250);
    trackUntil = performance.now() + 1000;
    if (!tracking && images.size > 0) {
      tracking = true;
      requestAnimationFrame(trackFrame);
    }
  };
  // 切回这个标签页：canvas 页只有当前标签页才能截图，切走期间没翻的现在接着翻
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) scheduleScan(100);
  });
  for (const type of [
    'touchstart', 'touchmove', 'touchend', 'pointerdown', 'pointerup', 'wheel', 'click', 'keydown',
    'transitionstart', 'transitionend', 'animationend',
  ]) {
    window.addEventListener(type, onInteraction, { capture: true, passive: true });
  }

  // 等浏览器把刚改过的样式真正画到屏幕上（截图前藏起译文层后调用）
  const nextPaint = () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));

  // 截图时用：页面坐标换算成截图像素要用到窗口大小和双指缩放倍数
  const captureGeometry = () => {
    const v = window.visualViewport;
    return { innerWidth: window.innerWidth, innerHeight: window.innerHeight, scale: v ? v.scale : 1 };
  };

  const api = {
    // ---------- 按图片翻译 ----------
    setAuto(enabled) {
      autoEnabled = enabled;
      if (enabled) {
        scheduleScan();
      } else {
        clearTimeout(scanTimer);
        scanTimer = null;
      }
    },
    // pending 时在图片右上角放一个小标记，翻译超过 0.6 秒才显出来，秒出的图不会闪一下；
    // failed 不再自动重试；waiting 是 canvas 截到空白，等后台过一会儿重新排队；传空值表示重新排队
    markState(id, state) {
      const img = elementById(id);
      if (!img) return;
      if (state) img.dataset.mtState = state; else delete img.dataset.mtState;
      const entry = entryFor(id);
      if (!entry) return;
      entry.box.querySelector('.__mt_badge')?.remove();
      if (state === 'pending') {
        const badge = document.createElement('div');
        badge.className = '__mt_badge';
        badge.append(document.createElement('span'), document.createElement('span'), document.createElement('span'));
        entry.box.appendChild(badge);
        setTimeout(() => { if (badge.isConnected) badge.style.opacity = '0.9'; }, 600);
      }
      place(id, entry);
      if (!state) scheduleScan();
    },
    renderImage(id, items) {
      const entry = entryFor(id);
      if (!entry) return;
      entry.img.dataset.mtState = 'done';
      entry.box.replaceChildren();
      entry.texts = [];
      for (const item of items) {
        const el = textBox(item);
        // 小标签的位置在 place() 里按像素算，要知道自己多宽才能不超出图片
        if (!item.label) {
          el.style.left = (item.x * 100) + '%';
          el.style.top = (item.y * 100) + '%';
          el.style.width = (item.width * 100) + '%';
          el.style.height = (item.height * 100) + '%';
        }
        entry.box.appendChild(el);
        entry.texts.push([el, item]);
      }
      entry.width = 0;
      place(id, entry);
    },

    // 截取 canvas 前调用：它还完整停在原处就藏起译文层，等画面更新后返回它在可视区域里的位置；
    // 已经翻走或正在动就返回 null。截完要调 show()
    async prepareSnapshot(id) {
      const el = elementById(id);
      if (!el || !el.isConnected) return null;
      const check = () => {
        const rect = el.getBoundingClientRect();
        const area = visibleArea();
        if (!fullyVisible(rect, area) || canvasMoves.get(id)?.key !== rectKey(rect)) return null;
        return {
          x: rect.left - area.left, y: rect.top - area.top, width: rect.width, height: rect.height,
          viewWidth: area.width, viewHeight: area.height, ...captureGeometry(),
        };
      };
      if (!check()) return null;
      layer().style.visibility = 'hidden';
      await nextPaint();
      // 等待期间翻走了
      const frame = check();
      if (!frame) layer().style.visibility = 'visible';
      return frame;
    },

    // ---------- 按屏幕翻译 ----------
    // 藏起译文层，等画面更新后返回可视区域在文档中的位置
    async prepareScreen() {
      layer().style.visibility = 'hidden';
      await nextPaint();
      const v = window.visualViewport;
      const viewport = v
        ? { left: v.pageLeft, top: v.pageTop, width: v.width, height: v.height }
        : { left: window.scrollX, top: window.scrollY, width: window.innerWidth, height: window.innerHeight };
      viewport.layoutWidth = document.documentElement.clientWidth;
      return { viewport, ...captureGeometry() };
    },
    hide() { layer().style.visibility = 'hidden'; },
    show() { layer().style.visibility = 'visible'; },
    // 重新翻译同一屏前，先移除和这块区域重叠的旧译文
    clearRegion(top, bottom) {
      for (const el of [...layer().children]) {
        if (el.dataset.top === undefined) continue;
        const elTop = parseFloat(el.dataset.top);
        const elBottom = elTop + parseFloat(el.dataset.height);
        if (elBottom > top && elTop < bottom) el.remove();
      }
    },
    render(items) {
      const root = layer();
      const pageWidth = document.documentElement.scrollWidth;
      const pageHeight = document.documentElement.scrollHeight;
      const viewWidth = window.visualViewport ? window.visualViewport.width : window.innerWidth;
      for (const item of items) {
        const el = textBox(item);
        el.dataset.top = item.y;
        el.dataset.height = item.height;
        root.appendChild(el);
        if (item.label) {
          placeLabel(
            el, item.x, item.y, item.fontSize, Math.min(Math.max(item.width, viewWidth * 0.35), viewWidth * 0.9),
            pageWidth, pageHeight);
          continue;
        }
        el.style.left = item.x + 'px';
        el.style.top = item.y + 'px';
        el.style.width = item.width + 'px';
        el.style.height = item.height + 'px';
        fit(el, item.fontSize);
      }
    },
    // 贴整屏译文：翻译期间调了窗口大小，网页已经重新排版，按截图时的位置贴会对不上，就不贴
    renderScreen(viewport, items) {
      if (Math.abs(document.documentElement.clientWidth - viewport.layoutWidth) >= 1) return false;
      api.clearRegion(viewport.top, viewport.top + viewport.height);
      api.render(items);
      return true;
    },

    // 清除全部译文，图片和 canvas 都恢复成未翻译状态
    clear() {
      layer().replaceChildren();
      images.clear();
      canvasMoves.clear();
      for (const el of document.querySelectorAll('[data-mt-state]')) delete el.dataset.mtState;
      scheduleScan();
    },

    // 读取图片内容（blob: 地址，或后台直接下载失败时），返回 data URL
    async readImage(src) {
      const response = await fetch(src, { credentials: 'include' });
      if (!response.ok) throw new Error('HTTP ' + response.status);
      const blob = await response.blob();
      return await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(blob);
      });
    },

    toast,
  };
  window.__mangaTranslate = api;

  // 后台发来的命令：{ cmd, args }；需要返回值的命令异步回复 { ok, value } 或 { ok: false, error }
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message?.target !== 'overlay') return false;
    // 换页后旧页面的命令不再执行（bfcache 恢复的旧页面除外，它会重新报到）
    if (message.doc && message.doc !== doc) {
      sendResponse({ ok: false, error: 'stale' });
      return false;
    }
    const handler = api[message.cmd];
    if (!handler) {
      sendResponse({ ok: false, error: 'unknown command' });
      return false;
    }
    Promise.resolve()
      .then(() => handler(...(message.args || [])))
      .then((value) => sendResponse({ ok: true, value }), (error) => sendResponse({ ok: false, error: String(error) }));
    return true;
  });

  // 报到：后台回复这个网站要不要自动翻译。从往返缓存恢复的页面重新报到
  const announce = () => {
    try {
      chrome.runtime.sendMessage({ type: 'overlayReady', doc, pageUrl: location.href })
        .then((state) => api.setAuto(Boolean(state?.auto)))
        .catch(() => {});
    } catch (error) {}
  };
  announce();
  window.addEventListener('pageshow', (event) => { if (event.persisted) announce(); });
})();
