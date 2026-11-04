# OCRProbe：识别与翻译验证工具

阶段 0（技术验证）用的 Mac 命令行小工具，分两步：

1. `run`：用 Apple Vision（和 iPhone 上是同一套框架）识别漫画截图里的文字，生成标注图和 HTML 报告，判断本地识别够不够用。只在本机运行，不联网。
2. `translate`：把第 1 步找到的文字块编号画在图上，连同识别文字一起发给 DeepSeek 翻译，生成译文预览图和报告，判断翻译质量、速度和费用。**这一步会联网，把图片和文字发送到 DeepSeek。**

识别、合并、编号图和翻译提示词都在 `Packages/MangaCore` 里，和 App 共用同一份代码。在这里调好的参数，App 里会同样生效。

## 准备样本

把截图放进项目根目录的 `samples/`：

- 日漫放 `samples/ja/`：按日文识别，编号按从右到左的顺序
- 韩漫放 `samples/ko/`：按韩文识别，编号按从左到右的顺序

支持 png、jpg、jpeg、heic、webp。

## 运行

在项目根目录（`MangaTranslate/`）执行：

```bash
swift run --package-path Tools/OCRProbe ocrprobe run samples output/ocr-probe
```

第一次运行要先编译，稍等片刻。完成后打开报告：

```bash
open output/ocr-probe/report.html
```

## 怎么看报告

- **绿框 + 编号**：合并后的文字块，App 里每块对应一处译文
- **红框 + 编号**：检测到有文字、但没认出内容的文字块。这种块之后交给 DeepSeek 看图识别，问题不大
- **蓝框**：识别出文字的行（竖排时是一列）
- **橙框**：检测到的文字区域，不管认不认得出字

重点看三件事：

1. 有没有气泡**完全没被框到**。这是最要紧的，没有框就没地方放译文
2. 一个气泡是不是被拆成了好几块，或者相邻的几个气泡被合成了一块
3. 编号顺序和你实际阅读的顺序是否大致一致

## 翻译验证

先跑完上面的识别，再在项目根目录执行。建议先用 `--limit 3` 只翻前 3 页试试：

```bash
swift run --package-path Tools/OCRProbe ocrprobe translate samples output/ocr-probe output/translate --limit 3
```

运行后终端会提示粘贴 DeepSeek API Key，输入时不会显示，也不会保存到任何文件。如果你已经在环境变量 `DEEPSEEK_API_KEY` 里设置了 Key，就不会再提示。

完成后打开报告：

```bash
open output/translate/report.html
```

报告里每页有两张图：左边是发给模型的图（红框加编号），右边是译文预览，模拟 App 里的显示效果。下面的表格列出每个编号的本地识别结果、模型核对后的原文和译文，页首汇总了 token 用量和估算费用。

会发送给 DeepSeek 的内容：
- 每页一张带红框编号的截图（JPEG）
- 每个编号的本地识别文字、前几页的译文和术语表
- 固定的翻译要求（系统提示词）

可选参数：
- `--limit 3`：只处理前 3 页
- `--text-only`：只发文字不发图片，用来对比有图和没图的翻译效果
- `--thinking`：开启 DeepSeek 的思考模式，更慢也更贵，用来对比难页的效果
- `--dry-run`：试运行，不联网也不需要 Key，在 `requests/` 里生成每页要发送的请求内容（图片内容省略），方便核对
- `--model <模型名>`：换模型；费用估算只按 deepseek-flash 的价格计算

## 其他命令和参数

- `ocrprobe fixtures <目录>`：生成两张合成测试页，没有真实样本时用来自测
- `ocrprobe languages`：列出本机 Vision 支持的识别语言
- `--lang ja-JP,ko-KR`：手动指定识别语言，不按子目录名自动选
- `--gap 0.6`：合并文字块时允许的间距，单位是字符大小。气泡被拆散就调大，相邻气泡被合并就调小

## 输出内容

- `report.html`：可视化报告
- `annotated/`：标注图
- `results.json`：每页文字块的坐标和识别结果，下一步发给 DeepSeek 翻译时会用到
