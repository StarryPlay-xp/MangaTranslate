# 漫译 Chrome 插件（Mac）

在 Mac 上的 Chrome 里看日漫、韩漫网页时自动翻译，效果和 iPhone / iPad 上的漫译一样：先在本机用 Apple Vision 找出文字，再交给大模型看图翻译成简体中文，最后把译文贴回原来的位置。

插件分两部分：

- **插件**（`Extension/`）：在网页里找漫画图片、取图或截图，把译文贴回网页。
- **Mac 小助手**（`Helper/`）：一个小程序，由 Chrome 在需要时自动启动、不用时自动退出。识别文字和调用模型都由它完成，和 App 共用 `Packages/MangaCore`。

只支持 Mac。设置、术语表、译文缓存和用量记录存在这台 Mac 上，API Key 存在 Mac 钥匙串里，这些和 iPhone / iPad 上的 App 互不相通。

## 安装

1. 打开"终端"，进入漫译项目文件夹，运行安装脚本。它会编译小助手（第一次要一两分钟），复制到 `~/Library/Application Support/MangaTranslate Chrome/bin/`，再登记给 Chrome：

   ```bash
   Chrome/install.sh
   ```

2. 完全退出 Chrome（⌘Q），再重新打开。
3. 地址栏输入 `chrome://extensions`，打开右上角的"开发者模式"。
4. 点"加载已解压的扩展程序"，选择项目里的 `Chrome/Extension` 文件夹。macOS 如果问"Google Chrome 想访问'文稿'文件夹中的文件"，选"允许"。
5. 在漫译插件上点"详细信息 → 扩展程序选项"，打开设置页：
   - 页面顶部显示"已连接"，说明小助手装好了。
   - 在"模型服务"里点 DeepSeek 的"编辑"，粘贴 API Key，再点"保存并使用"。Key 会立刻交给小助手存进钥匙串，插件本身不保存。
6. 把漫译固定到工具栏：点 Chrome 右上角的拼图图标，再点漫译旁边的图钉。

插件的 ID 是固定的（`gkghibbflnabefngldccgikgnaeolobi`），小助手只允许这个 ID 连接。

**更新**：拉取新代码后重新运行 `Chrome/install.sh`，再到 `chrome://extensions` 点漫译上的刷新按钮。

**其他基于 Chromium 的浏览器**：先用 `MANGA_CHROME_DIR` 指定这个浏览器的资料目录，再运行安装脚本。以 Edge 为例：

```bash
MANGA_CHROME_DIR="$HOME/Library/Application Support/Microsoft Edge" Chrome/install.sh
```

**卸载**：删掉小助手和 Chrome 里的登记。加上 `--all` 时，设置、术语表、用量记录、译文缓存和钥匙串里的 Key 也一起删掉。插件本身在 `chrome://extensions` 里移除。

```bash
Chrome/uninstall.sh
```

## 使用

打开漫画网站，点工具栏上的漫译图标：

- **自动翻译本站漫画**：按网站分别开关，开启后这个网站上的漫画会自动翻译。滚动或翻页时，屏幕上和下方 3 屏以内的图会依次翻好；左右翻页的阅读器，还会提前翻好左右相邻的几页。
- **原文语言**：按网站分别记住。App 收录的韩漫平台默认是韩语，其他网站默认是日语。
- **网页文字翻译**：把网页上的标题、简介、按钮文字也换成中文，关掉后恢复原文。只看页面文字的话，也可以用 Chrome 自带的翻译。
- **只翻译这一屏**：截下当前看到的画面，整屏识别后翻译。适合自动翻译找不到图的网站。
- **清除译文**：去掉这一页已经贴上的译文，然后重新翻译；有缓存的图会直接用缓存。

其他说明：

- 点一下译文，可以临时看原文；再点一下恢复。
- 图片右上角出现三个点，表示正在翻译。
- 工具栏图标上的数字，是这一页还在排队和翻译中的数量；变成"!"表示翻译暂停了，比如缺 Key、余额不足或连不上服务。点开面板可以看原因，问题处理好后点"重试"。
- 插件只在开启了的网站上运行，其他网站上什么都不做。
- 设置页可以：
  - 添加别的模型服务（OpenAI 兼容或 Anthropic 格式，也可以是局域网里的本地模型）
  - 查看 DeepSeek 用量
  - 管理已开启的网站
  - 打开"试运行"，不调用模型，只显示识别出的原文

## 遇到问题

- **设置页显示"没有找到 Mac 小助手"**：运行 `Chrome/install.sh`，然后完全退出 Chrome 再打开。
- **加载插件时提示读不到 manifest**：Chrome 没有访问"文稿"文件夹的权限。到"系统设置 → 隐私与安全性 → 文件与文件夹"，允许 Google Chrome 访问"文稿"，然后重新加载插件。
- **弹窗问"manga-translate-helper 想使用钥匙串里的机密信息"**：小助手每次重新编译后，第一次读 Key 时 macOS 会这样问，输入 Mac 登录密码，再点"始终允许"。
- **小助手日志**：在 `~/Library/Application Support/MangaTranslate Chrome/helper.log`。只记数量、耗时和错误，不记图片地址、网页文字和 Key。

## 当前版本的限制

- 和 App 一样：漫画画在 canvas 上的网站要等这一页完整停在屏幕上才截图翻译，不能提前翻。截图时必须是当前标签页；切到别的标签页时，canvas 页会暂停翻译，切回来后继续。
- 只处理主页面，嵌在 iframe 里的图片和文字不会翻译。
- 已经验证过的：本机测试页加模拟模型服务，覆盖条漫、长图分段、canvas、左右双页、只翻译这一屏、网页文字、缓存、缺 Key 提示和小助手断开重连。
- 还没有验证的：真实漫画网站的电脑版页面、真实 DeepSeek 请求，以及钥匙串在你这台 Mac 上的实际弹窗情况。

## 开发

- 小助手：`cd Chrome/Helper && swift test`
- 插件是纯 JavaScript，不需要编译。改了代码后，到 `chrome://extensions` 点刷新。
- 插件和小助手之间的消息格式见 `Helper/Sources/HelperCore/Messages.swift`。
- 页面脚本 `Extension/content/overlay.js` 和 `pagetext.js` 移植自 App 的 `OverlayScript.swift` 和 `PageTextScript.swift`。改找图或贴字规则时两边都要改。
