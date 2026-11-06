// 设置页：小助手状态、模型服务（Key 交给小助手存进 Mac 钥匙串，这里不保存）、用量、已开启的网站、试运行
const $ = (id) => document.getElementById(id);
const send = async (message) => {
  const result = await chrome.runtime.sendMessage(message);
  if (result?.error) throw new Error(result.error);
  return result;
};
const helper = (request, payload) => send({ type: 'helper', request, payload });

let settings = null;
let editing = null;  // 正在编辑的服务草稿；新建时没有 id

const usd = (value) => '$' + value.toFixed(value > 0 && value < 0.01 ? 6 : 4);
const hostOf = (url) => {
  try { return new URL(/^https?:\/\//.test(url) ? url : 'https://' + url).host; } catch (error) { return url; }
};

async function loadHelper() {
  const status = await send({ type: 'helperStatus' });
  $('helper-dot').className = 'dot ' + (status.connected ? 'ok' : 'bad');
  $('helper-text').textContent = status.connected ? `已连接（版本 ${status.hello.version}）` : '未连接';
  $('install').hidden = status.connected;
  $('install-error').textContent = status.error || '';
  $('extension-id').textContent = chrome.runtime.id;
  $('services-panel').hidden = !status.connected;
  if (!status.connected) {
    $('usage-panel').hidden = true;
    $('editor').hidden = true;
    return;
  }
  settings = await helper('getSettings');
  renderServices();
  await loadUsage();
}

function renderServices() {
  const list = $('services');
  list.replaceChildren();
  for (const service of settings.services) {
    const row = document.createElement('div');
    row.className = 'service' + (service.id === settings.activeServiceID ? ' active' : '');
    const radio = document.createElement('input');
    radio.type = 'radio';
    radio.name = 'active';
    radio.checked = service.id === settings.activeServiceID;
    radio.addEventListener('change', async () => {
      settings = await helper('setActive', { serviceID: service.id });
      renderServices();
      await loadUsage();
    });
    const info = document.createElement('div');
    info.className = 'info';
    const name = document.createElement('div');
    name.className = 'name';
    name.textContent = service.name;
    const summary = document.createElement('div');
    summary.className = 'summary';
    const key = service.hasKey ? '已填 Key' : service.requiresKey ? '还没填 Key' : '不需要 Key';
    summary.textContent = [
      service.config.format === 'anthropic' ? 'Anthropic' : 'OpenAI 兼容', service.config.model,
      hostOf(service.config.baseURL), service.isLocal ? '局域网' : '', key,
    ].filter(Boolean).join(' · ');
    info.append(name, summary);
    const edit = document.createElement('button');
    edit.className = 'btn small';
    edit.textContent = '编辑';
    edit.addEventListener('click', () => openEditor(service));
    row.append(radio, info, edit);
    if (settings.services.length > 1) {
      const remove = document.createElement('button');
      remove.className = 'btn small';
      remove.textContent = '删除';
      remove.addEventListener('click', async () => {
        if (!confirm(`删除「${service.name}」？它的 Key 也会从钥匙串里删掉。`)) return;
        settings = await helper('deleteService', { serviceID: service.id });
        renderServices();
      });
      row.append(remove);
    }
    list.append(row);
  }
  $('send-image').checked = settings.sendImage;
}

function openEditor(service) {
  const preset = settings.presets[0];
  editing = service
    ? { id: service.id, name: service.name, config: { ...service.config }, hasKey: service.hasKey, requiresKey: service.requiresKey }
    : { name: '', config: { format: 'openai', baseURL: '', model: '', supportsImages: true, jsonMode: true, timeoutSeconds: 300, enableThinking: false }, hasKey: false };
  $('editor-title').textContent = service ? `编辑「${service.name}」` : '添加模型服务';
  $('f-name').value = editing.name;
  $('f-format').value = editing.config.format;
  $('f-url').value = editing.config.baseURL;
  $('f-url').placeholder = preset ? preset.baseURL : '';
  $('f-model').value = editing.config.model;
  $('f-timeout').value = editing.config.timeoutSeconds;
  $('f-key').value = '';
  $('f-key').placeholder = editing.hasKey ? '已保存（不显示）；粘贴新的会替换' : '粘贴 Key；本地模型一般不需要';
  $('f-images').checked = editing.config.supportsImages;
  $('f-json').checked = editing.config.jsonMode;
  $('clear-key').hidden = !editing.hasKey;
  $('key-note').textContent = 'Key 会交给 Mac 小助手存进钥匙串，插件和这个页面都不保存。';
  $('test-result').hidden = true;
  $('editor').hidden = false;
  $('editor').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function draft() {
  return {
    ...(editing.id ? { id: editing.id } : {}),
    name: $('f-name').value.trim(),
    config: {
      ...editing.config,
      format: $('f-format').value,
      baseURL: $('f-url').value.trim(),
      model: $('f-model').value.trim(),
      timeoutSeconds: Number($('f-timeout').value) || 180,
      supportsImages: $('f-images').checked,
      jsonMode: $('f-json').checked,
    },
  };
}

function showResult(text, isError) {
  const box = $('test-result');
  box.hidden = false;
  box.className = 'bubble small' + (isError ? ' error' : '');
  box.textContent = text;
}

$('save').addEventListener('click', async () => {
  try {
    const key = $('f-key').value.trim();
    settings = await helper('saveService', { service: draft(), key: key || undefined, activate: true });
    $('f-key').value = '';
    $('editor').hidden = true;
    renderServices();
    await loadUsage();
  } catch (error) {
    showResult(error.message, true);
  }
});
$('test').addEventListener('click', async () => {
  showResult('正在测试…', false);
  try {
    const result = await helper('testConnection', { service: draft(), key: $('f-key').value.trim() || undefined });
    showResult(result.message, false);
    await loadUsage();
  } catch (error) {
    showResult(error.message, true);
  }
});
$('cancel').addEventListener('click', () => { $('editor').hidden = true; });
$('clear-key').addEventListener('click', async () => {
  settings = await helper('clearKey', { serviceID: editing.id });
  editing.hasKey = false;
  $('clear-key').hidden = true;
  $('f-key').placeholder = '粘贴 Key';
  renderServices();
});
$('add-service').addEventListener('click', () => openEditor(null));
$('send-image').addEventListener('change', async (event) => {
  settings = await helper('setSendImage', { sendImage: event.target.checked });
});
$('reconnect').addEventListener('click', loadHelper);

async function loadUsage() {
  const usage = await helper('usage');
  const show = usage.activeHasPricing || usage.total.requests > 0;
  $('usage-panel').hidden = !show;
  if (!show) return;
  const rows = [['今天', usage.today], ['本月', usage.thisMonth], ['上月', usage.lastMonth], ['累计', usage.total]];
  const body = $('usage-table').querySelector('tbody');
  body.replaceChildren(...rows.map(([label, total]) => {
    const tr = document.createElement('tr');
    for (const value of [label, total.requests, total.inputTokens.toLocaleString(), total.outputTokens.toLocaleString(), usd(total.costUSD)]) {
      const td = document.createElement('td');
      td.textContent = value;
      tr.append(td);
    }
    return tr;
  }));
}
$('clear-usage').addEventListener('click', async () => {
  if (!confirm('清除 Chrome 插件的 DeepSeek 用量记录？')) return;
  await helper('clearUsage');
  await loadUsage();
});

async function loadSites() {
  const sites = await send({ type: 'listSites' });
  const list = $('sites');
  list.replaceChildren();
  const entries = Object.entries(sites);
  if (entries.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'muted small';
    empty.textContent = '还没有开启任何网站。';
    list.append(empty);
  }
  for (const [host, site] of entries) {
    const row = document.createElement('div');
    row.className = 'site';
    const name = document.createElement('div');
    name.className = 'name';
    name.textContent = host;
    const detail = document.createElement('div');
    detail.className = 'muted small';
    detail.textContent = [site.language === 'korean' ? '韩语' : '日语', site.auto ? '自动翻译' : '', site.pageText ? '网页文字' : '']
      .filter(Boolean).join(' · ');
    const remove = document.createElement('button');
    remove.className = 'btn small';
    remove.textContent = '移除';
    remove.addEventListener('click', async () => {
      await send({ type: 'removeSite', host });
      await loadSites();
    });
    row.append(name, detail, remove);
    list.append(row);
  }
}

$('dry-run').addEventListener('change', async (event) => {
  await send({ type: 'setDryRun', dryRun: event.target.checked });
});

const { dryRun = false } = await chrome.storage.local.get('dryRun');
$('dry-run').checked = dryRun;
await loadSites();
await loadHelper();
