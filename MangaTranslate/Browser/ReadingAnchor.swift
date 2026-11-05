import Foundation

/// 记下阅读位置时的版面宽度和屏幕顶部那张图。iPad 转屏、调整窗口后网页按新宽度重新排版，
/// 条漫的图跟着宽度缩放，按原来的像素位置会回到别处，这时改成"回到那张图的同一位置"
struct ReadingAnchor: Codable, Hashable {
    /// 记录时网页的版面宽度（CSS 像素）
    var pageWidth: Double
    /// 看到的位置占整页高度的比例，找不到那张图时用
    var ratio: Double
    /// 屏幕顶部那张图；网页上没有大图时为空
    var image: Image?

    struct Image: Codable, Hashable {
        /// 图片地址
        var source: String
        /// 是网页里的第几张图（document.images 的序号）
        var index: Int
        /// 屏幕顶部在这张图的哪个位置：0 是图的上边，1 是下边；图在屏幕顶部下方时是负数
        var fraction: Double
    }

    /// 读取当前的锚点，返回 JSON
    static let readScript = """
        const view = document.documentElement;
        const v = window.visualViewport;
        const top = v ? v.offsetTop : 0;
        const bottom = top + (v ? v.height : window.innerHeight);
        const images = Array.from(document.images);
        let image = null;
        // 按网页顺序找第一张露在屏幕上的大图（小图标、头像不算）
        for (let index = 0; index < images.length; index++) {
          const rect = images[index].getBoundingClientRect();
          if (rect.width < 150 || rect.height < 100) continue;
          if (rect.bottom <= top || rect.top >= bottom || rect.right <= 0 || rect.left >= view.clientWidth) continue;
          image = {
            source: images[index].currentSrc || images[index].src,
            index,
            fraction: (top - rect.top) / rect.height,
          };
          break;
        }
        return JSON.stringify({
          pageWidth: view.clientWidth,
          ratio: view.scrollHeight > 0 ? window.scrollY / view.scrollHeight : 0,
          image,
        });
        """

    /// 回到上次的位置，参数 y（上次的像素位置）、anchor（锚点 JSON，旧记录没有时是空字符串）、
    /// last（最后一次尝试，不再等网页加载）。滚动了返回 true，网页还没加载到那里返回 false
    static let restoreScript = """
        const view = document.documentElement;
        const saved = anchor ? JSON.parse(anchor) : null;
        const enough = (target) => view.scrollHeight >= target + window.innerHeight * 0.5;
        // 版面宽度没变，或者旧记录没有锚点：按原来的像素位置
        if (!saved || Math.abs(view.clientWidth - saved.pageWidth) < 2) {
          if (!enough(y) && !last) return false;
          window.scrollTo(0, y);
          return true;
        }
        // 宽度变了：先找那张图。优先同一序号且地址相同的；地址相同但序号变了的取序号最近的；
        // 都没有就用同一序号的（宽度不同时网页可能换了另一种分辨率的图片地址）
        const saw = saved.image;
        if (saw) {
          const images = Array.from(document.images);
          const sourceOf = (img) => img.currentSrc || img.src;
          let img = images[saw.index] && sourceOf(images[saw.index]) === saw.source ? images[saw.index] : null;
          if (!img) {
            let best = Infinity;
            images.forEach((other, index) => {
              if (sourceOf(other) === saw.source && Math.abs(index - saw.index) < best) {
                best = Math.abs(index - saw.index);
                img = other;
              }
            });
          }
          img = img || images[saw.index] || null;
          if (img) {
            const rect = img.getBoundingClientRect();
            // 图还没排好版（懒加载的图可能还没有高度）就等下一次
            if (rect.height >= 50) {
              const target = rect.top + window.scrollY + saw.fraction * rect.height;
              if (enough(target) || last) {
                window.scrollTo(0, Math.max(target, 0));
                return true;
              }
            }
            if (!last) return false;
          }
        }
        // 没有图可对：按占整页高度的比例，等网页加载完再算
        if (document.readyState !== 'complete' && !last) return false;
        window.scrollTo(0, saved.ratio * view.scrollHeight);
        return true;
        """
}
