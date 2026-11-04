import CoreGraphics
import Foundation
import MangaCore

/// 注入网页的脚本，运行在独立的 content world 里，网页自己的脚本看不到也改不了这些函数。
/// - 按图片翻译（自动模式）：找出屏幕附近的漫画图片报给 App，再把译文按比例贴在图片上，跟着图片移动和缩放
/// - 按屏幕翻译："只翻译这一屏"的结果按文档坐标绝对定位
enum OverlayScript {
    static let messageHandlerName = "mangaTranslate"

    static let source = """
        (() => {
          if (window.__mangaTranslate) return;
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
            'background:#fff', 'color:#111', 'line-height:1.25', 'font-family:-apple-system,"PingFang SC",sans-serif',
            'font-weight:600', 'word-break:break-all', 'pointer-events:auto', 'transition:opacity 0.15s',
          ].join(';');

          // 点一下译文可以临时看原文，再点一下恢复
          const textBox = (text, vertical) => {
            const el = document.createElement('div');
            el.textContent = text;
            el.style.cssText = textStyle + (vertical ? ';writing-mode:vertical-rl' : '');
            el.addEventListener('click', (event) => {
              event.preventDefault();
              event.stopPropagation();
              el.style.opacity = el.style.opacity === '0' ? '1' : '0';
            });
            return el;
          };

          // 翻译中的小标记：白底黑框的小气泡，里面三个点依次闪烁；系统开了“减弱动态效果”时不闪
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
            @media (prefers-reduced-motion: reduce) { .__mt_badge span { animation: none; opacity: .6; } }
          `;
          (document.head || document.documentElement).appendChild(style);

          // ---------- 按图片翻译 ----------
          const images = new Map();  // 图片编号 → { img, box, texts, width }
          let autoEnabled = false;
          let nextId = 0;
          let scanTimer = null;
          let repositionQueued = false;

          const post = (message) => {
            try {
              window.webkit.messageHandlers.\(messageHandlerName).postMessage(JSON.stringify(message));
            } catch (error) {}
          };

          const imageById = (id) => document.querySelector(`img[data-mt-id="${CSS.escape(id)}"]`);

          // 找出屏幕上和下方 1.5 屏以内、已经加载好的大图，按离屏幕的远近报给 App
          const scan = () => {
            scanTimer = null;
            if (!autoEnabled) return;
            const viewWidth = window.innerWidth;
            const viewHeight = window.innerHeight;
            const items = [];
            for (const img of document.images) {
              if (img.dataset.mtState) continue;
              if (!img.complete || img.naturalWidth < 300 || img.naturalHeight < 200) continue;
              const rect = img.getBoundingClientRect();
              if (rect.width < viewWidth * 0.5 || rect.height < 100) continue;
              if (rect.bottom < 0) continue;
              const distance = Math.max(0, rect.top - viewHeight);
              if (distance > viewHeight * 1.5) continue;
              if (!img.dataset.mtId) img.dataset.mtId = String(++nextId);
              items.push({ id: img.dataset.mtId, src: img.currentSrc || img.src, distance });
            }
            post({ type: 'candidates', items });
          };
          const scheduleScan = () => {
            if (autoEnabled && !scanTimer) scanTimer = setTimeout(scan, 250);
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
            style.left = (rect.left + window.scrollX) + 'px';
            style.top = (rect.top + window.scrollY) + 'px';
            style.width = rect.width + 'px';
            style.height = rect.height + 'px';
            if (Math.abs(rect.width - entry.width) > 1) {
              entry.width = rect.width;
              for (const [el, item] of entry.texts) fit(el, item.fontScale * rect.width);
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
            const img = imageById(id);
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
          document.addEventListener('load', (event) => {
            if (event.target instanceof HTMLImageElement) onPageChange();
          }, true);
          new MutationObserver(onPageChange).observe(document.documentElement, { childList: true, subtree: true });

          window.__mangaTranslate = {
            // ---------- 按图片翻译 ----------
            setAuto(enabled) {
              autoEnabled = enabled;
              if (enabled) scheduleScan();
            },
            // pending 时在图片右上角放一个小标记，翻译超过 0.6 秒才显出来，秒出的图不会闪一下；
            // failed 不再自动重试；传空值表示重新排队
            markState(id, state) {
              const img = imageById(id);
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
                const el = textBox(item.text, item.vertical);
                el.style.left = (item.x * 100) + '%';
                el.style.top = (item.y * 100) + '%';
                el.style.width = (item.width * 100) + '%';
                el.style.height = (item.height * 100) + '%';
                entry.box.appendChild(el);
                entry.texts.push([el, item]);
              }
              entry.width = 0;
              place(id, entry);
            },

            // ---------- 按屏幕翻译 ----------
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
              for (const item of items) {
                const el = textBox(item.text, item.vertical);
                el.dataset.top = item.y;
                el.dataset.height = item.height;
                el.style.left = item.x + 'px';
                el.style.top = item.y + 'px';
                el.style.width = item.width + 'px';
                el.style.height = item.height + 'px';
                root.appendChild(el);
                fit(el, item.fontSize);
              }
            },

            // 清除全部译文，图片恢复成未翻译状态
            clear() {
              layer().replaceChildren();
              images.clear();
              for (const img of document.querySelectorAll('img[data-mt-state]')) delete img.dataset.mtState;
              scheduleScan();
            },

            // 读取图片内容（blob: 地址，或 App 直接下载失败时），返回 data URL
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
          };
        })();
        """
}

/// 网页可视区域在文档中的位置，单位是 CSS 像素
struct Viewport: Decodable {
    var left: Double
    var top: Double
    var width: Double
    var height: Double

    static let readScript = """
        const v = window.visualViewport;
        return JSON.stringify(v
          ? { left: v.pageLeft, top: v.pageTop, width: v.width, height: v.height }
          : { left: window.scrollX, top: window.scrollY, width: window.innerWidth, height: window.innerHeight });
        """
}

/// "只翻译这一屏"贴到网页上的一处译文，坐标已换算成文档坐标
struct OverlayItem: Encodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var text: String
    var vertical: Bool
    var fontSize: Double

    /// 把截图上的像素坐标换算到网页文档坐标；框向外扩一点，盖住原文的边缘
    static func items(
        for blocks: [TranslatedBlock], imageSize: CGSize, characterSize: CGFloat, viewport: Viewport
    ) -> [OverlayItem] {
        let scaleX = viewport.width / imageSize.width
        let scaleY = viewport.height / imageSize.height
        let padding = max(4, characterSize * 0.25)
        return blocks.filter(\.shouldOverlay).map { block in
            let rect = block.box.rect.insetBy(dx: -padding, dy: -padding)
            let fontSize = block.characterSize.map { CGFloat($0) } ?? characterSize
            return OverlayItem(
                x: viewport.left + rect.minX * scaleX,
                y: viewport.top + rect.minY * scaleY,
                width: rect.width * scaleX,
                height: rect.height * scaleY,
                text: block.translation,
                vertical: block.direction == .vertical,
                fontSize: max(fontSize * scaleX, 10))
        }
    }
}
