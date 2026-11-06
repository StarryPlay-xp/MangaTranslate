// 和 Mac 小助手通信：Chrome 按需启动小助手，通过 Native Messaging 长连接收发 JSON。
// 连接期间插件后台不会被 Chrome 停掉；一段时间没有任务就断开，小助手随之退出

export const HOST_NAME = 'io.github.starryplay_xp.mangatranslate';
const IDLE_DISCONNECT_MS = 5 * 60 * 1000;

export class HelperError extends Error {
  constructor(message, { stopsAll = false, needsSettings = false, disconnected = false } = {}) {
    super(message);
    this.stopsAll = stopsAll;
    this.needsSettings = needsSettings;
    this.disconnected = disconnected;
  }
}

let port = null;
let nextId = 1;
const pending = new Map();      // 请求编号 → { resolve, reject }
const jobHandlers = new Map();  // 任务编号 → 事件回调
let idleTimer = null;
const statusListeners = new Set();

/** 小助手当前状态：connected 表示连接还在；hello 是最近一次 hello 的结果 */
export const helperStatus = { connected: false, error: null, hello: null };

export function onStatusChange(listener) {
  statusListeners.add(listener);
}

function notify() {
  for (const listener of statusListeners) {
    try { listener(helperStatus); } catch (error) { console.error(error); }
  }
}

// Chrome 给的英文错误换成能看懂的说明
function describe(message) {
  if (!message) return '小助手已断开';
  if (/not found/i.test(message)) return '没有找到 Mac 小助手：请先在终端运行 Chrome/install.sh 安装，再重新打开 Chrome';
  if (/forbidden/i.test(message)) return '小助手不允许这个插件连接：请重新运行 Chrome/install.sh';
  if (/exited/i.test(message)) return '小助手意外退出了，下次翻译时会自动重新启动';
  return '小助手连接出错：' + message;
}

function touch() {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => {
    if (pending.size === 0 && jobHandlers.size === 0 && port) {
      port.disconnect();
      dropPort('空闲断开');
    } else {
      touch();
    }
  }, IDLE_DISCONNECT_MS);
}

function dropPort(reason) {
  port = null;
  helperStatus.connected = false;
  helperStatus.hello = null;
  helperStatus.error = reason === '空闲断开' ? null : describe(reason);
  const error = new HelperError(helperStatus.error || '小助手已断开', { disconnected: true });
  for (const { reject } of pending.values()) reject(error);
  pending.clear();
  for (const [job, handler] of jobHandlers) {
    handler({ type: 'failed', job, message: error.message, disconnected: true });
  }
  jobHandlers.clear();
  notify();
}

function connect() {
  if (port) return port;
  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch (error) {
    helperStatus.error = describe(error.message);
    notify();
    throw new HelperError(helperStatus.error, { disconnected: true });
  }
  helperStatus.connected = true;
  helperStatus.error = null;
  port.onMessage.addListener(onMessage);
  port.onDisconnect.addListener(() => dropPort(chrome.runtime.lastError?.message));
  touch();
  return port;
}

function onMessage(message) {
  touch();
  if (message.type === 'reply') {
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.ok) waiter.resolve(message.result);
    else waiter.reject(new HelperError(message.error, message));
    return;
  }
  const handler = jobHandlers.get(message.job);
  if (!handler) return;
  if (message.type === 'done' || message.type === 'failed' || message.type === 'screenDone') {
    jobHandlers.delete(message.job);
  }
  handler(message);
}

/** 发一条请求，等小助手回复 result；出错时抛 HelperError */
export function request(type, payload = {}) {
  const connection = connect();
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    try {
      connection.postMessage({ ...payload, type, id });
    } catch (error) {
      pending.delete(id);
      reject(new HelperError(describe(error.message), { disconnected: true }));
    }
  });
}

/** 开始一个翻译任务，小助手推来的事件（working、partial、done、failed、screenDone）交给 onEvent */
export function startJob(type, payload, onEvent) {
  let connection;
  try {
    connection = connect();
  } catch (error) {
    onEvent({ type: 'failed', job: payload.job, message: error.message, disconnected: true });
    return;
  }
  jobHandlers.set(payload.job, onEvent);
  try {
    connection.postMessage({ ...payload, type });
  } catch (error) {
    jobHandlers.delete(payload.job);
    onEvent({ type: 'failed', job: payload.job, message: describe(error.message), disconnected: true });
  }
}

/** 通知小助手丢掉这些任务：还没发出的段不再发 */
export function cancelJobs(jobs) {
  if (!port || jobs.length === 0) return;
  for (const job of jobs) jobHandlers.delete(job);
  try { port.postMessage({ type: 'cancel', jobs }); } catch (error) {}
}

/** 当前服务信息和并发上限；需要时重新问 */
export async function hello({ refresh = false } = {}) {
  if (helperStatus.hello && !refresh && port) return helperStatus.hello;
  const result = await request('hello');
  helperStatus.hello = result;
  helperStatus.error = null;
  notify();
  return result;
}
