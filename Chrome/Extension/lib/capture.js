// 取图：下载漫画原图、截取可视区域，都转成 base64 交给小助手

/** ArrayBuffer → base64（分块转换，大图也不会栈溢出） */
export function toBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

let nextRuleId = 1;

// 浏览器自己加载图片时的 Referer：同一网站给完整地址，跨网站只给来源（strict-origin-when-cross-origin）
function refererFor(src, pageUrl) {
  try {
    const image = new URL(src);
    const page = new URL(pageUrl);
    return image.origin === page.origin ? page.href.split('#')[0] : page.origin + '/';
  } catch (error) {
    return null;
  }
}

// declarativeNetRequest 的 urlFilter 里 * ^ | 有特殊含义：只取到第一个特殊字符之前
function urlFilterFor(src) {
  const url = new URL(src);
  return '||' + url.host + (url.pathname + url.search).replace(/[*^|].*$/, '');
}

/**
 * 下载图片原图：插件后台带上这个网站的 Cookie，用一条临时规则把 Referer 设成当前页面（图床常按它防盗链）。
 * 下载失败或是 blob: 地址时，让页面脚本在网页里读出来（readImage）
 */
export async function loadImage(src, pageUrl, readInPage) {
  if (src.startsWith('data:')) return src.slice(src.indexOf(',') + 1);
  if (!src.startsWith('blob:')) {
    const ruleId = nextRuleId++;
    const referer = refererFor(src, pageUrl);
    try {
      if (referer && /^https?:/.test(src)) {
        await chrome.declarativeNetRequest.updateSessionRules({
          addRules: [{
            id: ruleId,
            priority: 1,
            action: { type: 'modifyHeaders', requestHeaders: [{ header: 'referer', operation: 'set', value: referer }] },
            condition: { urlFilter: urlFilterFor(src), tabIds: [chrome.tabs.TAB_ID_NONE] },
          }],
        });
      }
      const response = await fetch(src, { credentials: 'include' });
      if (!response.ok) throw new Error('HTTP ' + response.status);
      const buffer = await response.arrayBuffer();
      if (buffer.byteLength === 0) throw new Error('图片是空的');
      return toBase64(buffer);
    } catch (error) {
      // 交给网页自己读
    } finally {
      chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: [ruleId] }).catch(() => {});
    }
  }
  const dataUrl = await readInPage(src);
  return dataUrl.slice(dataUrl.indexOf(',') + 1);
}

// Chrome 限制每秒最多截 2 次：所有截图排成一队，两次之间至少隔 550 毫秒
let captureChain = Promise.resolve();
let lastCapture = 0;

/** 截取窗口里当前标签页的可视区域，返回 ImageBitmap */
export function captureVisible(windowId) {
  const run = async () => {
    const wait = lastCapture + 550 - Date.now();
    if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
    let dataUrl;
    try {
      dataUrl = await chrome.tabs.captureVisibleTab(windowId, { format: 'png' });
    } catch (error) {
      if (!/MAX_CAPTURE/i.test(String(error?.message))) throw error;
      await new Promise((resolve) => setTimeout(resolve, 1000));
      dataUrl = await chrome.tabs.captureVisibleTab(windowId, { format: 'png' });
    } finally {
      lastCapture = Date.now();
    }
    const blob = await (await fetch(dataUrl)).blob();
    return await createImageBitmap(blob);
  };
  const result = captureChain.then(run, run);
  captureChain = result.catch(() => {});
  return result;
}

/**
 * 从截图里裁出一块。坐标是相对可视区域的 CSS 像素；截图每个 CSS 像素对应
 * 截图宽度 ÷ 窗口宽度 × 双指缩放倍数 个像素（不受滚动条影响）
 */
export async function cropToBase64(bitmap, rect, geometry, { minSize = 100 } = {}) {
  const scale = bitmap.width / geometry.innerWidth * (geometry.scale || 1);
  let left = Math.max(0, Math.floor(rect.x * scale));
  let top = Math.max(0, Math.floor(rect.y * scale));
  const right = Math.min(bitmap.width, Math.ceil((rect.x + rect.width) * scale));
  const bottom = Math.min(bitmap.height, Math.ceil((rect.y + rect.height) * scale));
  const width = right - left;
  const height = bottom - top;
  if (width < minSize || height < minSize) return null;
  const canvas = new OffscreenCanvas(width, height);
  canvas.getContext('2d').drawImage(bitmap, left, top, width, height, 0, 0, width, height);
  const blob = await canvas.convertToBlob({ type: 'image/png' });
  return toBase64(await blob.arrayBuffer());
}
