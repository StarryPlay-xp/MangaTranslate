# 漫译（MangaTranslate）

自用的 iPhone App：在 App 内置的浏览器里看日漫、韩漫网页，点"翻译这一屏"后，先用 Apple Vision 在手机上找出文字，再交给 DeepSeek 看图翻译成简体中文，最后把译文贴回原来的位置。

## 目录结构

- `MangaTranslate.xcodeproj`、`MangaTranslate/`：iOS App
- `Packages/MangaCore/`：App 和验证工具共用的核心逻辑（文字识别、合并文字块、编号图、DeepSeek 翻译）
- `Tools/OCRProbe/`：Mac 上的识别与翻译验证工具，用法见它的 README
- `samples/`：验证用的截图，不提交到仓库

## 在模拟器里运行

1. 用 Xcode 打开 `MangaTranslate.xcodeproj`
2. 窗口顶部选择 `MangaTranslate` 和一台 iPhone 模拟器，按 ⌘R 运行
3. 首页点"内置示例页"。在设置里打开"试运行"，可以不联网先检查识别和贴字效果

## 装到自己的 iPhone（免费 Apple ID）

1. Xcode → Settings → Accounts，添加自己的 Apple ID
2. 在左侧选中项目 → TARGETS 里的 `MangaTranslate` → Signing & Capabilities，Team 选自己的 Personal Team。如果提示 Bundle Identifier 已被占用，改成一个别人不会用的名字
3. 用数据线连接 iPhone，在 Xcode 顶部选择这台 iPhone，按 ⌘R 运行
4. 第一次安装需要在 iPhone 上操作：设置 → 隐私与安全性 → 打开"开发者模式"并重启；然后在 设置 → 通用 → VPN 与设备管理 里信任自己的开发者证书
5. 免费签名 7 天后失效，到时连上 Mac 再运行一次就行，App 里的数据一般不会丢

选好 Team 后，项目文件里会多出一行 `DEVELOPMENT_TEAM`。这是开发者团队编号，不是密钥，提交到仓库没有问题。

## 使用方法

1. 首页右上角进入设置，粘贴 DeepSeek API Key。Key 只保存在这台设备的钥匙串里
2. 打开漫画网页，在右下角"更多"菜单里选好原文语言（日语或韩语）
3. 正常往下看就行：自动翻译默认开启，会翻译屏幕上和下方 1.5 屏以内的漫画图片，正在翻译的图右上角会显示"翻译中…"
4. 点一下译文可以临时看原文，再点一下恢复
5. 底部中间的按钮是自动翻译开关；"更多"菜单里还有"只翻译这一屏"、清除译文、加入书签

翻译过的图片会缓存译文，重看时直接显示，不再调用 DeepSeek。人名等专有名词的译法按网站记住，下一话继续沿用。缓存和术语记忆都可以在设置里清除。

翻译时，漫画图片（带编号框）和识别出的文字会发送到 DeepSeek（`api.deepseek.com`）。

## 当前版本的限制

- 自动翻译只处理网页里的普通图片（`<img>`）。漫画画在 canvas 上，或被切块打乱后再拼起来的网站，需要用"只翻译这一屏"
- 只翻译已经加载好的图片；快速滑过去的图不会翻译，滑回来时会补上
- 翻译失败的图不会自动重试；清除译文后重新打开自动翻译即可重试
- 放在内嵌框架里的图片不会被翻译
