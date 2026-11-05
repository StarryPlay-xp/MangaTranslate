# OCRProbe：识别与翻译验证工具

阶段 0（技术验证）用的 Mac 命令行小工具，分两步：

1. `run`：用 Apple Vision（和 iPhone 上是同一套框架）识别漫画截图里的文字，生成标注图和 HTML 报告，判断本地识别够不够用。只在本机运行，不联网。
2. `translate`：把第 1 步找到的文字块编号画在图上，连同识别文字一起发给大模型翻译，生成译文预览图和报告，判断翻译质量、速度和费用。默认用 DeepSeek，也可以换成其他服务或本机、局域网里的模型。**这一步会联网，把图片和文字发送到你指定的模型服务。**

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
- **红框 + 编号**：检测到有文字、但没认出内容的文字块。这种块之后交给模型看图识别，问题不大
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

运行后终端会提示粘贴 API Key，输入时不会显示，也不会保存到任何文件。如果你已经在环境变量 `LLM_API_KEY`（DeepSeek 也认 `DEEPSEEK_API_KEY`）里设置了 Key，就不会再提示。局域网地址默认不要 Key。

完成后打开报告：

```bash
open output/translate/report.html
```

报告里每页有两张图：左边是发给模型的图（红框加编号），右边是译文预览，模拟 App 里的显示效果。下面的表格列出每个编号的本地识别结果、模型核对后的原文和译文，页首汇总了 token 用量和估算费用。

会发送给模型服务的内容：
- 每页一张带红框编号的截图（JPEG）
- 每个编号的本地识别文字、前几页的译文和术语表
- 固定的翻译要求（系统提示词）

可选参数：
- `--limit 3`：只处理前 3 页
- `--text-only`：只发文字不发图片，用来对比有图和没图的翻译效果
- `--thinking`：开启 DeepSeek 的思考模式，更慢也更贵，用来对比难页的效果（只对 DeepSeek 生效）
- `--dry-run`：试运行，不联网也不需要 Key，在 `requests/` 里生成每页要发送的请求内容（图片内容省略），方便核对
- `--reply-format full|nosource|compact|compact-source`：模型回复的写法，默认 `full`（App 现在用的）。`nosource` 不再抄写原文；`compact` 每块写成 `[编号, 类型, 译文]` 数组，也不抄原文；`compact-source` 每块写成 `[编号, 核对后的原文, 译文, 类型]` 数组，照样先抄原文、只省掉键名。后几种回复更短、生成更快，可能影响翻译质量。第一轮对比里，不抄原文的两种人名、短句错得明显更多

### 对比回复写法

`--reply-format` 用逗号写多个时，每页把各种写法各翻一次（每页换一个先后顺序，免得某种写法总碰上同样的网络状况），每种写法各自积累术语和前文：

```bash
swift run --package-path Tools/OCRProbe ocrprobe translate samples output/ocr-probe output/reply-compare \
  --reply-format full,nosource,compact
```

请求次数是页数乘以写法数，费用也相应翻倍。完成后打开 `output/reply-compare/compare.html`：上面是各写法的成功率、重试次数、平均和最慢耗时、平均输入输出 token、模型漏掉的块数；耗时和 token 只统计所有写法都成功的页。下面每页一张表，并排列出各写法的类型和译文，类型和 `full` 不一样的格子标成黄色。各写法的完整报告在对应的子目录里，`compare.json` 是同样内容的数据文件。

换模型服务（和 App 设置里的含义一样）：
- `--format openai|anthropic`：接口格式，默认 `openai`（OpenAI 兼容）
- `--base-url <地址>`：请求地址，带不带 `/v1` 都行，默认 `https://api.deepseek.com`
- `--model <模型名>`：换了地址或格式时必填
- `--no-json-mode`：不发 `response_format`，给不支持 JSON 模式的模型用
- `--timeout <秒>`：最长等待时间，默认 180 秒
- `--no-key`：不要 Key

只有 deepseek-flash 会估算费用，其他模型只统计 token。对比几个模型时，给每次运行换一个输出目录，再分别打开报告：

```bash
swift run --package-path Tools/OCRProbe ocrprobe translate samples output/ocr-probe output/translate-qwen --limit 3 \
  --base-url http://192.168.1.10:11434 --model qwen2.5vl:7b --timeout 600
```

正式翻译前可以先测一下连接，只发一条很短的文字请求：

```bash
swift run --package-path Tools/OCRProbe ocrprobe ping --base-url http://192.168.1.10:11434 --model qwen2.5vl:7b
```

## 其他命令和参数

- `ocrprobe fixtures <目录>`：生成两张合成测试页，没有真实样本时用来自测
- `ocrprobe languages`：列出本机 Vision 支持的识别语言
- `--lang ja-JP,ko-KR`：手动指定识别语言，不按子目录名自动选
- `--gap 0.6`：合并文字块时允许的间距，单位是字符大小。气泡被拆散就调大，相邻气泡被合并就调小

## 输出内容

- `report.html`：可视化报告
- `annotated/`：标注图
- `results.json`：每页文字块的坐标和识别结果，下一步发给模型翻译时会用到
