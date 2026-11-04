import CoreGraphics
import Foundation
import MangaCore

/// 注入网页的脚本：在网页上方叠一层译文。译文按文档坐标绝对定位，会跟着页面一起滚动。
/// 脚本运行在独立的 content world 里，网页自己的脚本看不到也改不了这些函数。
enum OverlayScript {
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
          window.__mangaTranslate = {
            hide() { layer().style.visibility = 'hidden'; },
            show() { layer().style.visibility = 'visible'; },
            clear() { layer().replaceChildren(); },
            // 重新翻译同一屏前，先移除和这块区域重叠的旧译文
            clearRegion(top, bottom) {
              for (const el of [...layer().children]) {
                const elTop = parseFloat(el.dataset.top);
                const elBottom = elTop + parseFloat(el.dataset.height);
                if (elBottom > top && elTop < bottom) el.remove();
              }
            },
            render(items) {
              const root = layer();
              for (const item of items) {
                const el = document.createElement('div');
                el.textContent = item.text;
                el.dataset.top = item.y;
                el.dataset.height = item.height;
                el.style.cssText = [
                  'position:absolute', `left:${item.x}px`, `top:${item.y}px`,
                  `width:${item.width}px`, `height:${item.height}px`,
                  'box-sizing:border-box', 'display:flex', 'align-items:center', 'justify-content:center',
                  'text-align:center', 'padding:2px', 'overflow:hidden', 'border-radius:6px',
                  'background:#fff', 'color:#111', 'line-height:1.25',
                  'font-family:-apple-system,"PingFang SC",sans-serif', 'font-weight:600',
                  'word-break:break-all', 'pointer-events:auto', 'transition:opacity 0.15s',
                  item.vertical ? 'writing-mode:vertical-rl' : '',
                ].join(';');
                // 点一下译文可以临时看原文，再点一下恢复
                el.addEventListener('click', (event) => {
                  event.preventDefault();
                  event.stopPropagation();
                  el.style.opacity = el.style.opacity === '0' ? '1' : '0';
                });
                root.appendChild(el);
                fit(el, item.fontSize);
              }
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

/// 一处要贴到网页上的译文，坐标已换算成文档坐标
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
