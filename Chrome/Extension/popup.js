// 点插件图标弹出的面板：本站开关、原文语言、只翻译这一屏、清除译文、小助手状态和今日用量
const $ = (id) => document.getElementById(id);
const send = (message) => chrome.runtime.sendMessage(message);

let tabId = null;
let state = null;

const usd = (value) => (value < 0.01 && value > 0 ? '$' + value.toFixed(4) : '$' + value.toFixed(2));

function render() {
  const helper = state.helper;
  $('helper-dot').className = 'dot ' + (helper.connected ? 'ok' : 'bad');
  if (helper.connected) {
    const service = helper.hello.service;
    $('helper-text').textContent = service.name + (helper.hello.ready ? '' : '（未填 Key）');
  } else {
    $('helper-text').textContent = '小助手未连接';
  }

  $('blocked').hidden = !state.blocked && helper.connected;
  $('blocked-text').textContent = state.blocked ? state.blocked.message : helper.error || '小助手没有回应';
  $('unsupported').hidden = Boolean(state.host);
  $('site-panel').hidden = !state.host;
  $('actions').hidden = !state.host;
  $('dry-run').hidden = !state.dryRun;
  if (state.host) {
    $('host').textContent = state.host;
    $('auto').checked = state.site.auto;
    $('page-text').checked = state.site.pageText;
    for (const button of $('language').querySelectorAll('button')) {
      button.classList.toggle('on', button.dataset.value === state.site.language);
    }
    $('pending').hidden = state.pending === 0;
    $('pending').textContent = `正在翻译 ${state.pending} 项…`;
  }
  $('last-error').hidden = !state.lastError;
  if (state.lastError) $('last-error').textContent = '上一个错误：' + state.lastError.message;
  const usage = state.usage;
  $('usage').textContent = usage
    ? `DeepSeek 今天 ${usd(usage.today.costUSD)} · 本月 ${usd(usage.thisMonth.costUSD)}` : '';
}

async function refresh() {
  state = await send({ type: 'popupState', tabId });
  render();
}

async function setSite(patch) {
  await send({ type: 'setSite', host: state.host, patch, tabId });
  await refresh();
}

$('auto').addEventListener('change', (event) => setSite({ auto: event.target.checked }));
$('page-text').addEventListener('change', (event) => setSite({ pageText: event.target.checked }));
$('language').addEventListener('click', (event) => {
  const value = event.target.closest('button')?.dataset.value;
  if (value && value !== state.site.language) setSite({ language: value });
});
$('screen').addEventListener('click', async () => {
  $('screen').disabled = true;
  $('screen').textContent = '正在翻译…';
  // 面板开着时截图会截到面板外的网页，没有影响；翻完关掉面板，看结果
  const result = await send({ type: 'translateScreen', tabId });
  if (result?.error) {
    $('screen').disabled = false;
    $('screen').textContent = '只翻译这一屏';
    await refresh();
  } else {
    window.close();
  }
});
$('clear').addEventListener('click', async () => {
  await send({ type: 'clearPage', tabId });
  await refresh();
});
$('retry').addEventListener('click', async () => {
  await send({ type: 'retry' });
  await refresh();
});
for (const id of ['open-settings', 'open-settings-blocked']) {
  $(id).addEventListener('click', () => chrome.runtime.openOptionsPage());
}

// ?tab= 只用于测试：把面板当普通网页打开时指定要看的标签页
const forced = Number(new URLSearchParams(location.search).get('tab'));
const [tab] = forced ? [{ id: forced }] : await chrome.tabs.query({ active: true, currentWindow: true });
tabId = tab?.id;
await refresh();
// 翻译进度每秒刷新一次
setInterval(refresh, 1000);
