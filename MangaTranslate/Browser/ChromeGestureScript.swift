import Foundation

/// 注入网页每个 frame 的手势脚本，告诉 App 什么时候收起或放出上下工具栏。
///
/// 上下滚动的网页靠 BrowserModel 看滚动位置就够了；左右翻页的阅读器整页不滚动（多半用脚本换图），
/// 只能看手指在网页上怎么动：
/// - 左右滑（翻页）、点屏幕左右两侧（多数阅读器点两侧翻页）：收起
/// - 点屏幕中间：切换显示和收起，和常见的漫画 App 一样；等 0.3 秒确认不是双击缩放
/// - 网页本身没跟着滚动的上下滑（翻页阅读器、只有内层区域在滚动）：往上滑收起，往下拉放出
///
/// 只用被动监听、不拦截任何触摸，网页自己的翻页和菜单照常工作；点在链接、按钮、输入框和译文上不算
enum ChromeGestureScript {
    static let source = """
        (() => {
          if (window.__mangaTranslateGestures) return;
          window.__mangaTranslateGestures = true;

          const post = (action) => {
            try {
              window.webkit.messageHandlers.\(OverlayScript.messageHandlerName)
                .postMessage(JSON.stringify({ type: 'chrome', action }));
            } catch (error) {}
          };

          const interactive = [
            'a[href]', 'button', 'input', 'textarea', 'select', 'label', 'summary', 'video', 'audio',
            '[role="button"]', '[role="link"]', '[role="slider"]', '[role="tab"]', '[role="menuitem"]',
            '[contenteditable]:not([contenteditable="false"])', '#__manga_translate_layer',
          ].join(',');
          const options = { capture: true, passive: true };
          let start = null;
          let pendingToggle = null;

          const onTap = (begin) => {
            if (begin.target?.closest?.(interactive)) return;
            // clientX 相对布局视口；放大以后要换算到屏幕上实际看到的区域
            const viewport = window.visualViewport;
            const left = viewport ? viewport.offsetLeft : 0;
            const width = (viewport ? viewport.width : window.innerWidth) || 1;
            const position = (begin.x - left) / width;
            if (position < 0.3 || position > 0.7) {
              post('hide');
              return;
            }
            // 0.3 秒内又点了一下是双击（多半在缩放），两下都不算
            if (pendingToggle) {
              clearTimeout(pendingToggle);
              pendingToggle = null;
              return;
            }
            pendingToggle = setTimeout(() => {
              pendingToggle = null;
              post('toggle');
            }, 300);
          };

          window.addEventListener('touchstart', (event) => {
            // 多指（双指缩放）整个手势都不算
            if (event.touches.length !== 1) {
              start = null;
              return;
            }
            const touch = event.touches[0];
            start = {
              x: touch.clientX, y: touch.clientY, time: event.timeStamp,
              scrollY: window.scrollY, target: event.target,
            };
          }, options);

          window.addEventListener('touchcancel', () => { start = null; }, options);

          window.addEventListener('touchend', (event) => {
            if (!start || event.touches.length > 0) return;
            const begin = start;
            start = null;
            const touch = event.changedTouches[0];
            if (!touch) return;
            const dx = touch.clientX - begin.x;
            const dy = touch.clientY - begin.y;
            const distance = Math.hypot(dx, dy);
            if (distance < 12) {
              if (event.timeStamp - begin.time < 350) onTap(begin);
            } else if (distance >= 40) {
              if (Math.abs(dx) > Math.abs(dy) * 1.5) {
                post('hide');
              } else if (Math.abs(window.scrollY - begin.scrollY) < 10) {
                // 网页跟着滚动了的话，App 那边看滚动位置已经处理过
                post(dy < 0 ? 'hide' : 'show');
              }
            }
          }, options);
        })();
        """
}
