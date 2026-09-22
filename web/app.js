/* ==========================================================================
   账号管理器 · 前端逻辑
   ------------------------------------------------------------------------
   与 Swift 侧的约定：
     · 调用：window.webkit.messageHandlers.bridge.postMessage({id, method, params})
     · 回调：window.__bridgeResolve({id, ok, result|error})
   安全约定：
     · 界面默认只显示掩码与指纹；只有用户显式打开「显示明文」才会向前端回传明文
     · 所有写入动作都需要「先生成计划 → 再确认写入」两步
   ========================================================================== */

'use strict';



/* ---------- 桥接 ---------- */

const pending = new Map();
let seq = 0;

window.__bridgeResolve = function (payload) {
  const entry = pending.get(payload.id);
  if (!entry) return;
  pending.delete(payload.id);
  if (payload.ok) entry.resolve(payload.result);
  else entry.reject(new Error(payload.error || '未知错误'));
};

function call(method, params) {
  return new Promise((resolve, reject) => {
    if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.bridge) {
      reject(new Error('桥接不可用：请通过 账号管理器应用打开本页面'));
      return;
    }
    const id = 'r' + (++seq);
    pending.set(id, { resolve, reject });
    window.webkit.messageHandlers.bridge.postMessage({ id: id, method: method, params: params || {} });
    setTimeout(() => {
      if (pending.has(id)) {
        pending.delete(id);
        reject(new Error('调用超时：' + method));
      }
    // 模型发现会真实请求上游 /models，超时放宽到 120s
    }, 120000);
  });
}

/* ---------- 状态 ---------- */

const state = {
  page: 'keys',
  providers: [],
  targets: [],
  keys: [],
  audit: [],
  plan: null,
  outcome: null,
  reveal: false,
  auditFilter: 'all',
  info: {},
  lastInjectForm: null,
  selectedTargetID: '',
  targetFilter: 'all',
  editingKey: null,
  editingTarget: null,
  // 密钥库分区视图（REQ-019）：由 call('keysGrouped') 填充
  keyGroups: [],
  // 每把 key 的模型发现结果（REQ-020）：keyID -> discovery
  discoveries: {},
  // 分区折叠状态（会话内记忆）
  collapsedGroups: {},
  keysSearch: '',
  keysOnlyAttention: false,
  // 当前打开的密钥详情（REQ-021）
  detailKeyID: null,
  // 跨宿主模型清单（DSH + Codex），由 call('hostModels') 填充
  hostModelGroups: [],
  gatewayInfo: null,
  syncPlan: null,
  hostModelsOverview: null,
  modelsOverview: null,
  models: []
};

/* ---------- 工具 ---------- */

const $ = (sel) => document.querySelector(sel);

function updateStepper(step) {
  const el = $('#inject-stepper');
  if (!el) return;
  el.querySelectorAll('.step').forEach((s) => {
    const sNum = parseInt(s.dataset.step, 10);
    s.classList.toggle('active', sNum === step);
    s.classList.toggle('done', sNum < step);
  });
}

function getTargetCategory(t) {
  if (t.isCustom) return 'custom';
  if (t.id.includes('dsh') || t.id.includes('codex') || t.id.includes('claude')) return 'desktop';
  if (t.id.includes('shell') || t.id.includes('dotenv') || t.format === 'dotenv' || t.format === 'shellExport') return 'dev';
  return 'custom';
}

function getTargetIcon(t) {
  if (t.id.includes('dsh')) return '🤖';
  if (t.id.includes('codex')) return '⚡';
  if (t.id.includes('claude')) return '🟣';
  if (t.format === 'shellExport' || t.id.includes('shell')) return '🐚';
  if (t.format === 'dotenv' || t.id.includes('dotenv')) return '📄';
  if (t.format === 'plist') return '⚙️';
  return '🧩';
}

function esc(s) {
  return String(s === undefined || s === null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function banner(kind, text) {
  const host = $('#banner-host');
  host.innerHTML = '<div class="banner ' + kind + '"><span class="msg">' + esc(text) +
    '</span><button class="icon-btn" onclick="this.parentNode.remove()">✕</button></div>';
  if (kind === 'success' || kind === 'info') {
    setTimeout(() => { if (host.firstChild) host.innerHTML = ''; }, 6000);
  }
}

function statusClass(status) { return 's-' + (status || 'unchecked'); }
function statusTextClass(status) { return 't-' + (status || 'unchecked'); }

function providerName(id) {
  const p = state.providers.find((x) => x.id === id);
  return p ? p.name : id;
}

function targetById(id) { return state.targets.find((t) => t.id === id); }
function providerById(id) { return state.providers.find((p) => p.id === id); }

function fmtTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  const p = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' +
         p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

/**
 * 只到日期（不带时分秒），用于「模型发布时间」这类**厂商侧的事实**。
 *
 * 为什么单独一个函数：日期与时间戳混排时，同一列里有的长有的短会破坏对齐；
 * 模型发布时间本身也只精确到天，展示到秒属于虚假精度。
 * 兼容三种输入：Swift Date 默认编码（秒级 Double）、毫秒级数字、ISO 字符串。
 */
function fmtDate(value) {
  if (value === null || value === undefined || value === '') return '—';
  let d;
  if (typeof value === 'number') {
    d = new Date(value < 1e11 ? value * 1000 : value);
  } else {
    d = new Date(value);
  }
  if (isNaN(d.getTime())) return String(value);
  const p = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}

/* ---------- 导航 ---------- */

/**
 * 切换主页面。
 *
 * REQ-025 起「模型清单」不再是一个独立标签页，而是**密钥页内的可折叠总览**：
 * 格式塔的邻近性与共同区域要求「一把 Key 和它供给的模型」出现在同一容器里，
 * 跨页跳转会把同一条信息链切断。为兼容旧入口（书签、截图脚本、
 * 自动化钩子 window.__selectPage('models')），`models` 参数仍被接受，
 * 但会落到密钥页并自动展开总览。
 */
function switchPage(page, options) {
  const opts = options || {};
  if (page === 'models') page = 'keys';   // 旧入口兼容：不再存在独立页面
  state.page = page;
  document.querySelectorAll('.nav-item').forEach((el) => {
    el.classList.toggle('active', el.dataset.page === page);
  });
  document.querySelectorAll('.page').forEach((el) => {
    el.classList.toggle('hidden', el.id !== 'page-' + page);
  });
  if (page === 'inject') {
    renderInjectPicker();
    renderPlan();
    renderRollbackList();
  } else if (page === 'keys') {
    renderKeys();
    // 首帧就把跨宿主总览的摘要填好，用户不必展开也能知道有几个模型
    renderOverviewSummary();
    // 跨宿主总览与密钥列表同页：从旧入口或旧钩子进来时要把它展开并滚到视野内
    if (opts.overview) {
      const fold = $('#keys-overview');
      if (fold) fold.open = true;
      loadModels();
      if (opts.scrollToOverview) fold.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  }
}

/**
 * 折叠区标题上的摘要（不展开也能读到关键数字）。
 *
 * 为什么值得单独做：格式塔的闭合性要求「收起的状态也要能回答问题」——
 * 用户收起总览时仍然需要知道模型总数与同步状态，否则每次都得展开一次。
 */
function renderOverviewSummary() {
  const el = $('#overview-summary');
  if (!el) return;
  const ov = state.hostModelsOverview || {};
  const plan = state.syncPlan || null;
  if (ov.loadError) {
    el.textContent = '读取失败：' + ov.loadError;
    return;
  }
  const parts = ['模型身份 ' + (ov.uniqueModels || 0) + ' 个'];
  if (ov.boundKeyCount) parts.push('已绑定密钥 ' + ov.boundKeyCount + ' 把');
  parts.push(plan ? (plan.allConsistent ? '两个宿主已一致' : '存在差异待同步') : '同步状态未知');
  el.textContent = parts.join(' · ');
}

document.querySelectorAll('.nav-item').forEach((el) => {
  el.addEventListener('click', () => switchPage(el.dataset.page));
});

/* ---------- 数据加载 ---------- */

async function loadAll() {
  state.info = await call('info');
  state.providers = await call('providers');
  state.targets = await call('targets');
  await loadKeys();
  await loadHostModels();
  await loadAudit();
  renderFoot();
}

/// 读取跨宿主模型清单总览。失败不应阻断启动：
/// 宿主配置文件可能不存在（例如未装 Codex），此时如实降级而不是白屏。
async function loadHostModels() {
  try {
    const data = await call('hostModels');
    state.hostModelGroups = data.groups || [];
    state.hostModelsOverview = data.overview || {};
    state.hostProviders = data.dshProviders || [];
    state.gatewayInfo = data.gateway || null;
    state.syncPlan = data.sync || null;
  } catch (err) {
    state.hostModelGroups = [];
    state.hostModelsOverview = { loadError: String(err.message || err) };
    state.hostProviders = [];
    state.gatewayInfo = null;
    state.syncPlan = null;
  }
  renderNavCounts();
}

async function loadKeys() {
  state.keys = await call('keys', { reveal: state.reveal });
  // 分区视图与「已缓存的模型发现结果」一起加载。
  // 关键取舍：首帧**只读缓存**（call('availableModels') 不联网），
  // 否则打开密钥库就会对所有端点发起真实请求（与「不做后台轮询」的既定边界冲突）。
  try {
    // 桥接返回的分区字段名是 records（与后端 KeyGroup 一致），前端统一改名为 keys 使用，
    // 否则 group.keys 恒为 undefined，会让「看起来正常」的界面悄悄走错分支。
    const raw = await call('keysGrouped', { reveal: state.reveal });
    state.keyGroups = (raw || []).map((g) => ({
      label: g.label,
      modelCount: g.modelCount,
      keys: g.records || g.keys || []
    }));
  } catch (err) {
    state.keyGroups = [];
  }
  try {
    state.discoveries = await call('availableModels');
  } catch (err) {
    state.discoveries = {};
  }
  renderKeys();
  renderHealth();
  renderNavCounts();
}

/// 显式探测单把密钥的可用模型（真实联网，只在用户点击时发生）
async function discoverKey(id) {
  const result = await call('discoverKey', { id: id });
  state.discoveries[id] = result;
  return result;
}

/// 显式探测全部密钥的可用模型
async function discoverAllKeys() {
  const res = await call('discoverAll', {});
  Object.keys(res.results || {}).forEach((id) => { state.discoveries[id] = res.results[id]; });
  return res;
}

/// 模型的推荐排序：探测到的排前面，同来源按名称
function sortModels(models) {
  const rank = { probe: 0, hostMapped: 1, inferred: 2, unknown: 3 };
  return models.slice().sort((a, b) => {
    const ra = rank[a.source] === undefined ? 9 : rank[a.source];
    const rb = rank[b.source] === undefined ? 9 : rank[b.source];
    if (ra !== rb) return ra - rb;
    return String(a.modelID).localeCompare(String(b.modelID));
  });
}

/// 合并同类模型（去重按模型名归一化），保留置信度最高的一条
function dedupeModels(models) {
  const rank = { probe: 0, hostMapped: 1, inferred: 2, unknown: 3 };
  const keyOf = (id) => String(id).toLowerCase().replace(/^models\//, '').replace(/[^a-z0-9]/g, '');
  const best = {};
  models.forEach((m) => {
    const k = keyOf(m.modelID);
    if (!k) return;
    const cur = best[k];
    const r = rank[m.source] === undefined ? 9 : rank[m.source];
    const curR = cur ? (rank[cur.source] === undefined ? 9 : rank[cur.source]) : 99;
    if (!cur || r < curR) best[k] = m;
  });
  return sortModels(Object.keys(best).map((k) => best[k]));
}

async function loadAudit() {
  state.audit = await call('audit', { limit: 120 });
  renderAudit();
  renderRollbackList();
  renderNavCounts();
}

function renderFoot() {
  $('#foot-backend').textContent = '密钥后端：' + (state.info.storeBackend || '—');
  $('#foot-counts').textContent = state.keys.length + ' 个密钥 · ' + state.targets.length + ' 个落点';
  const ver = state.info.version ? ('v' + state.info.version) : 'v1.1.0';
  if ($('#app-version-badge')) $('#app-version-badge').textContent = ver;
  if ($('#global-version-pill')) $('#global-version-pill').innerHTML = '<span class="pulse-dot"></span>' + ver + ' 已就绪';
  if ($('#modal-version-tag')) $('#modal-version-tag').textContent = ver;
}

function renderNavCounts() {
  const setCount = (sel, text) => {
    const el = $(sel);
    el.textContent = text;
    el.style.display = text ? '' : 'none';
  };
  setCount('#count-keys', state.keys.length ? String(state.keys.length) : '');
  setCount('#count-audit', state.audit.length ? String(state.audit.length) : '');
  const bad = state.keys.filter((k) => {
    const s = (k.lastCheck || {}).status;
    return s === 'invalid' || s === 'quota';
  }).length;
  setCount('#count-health', bad ? '⚠' + bad : '');
}

/* ---------- 密钥库 ---------- */

/* ---------- 密钥库：名字分区 + 模型识别（REQ-019 / REQ-020） ---------- */

/**
 * 模型行内的元数据片段（REQ-024 维度②「更新日期」/ 维度③ 版本）。
 *
 * 事实依据（docs/knowledge-account-protocols.md）：
 *  · OpenAI 形状给 `created`（**发布时间**）与 `shutdown_date`（下线公告）；
 *  · DeepSeek 形状只给 id/object/owned_by，**没有任何时间字段**；
 *  · Gemini 的 `version`（如 001）是**版本序号不是时间**，必须标成「版本」。
 * 协议没给的维度一律显式写「该协议不提供」，绝不用本机时间冒充。
 */
function modelMetaLine(meta) {
  if (!meta) return '<span class="km-meta dim">更新时间：该协议不提供</span>';
  const parts = [];
  if (meta.publishedAt) {
    parts.push('<span class="km-meta" title="' + esc(meta.publishedSource || '协议提供') + '">更新时间 ' +
      esc(fmtDate(meta.publishedAt)) + '</span>');
  } else {
    parts.push('<span class="km-meta dim">更新时间：该协议不提供</span>');
  }
  if (meta.versionTag) parts.push('<span class="km-meta dim" title="版本序号，不是日期">版本 ' + esc(meta.versionTag) + '</span>');
  if (meta.shutdownDate) parts.push('<span class="km-meta bad-text" title="服务商公告的下线时间">下线 ' + esc(meta.shutdownDate) + '</span>');
  return parts.join('');
}

/// 账号额度块（REQ-024 维度②：「剩余额度」属于账号级，不属于单个模型）
function renderBalanceLine(discovery) {
  const b = discovery && discovery.balance;
  if (!b) return '';
  if (b.supported === false) {
    return '<div class="key-balance bal-none"><b>账户额度</b>' +
      '<span>该协议不提供</span>' +
      '<span class="dim">' + esc(b.note || '该厂商的公开接口没有余额端点') + '</span></div>';
  }
  const cls = b.isAvailable === false ? 'bal-warn' : (b.isAvailable ? 'bal-ok' : 'bal-none');
  const gate = b.isAvailable === true ? '可调用' : (b.isAvailable === false ? '余额不足' : '未判定');
  let html = '<div class="key-balance ' + cls + '"><b>账户额度</b><span class="bal-gate">' + gate + '</span>';
  const entries = b.entries || [];
  if (entries.length) {
    entries.forEach((e) => {
      html += '<span class="bal-amount">' + esc(String(e.total || '—')) + ' ' + esc(e.currency || '') + '</span>';
      if (e.granted || e.toppedUp) {
        html += '<span class="dim small">（赠送 ' + esc(String(e.granted || '0')) + ' / 充值 ' + esc(String(e.toppedUp || '0')) + '）</span>';
      }
    });
  } else {
    html += '<span class="dim">未返回余额明细</span>';
  }
  if (b.fetchedAt) html += '<span class="dim small">取于 ' + esc(fmtTime(b.fetchedAt)) + '</span>';
  html += '</div>';
  return html;
}

/// 模型条目的一行（分区卡片与详情弹窗共用）
function modelEntry(id, model) {
  return '<div class="detail-model-row" data-model="' + esc(model.modelID) + '">' +
    '<span class="status ' + (model.source === 'probe' ? 's-valid' : 's-unchecked') + '"></span>' +
    '<code class="km-model-id">' + esc(model.modelID) + '</code>' +
    modelMetaLine(model.metadata) +
    (model.source ? '<span class="chip src-' + esc(model.source) + '">' + esc(model.sourceLabel || model.source) + '</span>' : '') +
    (model.confidence ? '<span class="small dim">' + esc(model.confidence) + '</span>' : '') +
    (model.hostLabel ? '<span class="chip plain">' + esc(model.hostLabel) + '</span>' : '') +
    (model.credentialKey ? '<span class="chip plain">凭据 ' + esc(model.credentialKey) + '</span>' : '') +
    '<button class="icon-btn" style="margin-left:auto" data-act="copy-model" data-model="' + esc(model.modelID) +
      '" title="复制模型 ID">📋</button>' +
    '</div>' +
    (model.evidence
      ? '<div class="small dim evidence" style="padding:0 2px 6px 18px">依据：' + esc(model.evidence) + '</div>'
      : '');
}

/// 一次发现结果的摘要行（来源 + 数量 + 端点 + 时间 + 降级原因）
function discoveryLine(k, discovery) {
  const probeBtn = '<button class="btn small" data-act="discover" data-id="' + esc(k.id) + '">🔍 ' +
    (discovery ? '重新识别' : '识别模型') + '</button>';
  if (!discovery) return '<div class="discovery-line"><span>尚未识别这把 Key 能提供哪些模型</span>' + probeBtn + '</div>';
  const cls = discovery.probed ? 'src-probe' : 'src-hostMapped';
  return '<div class="discovery-line">' +
    '<span class="chip ' + cls + '">' + esc(discovery.sourceLabel || '未知') + '</span>' +
    '<span>' + (discovery.modelCount || (discovery.models || []).length) + ' 个模型（去重后）</span>' +
    (discovery.endpoint ? '<code class="mono" style="font-size:10.5px">' + esc(discovery.endpoint) + '</code>' : '') +
    (discovery.fetchedAt ? '<span>识别于 ' + fmtTime(discovery.fetchedAt) + '</span>' : '') +
    (discovery.probed ? '' : '<span class="dim" title="' + esc(discovery.note || '') + '">⚠ 已降级</span>') +
    probeBtn + '</div>';
}

/**
 * 渲染某把密钥可提供的模型（REQ-020）。
 *
 * 数据优先级：端点实测（discovery）> 宿主配置映射（k.modelBindings）。
 * 交互取舍（格式塔原理）：
 *  · 共同区域 + 接近性：模型区块**内嵌在密钥卡里**，与端点、指纹同属一列，
 *    用户先认出「这是一把 Key 的资料」，再看到它提供了哪些模型；
 *  · 相似性：来源标签复用既有 .chip 形状，只用颜色区分置信度；
 *  · 图形—背景：模型行用次级字号与弱色，Key 本身保持主视觉；
 *  · 闭合性：默认折叠为一行摘要，点击才展开全部模型。
 */
function renderKeyModels(k) {
  const discovery = state.discoveries[k.id];
  const source = discovery
    ? (discovery.models || [])
    : (k.modelBindings || []).map((b) => ({
        modelID: b.modelID, displayName: b.displayName, source: 'hostMapped',
        sourceLabel: '宿主映射', confidence: '宿主声明', evidence: b.matchedBy,
        host: b.host, hostLabel: b.hostLabel, credentialKey: b.credentialKey
      }));
  const models = dedupeModels(source);
  const line = discoveryLine(k, discovery);

  if (!models.length) {
    return '<div class="key-models empty-note">' +
      '<span class="km-title">可提供模型</span>' +
      '<span class="small dim">' +
        (discovery && discovery.probed === false
          ? '端点探测未成功，且宿主没有声明绑定这把 Key 的模型（原因见提示）'
          : '暂未识别：点「识别模型」会请求该 Key 端点的 /models') +
      '</span>' + line + renderBalanceLine(discovery) + '</div>';
  }

  const order = ['probe', 'hostMapped', 'inferred', 'unknown'];
  const bySource = {};
  models.forEach((m) => {
    const s = m.source || 'unknown';
    (bySource[s] = bySource[s] || []).push(m);
  });
  const summary = order.filter((s) => bySource[s])
    .map((s) => (bySource[s][0].sourceLabel || s) + ' ' + bySource[s].length).join(' · ');

  let html = '<div class="key-models" data-models-for="' + esc(k.id) + '">' +
    '<button class="km-head" type="button" data-act="toggle-models" data-id="' + esc(k.id) + '">' +
      '<span class="km-caret">▸</span>' +
      '<span class="km-title">可提供模型 ' + models.length + ' 个</span>' +
      '<span class="small dim">' + esc(summary) + '</span>' +
    '</button>' + line +
    // REQ-024：额度是账号级事实，放在折叠区**外面**常显——
    // 用户第一眼就该知道「这个账号还能不能调」，不该藏在展开动作之后
    renderBalanceLine(discovery) +
    '<div class="km-body hidden">';
  order.filter((s) => bySource[s]).forEach((s) => {
    html += '<div class="km-host"><div class="km-host-name">' + esc(bySource[s][0].sourceLabel || s) + '</div>';
    bySource[s].forEach((m) => { html += modelEntry(k.id, m); });
    html += '</div>';
  });
  html += '<div class="small dim km-foot">来源说明：<b>端点探测</b>是这把 Key 自己端点 /models 的实测结果；' +
    '<b>宿主映射</b>来自 DSH/Codex 配置声明；<b>推断</b>仅作候选（可能出错）。' +
    '任何来源都不会被本工具自动写入宿主配置。</div>';
  html += '</div></div>';
  return html;
}

/// 分区标题行：别名 + 厂商 + 状态 + 模型计数 + 该 Key 的操作
/// 后端 keysGrouped 给出的每分区模型数（渲染前填好，避免前端重复计算）
let groupModelCountCache = {};

function renderGroupHead(label, keys) {
  const collapsed = !!state.collapsedGroups[label];
  const record = keys[0] || {};
  // 标题计数取「后端给的计数」与「本卡片实际渲染出的模型数」的较大者。
  // 实测踩坑：本机后端 keysGrouped 的 modelCount 曾返回 0，而同一张卡片由 modelBindings
  // 渲染出 6 个模型，界面上就出现「标题 0 个、卡片里 6 个」的自相矛盾数字。
  // 取较大者是两处口径不一致时的安全兜底：宁可多标一个，也不能少标成 0 误导用户。
  const localCount = dedupeModels((record.modelBindings || []).map((b) => ({ modelID: b.modelID, source: 'hostMapped' }))).length;
  const backendCount = (groupModelCountCache[label] !== undefined) ? groupModelCountCache[label] : 0;
  const modelCount = Math.max(backendCount, localCount);
  const st = (record.lastCheck || {}).status || 'unchecked';
  const stLabel = (record.lastCheck || {}).label || '未探测';
  return '<div class="key-group-head" data-act="toggle-group" data-group="' + esc(label) + '">' +
      '<span class="key-group-caret">' + (collapsed ? '▸' : '▾') + '</span>' +
      '<span class="status ' + statusClass(st) + '" title="' + esc(stLabel) + '"></span>' +
      '<span class="key-group-name">' + esc(label) + '</span>' +
      '<span class="chip">' + esc(providerName(record.providerID)) + '</span>' +
      (keys.length > 1 ? '<span class="chip plain">' + keys.length + ' 把密钥</span>' : '') +
      '<span class="chip plain">模型 ' + modelCount + ' 个</span>' +
      (record.enabled === false ? '<span class="chip plain" style="color:var(--red)">已禁用</span>' : '') +
      '<span class="key-group-actions">' +
        '<button class="btn small" data-act="detail" data-id="' + esc(record.id) + '">详情</button>' +
        '<button class="btn small" data-act="discover" data-id="' + esc(record.id) + '">🔍 识别模型</button>' +
      '</span>' +
    '</div>';
}

/// 单张密钥卡（与 v1.5.0 的卡片一致，只把「供给模型」换成「可提供模型」发现结果）
function renderKeyCard(k) {
  const st = (k.lastCheck || {}).status || 'unchecked';
  const stLabel = (k.lastCheck || {}).label || '未探测';
  const shown = state.reveal && k.secret ? k.secret : k.hint;
  return '<div class="key-card" data-id="' + esc(k.id) + '">' +
      '<div class="key-card-left">' +
        '<div class="key-card-title-row">' +
          '<span class="status ' + statusClass(st) + '" title="' + esc(stLabel) + '"></span>' +
          '<button class="key-card-label" style="background:none;border:0;padding:0;color:inherit;cursor:pointer" ' +
            'data-act="detail" data-id="' + esc(k.id) + '" title="点击查看详情">' + esc(k.label) + '</button>' +
          '<span class="chip">' + esc(providerName(k.providerID)) + '</span>' +
          '<span class="chip plain">优先级 ' + esc(k.priority) + '</span>' +
          (k.enabled ? '' : '<span class="chip plain" style="color:var(--red)">已禁用</span>') +
          (k.tags || []).map((t) => '<span class="chip plain">' + esc(t) + '</span>').join('') +
        '</div>' +
        '<div class="key-secret-box">' +
          '<span class="key-secret-text mono">' + esc(shown) + '</span>' +
          '<button class="icon-btn" data-act="copy-secret" data-id="' + esc(k.id) + '" title="复制当前明文/掩码">📋</button>' +
        '</div>' +
        '<div class="key-card-sub">' +
          (k.baseURL ? '<span>端点: <code class="mono" style="color:var(--accent)">' + esc(k.baseURL) + '</code></span>' : '') +
          '<span>指纹: <code class="mono">' + esc(k.fingerprint) + '</code></span>' +
          '<span class="' + statusTextClass(st) + '">● ' + esc(stLabel) +
            (k.lastCheck && k.lastCheck.latencyMS ? ' (' + k.lastCheck.latencyMS + 'ms)' : '') + '</span>' +
          (k.note ? '<span class="dim">备注: ' + esc(k.note) + '</span>' : '') +
          '<span class="dim">更新于 ' + fmtTime(k.updatedAt || k.createdAt) + '</span>' +
        '</div>' +
        // 模型区块与端点/指纹同属 .key-card-left 一列：
        // 接近性（列内 gap 6px < 卡片间距 12px）让它被读成「这张密钥卡的一部分」，
        // 共同区域则把它与右侧的编辑/探测按钮区分开。
        renderKeyModels(k) +
      '</div>' +
      '<div class="key-card-dock">' +
        '<button class="btn small" data-act="detail" data-id="' + esc(k.id) + '">详情</button>' +
        '<button class="btn small" data-act="edit" data-id="' + esc(k.id) + '">✏️ 编辑</button>' +
        '<button class="btn small" data-act="check" data-id="' + esc(k.id) + '">🩺 探测</button>' +
        '<label class="switch" title="启用/禁用"><input type="checkbox" data-act="toggle" data-id="' +
          esc(k.id) + '"' + (k.enabled ? ' checked' : '') + '><span></span></label>' +
        '<button class="icon-btn" data-act="delete" data-id="' + esc(k.id) + '" title="删除">🗑</button>' +
      '</div>' +
    '</div>';
}

function renderKeys() {
  const host = $('#keys-host');
  if (!state.keys.length) {
    host.innerHTML = '<div class="empty"><div class="big">🔑</div>' +
      '<div>密钥库还是空的</div>' +
      '<div class="small" style="margin-top:6px">点击右上角「新增密钥」，把大模型平台申请的 API Key 存进本机密钥后端。</div></div>';
    return;
  }

  // 分区来源：优先用后端返回的 keysGrouped（与 CLI 分区口径完全一致）；
  // 若该调用失败（旧版桥接），退化为「按别名就地分组」，保证界面始终按名字分区。
  let groups = state.keyGroups;
  if (!groups.length) {
    const byLabel = {};
    state.keys.forEach((k) => { (byLabel[k.label] = byLabel[k.label] || []).push(k); });
    groups = Object.keys(byLabel).map((label) => ({ label: label, keys: byLabel[label] }));
  }

  groupModelCountCache = {};
  groups.forEach((g) => { if (g && g.label) groupModelCountCache[g.label] = g.modelCount; });

  const q = state.keysSearch.trim().toLowerCase();
  const visible = groups.map((group) => {
    const keys = (group.keys || []).filter((k) => {
      if (state.keysOnlyAttention) {
        const st = (k.lastCheck || {}).status;
        const discovered = state.discoveries[k.id];
        const attention = !st || st === 'unchecked' || st === 'invalid' || st === 'quota'
          || (discovered && !discovered.probed);
        if (!attention) return false;
      }
      if (!q) return true;
      const models = (state.discoveries[k.id] || {}).models || [];
      const haystack = [
        group.label, k.label, k.providerID, providerName(k.providerID), k.baseURL || '', k.note || '',
        (k.tags || []).join(' '),
        models.map((m) => m.modelID).join(' '),
        (k.modelBindings || []).map((b) => b.modelID).join(' ')
      ].join(' ').toLowerCase();
      return haystack.indexOf(q) >= 0;
    });
    return { group: group, keys: keys };
  }).filter((item) => item.keys.length);

  if (!visible.length) {
    host.innerHTML = '<div class="empty"><div class="big">🔍</div><div>没有匹配的密钥分区</div>' +
      '<div class="small" style="margin-top:6px">试试清空搜索词，或取消「仅看未探测 / 异常」筛选。</div></div>';
    return;
  }

  let html = '';
  visible.forEach((item) => {
    const group = item.group;
    const collapsed = !!state.collapsedGroups[group.label];
    html += '<div class="key-group" data-group="' + esc(group.label) + '">' +
      renderGroupHead(group.label, item.keys) +
      '<div class="key-group-body' + (collapsed ? ' collapsed' : '') + '">';
    item.keys.forEach((k) => { html += renderKeyCard(k); });
    html += '</div></div>';
  });

  if (state.reveal) {
    html += '<div class="warn-box">⚠️ 当前正在显示完整明文，请注意屏幕共享与录屏安全。</div>';
  }
  host.innerHTML = html;
}

$('#keys-host').addEventListener('click', async (e) => {
  const btn = e.target.closest('[data-act]');
  if (!btn) return;
  const id = btn.dataset.id;
  const act = btn.dataset.act;
  const record = state.keys.find((k) => k.id === id);
  const groupLabel = btn.dataset.group;
  try {
    if (act === 'toggle-group') {
      // 就近折叠：只切换本分区，不重排整页（格式塔的连续性）
      state.collapsedGroups[groupLabel] = !state.collapsedGroups[groupLabel];
      const grp = btn.closest('.key-group');
      const body = grp && grp.querySelector('.key-group-body');
      if (body) body.classList.toggle('collapsed', !!state.collapsedGroups[groupLabel]);
      const caret = btn.querySelector('.key-group-caret');
      if (caret) caret.textContent = state.collapsedGroups[groupLabel] ? '▸' : '▾';
    } else if (act === 'toggle-models') {
      // 就地展开/收起：不重新渲染整张卡，避免用户视角跳位
      const box = btn.closest('.key-models');
      const body = box && box.querySelector('.km-body');
      if (body) {
        body.classList.toggle('hidden');
        const caret = btn.querySelector('.km-caret');
        if (caret) caret.textContent = body.classList.contains('hidden') ? '▸' : '▾';
      }
    } else if (act === 'detail') {
      await openKeyDetail(id);
    } else if (act === 'discover') {
      // 显式联网动作：只有用户点击才会请求该 Key 的端点
      banner('info', '正在识别这把密钥可提供的模型…');
      const result = await discoverKey(id);
      banner(result.probed ? 'success' : 'warning', result.probed
        ? '端点探测成功：识别到 ' + (result.modelCount || 0) + ' 个模型（' + result.endpoint + '）'
        : '端点探测未成功，已降级为' + (result.sourceLabel || '未知') + '：' + (result.note || ''));
      await loadKeys();
      if (state.detailKeyID === id) await openKeyDetail(id);
    } else if (act === 'copy-model') {
      await call('copy', { text: btn.dataset.model || '' });
      banner('success', '已复制模型 ID：' + (btn.dataset.model || ''));
    } else if (act === 'edit') {
      if (record) openModal('edit', record);
    } else if (act === 'copy-secret') {
      try {
        const res = await call('revealSecret', { id: id });
        await call('copy', { text: res.secret });
        banner('success', '已将密钥明文复制到剪贴板');
      } catch (err) {
        await call('copy', { text: record ? record.hint : '' });
        banner('info', '已将密钥掩码复制到剪贴板');
      }
    } else if (act === 'check') {
      banner('info', '正在探测…');
      const res = await call('checkKey', { id: id });
      banner(res.status === 'valid' ? 'success' : 'warning', '探测结果：' + res.label + ' — ' + res.message);
      await loadKeys();
    } else if (act === 'copy') {
      await call('copy', { text: record ? record.fingerprint : '' });
      banner('success', '已复制指纹到剪贴板');
    } else if (act === 'delete') {
      if (!confirm('确认删除密钥「' + (record ? record.label : '') + '」？\n将同时永久删除本机保存的明文内容。')) return;
      const res = await call('deleteKey', { id: id });
      banner('success', '已删除密钥「' + res.label + '」及其明文');
      state.plan = null;
      await loadKeys();
      await loadAudit();
    }
  } catch (err) {
    banner('error', String(err.message || err));
  }
});

$('#keys-host').addEventListener('change', async (e) => {
  const input = e.target.closest('input[data-act="toggle"]');
  if (!input) return;
  try {
    await call('setEnabled', { id: input.dataset.id, enabled: input.checked });
    await loadKeys();
  } catch (err) {
    banner('error', String(err.message || err));
  }
});

/* ---------- 密钥库工具栏（搜索 / 筛选 / 折叠 / 批量识别） ---------- */

$('#keys-search').addEventListener('input', (e) => {
  state.keysSearch = e.target.value || '';
  $('#keys-search-clear').classList.toggle('hidden', !state.keysSearch);
  renderKeys();
});

$('#keys-search-clear').addEventListener('click', () => {
  state.keysSearch = '';
  $('#keys-search').value = '';
  $('#keys-search-clear').classList.add('hidden');
  renderKeys();
});

$('#keys-filter-attention').addEventListener('change', (e) => {
  state.keysOnlyAttention = e.target.checked;
  renderKeys();
});

$('#btn-groups-toggle').addEventListener('click', (e) => {
  const labels = state.keyGroups.length ? state.keyGroups.map((g) => g.label) : state.keys.map((k) => k.label);
  const anyExpanded = labels.some((l) => !state.collapsedGroups[l]);
  labels.forEach((l) => { state.collapsedGroups[l] = anyExpanded; });
  e.target.textContent = anyExpanded ? '⇕ 全部展开' : '⇕ 全部折叠';
  renderKeys();
});

$('#btn-discover-all').addEventListener('click', async () => {
  try {
    banner('info', '正在对全部密钥识别可用模型（会逐把请求其端点 /models）…');
    const res = await discoverAllKeys();
    banner(res.probed === res.total ? 'success' : 'warning',
      '模型识别完成：' + res.probed + '/' + res.total + ' 把密钥成功从端点取证（其余为宿主映射兜底）');
    await loadKeys();
    await loadAudit();
  } catch (err) {
    banner('error', String(err.message || err));
  }
});

$('#reveal-toggle').addEventListener('change', async (e) => {
  state.reveal = e.target.checked;
  $('#reveal-toggle-inject').checked = state.reveal;
  await loadKeys();
  renderPlan();
});

$('#reveal-toggle-inject').addEventListener('change', async (e) => {
  state.reveal = e.target.checked;
  $('#reveal-toggle').checked = state.reveal;
  await loadKeys();
  renderPlan();
});

$('#btn-check-all').addEventListener('click', async () => {
  try {
    banner('info', '正在批量探测，请稍候…');
    const res = await call('checkAll', {});
    banner(res.valid === res.total ? 'success' : 'warning',
      '批量探测完成：' + res.valid + '/' + res.total + ' 个密钥鉴权通过');
    await loadKeys();
    await loadAudit();
  } catch (err) {
    banner('error', String(err.message || err));
  }
});

/* ---------- 密钥弹窗（新增 / 可视化编辑） ---------- */

function openModal(mode = 'add', keyRecord = null) {
  state.editingKey = mode === 'edit' ? keyRecord : null;
  const isEdit = mode === 'edit' && keyRecord;

  $('#modal-title').textContent = isEdit ? ('编辑密钥「' + keyRecord.label + '」') : '新增密钥';
  const sel = $('#f-provider');
  sel.innerHTML = state.providers.map((p) =>
    '<option value="' + esc(p.id) + '"' + (isEdit && p.id === keyRecord.providerID ? ' selected' : '') + '>' +
    esc(p.name) + '</option>').join('');
  sel.disabled = !!isEdit;

  $('#f-label').value = isEdit ? keyRecord.label : '';
  $('#f-base-url').value = isEdit ? (keyRecord.baseURL || '') : '';
  $('#f-secret').value = '';
  $('#f-secret').type = 'password';
  $('#f-secret').placeholder = isEdit ? '留空表示保持原密钥明文不变；输入新 Key 则覆盖更新' : '粘贴 API Key（仅保存在本机密钥后端）';
  $('#f-secret-hint').textContent = isEdit ? ('当前掩码：' + keyRecord.hint + ' · 短指纹 ' + keyRecord.fingerprint) : '';
  $('#f-priority').value = isEdit ? String(keyRecord.priority) : '100';
  $('#f-tags').value = isEdit ? (keyRecord.tags || []).join(', ') : '';
  $('#f-note').value = isEdit ? (keyRecord.note || '') : '';
  $('#f-warnings').classList.add('hidden');

  renderProviderInfo();
  $('#modal-mask').classList.remove('hidden');
  $('#f-label').focus();
}

function closeModal() {
  state.editingKey = null;
  $('#modal-mask').classList.add('hidden');
}

// 辅助输入框粘贴事件兜底（双重保证无论何时都能粘贴文本）
['#f-base-url', '#f-secret', '#f-label'].forEach((sel) => {
  const el = $(sel);
  if (!el) return;
  el.addEventListener('paste', (e) => {
    // 允许浏览器原生粘贴流转，若被特殊环境限制则主动读取 clipboardData 填入
    if (e.clipboardData && e.clipboardData.getData) {
      const text = e.clipboardData.getData('text');
      if (text && el.value === '') {
        // 如果系统没有自动插入，则稍后检测补足
        setTimeout(() => {
          if (!el.value) {
            el.value = text;
            renderProviderInfo();
          }
        }, 10);
      }
    }
  });
});

$('#f-secret-toggle').addEventListener('click', () => {
  const inp = $('#f-secret');
  inp.type = inp.type === 'password' ? 'text' : 'password';
});

function clientWarnings(secret, provider) {
  const out = [];
  if (!secret) return out;
  if (secret !== secret.trim()) out.push('密钥首尾含空白字符，保存时会自动去除');
  if (/\s/.test(secret.trim())) out.push('密钥中间含空格或换行，疑似复制错误');
  const t = secret.trim();
  if (t.length < 12) out.push('密钥长度短于 12 字符，多数厂商密钥不会这么短');
  const prefixes = (provider && provider.secretPrefixes) || [];
  if (prefixes.length && !prefixes.some((p) => t.startsWith(p))) {
    out.push('该厂商通常以 ' + prefixes.join(' / ') + ' 开头；若为中间商中转凭证可直接保存');
  }
  return out;
}

function renderProviderInfo() {
  const p = providerById($('#f-provider').value);
  if (!p) { $('#f-provider-info').innerHTML = ''; return; }
  let html = '<div class="kv"><span class="k">环境变量</span><span class="v mono">' + esc(p.envKeys.join(', ')) + '</span></div>';
  if (p.baseURL) html += '<div class="kv"><span class="k">API 基址</span><span class="v mono">' + esc(p.baseURL) + '</span></div>';
  if (p.consoleURL) {
    html += '<div class="kv"><span class="k">申请地址</span><span class="v mono">' + esc(p.consoleURL) +
      ' <button class="btn small" data-open="' + esc(p.consoleURL) + '">打开</button></span></div>';
  }
  html += '<div class="note">' + esc(p.note) + '</div>';
  $('#f-provider-info').innerHTML = html;

  const baseInput = $('#f-base-url');
  if (baseInput) {
    baseInput.placeholder = p.baseURL ? ('官方默认: ' + p.baseURL) : '留空使用官方默认；中转/中间商请填代理端点';
    $('#f-base-url-hint').textContent = p.baseURL ? ('官方端点为 ' + p.baseURL + '，若使用中间商/转发代理请在此覆盖') : '';
  }

  const warn = clientWarnings($('#f-secret').value, p);
  const box = $('#f-warnings');
  if (warn.length) {
    box.innerHTML = warn.map((w) => '• ' + esc(w)).join('<br>');
    box.classList.remove('hidden');
  } else {
    box.classList.add('hidden');
  }
}

$('#f-provider').addEventListener('change', renderProviderInfo);
$('#f-secret').addEventListener('input', renderProviderInfo);

$('#f-provider-info').addEventListener('click', (e) => {
  const btn = e.target.closest('[data-open]');
  if (btn) call('openURL', { url: btn.dataset.open }).catch(() => {});
});

$('#btn-add-key').addEventListener('click', () => openModal('add'));
$('#modal-close').addEventListener('click', closeModal);
$('#modal-cancel').addEventListener('click', closeModal);
$('#modal-mask').addEventListener('click', (e) => { if (e.target.id === 'modal-mask') closeModal(); });

$('#modal-save').addEventListener('click', async () => {
  const isEdit = !!state.editingKey;
  const secretVal = $('#f-secret').value;
  const labelVal = $('#f-label').value.trim();
  const baseURLVal = $('#f-base-url').value.trim();

  if (!isEdit && !secretVal.trim()) {
    banner('warning', '请先粘贴密钥明文');
    return;
  }

  try {
    if (isEdit) {
      const payload = {
        id: state.editingKey.id,
        label: labelVal || state.editingKey.label,
        baseURL: baseURLVal,
        priority: parseInt($('#f-priority').value, 10) || 100,
        tags: $('#f-tags').value.split(',').map((s) => s.trim()).filter(Boolean),
        note: $('#f-note').value.trim()
      };
      if (secretVal.trim()) {
        payload.secret = secretVal.trim();
      }
      const res = await call('updateKey', payload);
      closeModal();
      const w = res.warnings || [];
      banner(w.length ? 'warning' : 'success',
        '已更新密钥「' + res.record.label + '」' +
        (payload.secret ? '（新掩码 ' + res.record.hint + '）' : '') +
        (w.length ? '；注意：' + w.join('；') : ''));
    } else {
      const payload = {
        providerID: $('#f-provider').value,
        label: labelVal || (providerName($('#f-provider').value) + ' 密钥'),
        baseURL: baseURLVal || undefined,
        secret: secretVal,
        priority: parseInt($('#f-priority').value, 10) || 100,
        tags: $('#f-tags').value.split(',').map((s) => s.trim()).filter(Boolean),
        note: $('#f-note').value.trim()
      };
      const res = await call('addKey', payload);
      closeModal();
      const w = res.warnings || [];
      banner(w.length ? 'warning' : 'success',
        '已保存密钥「' + res.record.label + '」（掩码 ' + res.record.hint + '）' +
        (w.length ? '；注意：' + w.join('；') : ''));
    }
    await loadKeys();
    await loadAudit();
  } catch (err) {
    banner('error', String(err.message || err));
  }
});

/* ---------- 密钥详情（REQ-021） ---------- */

/// 打开某把密钥的详情视图：完整元数据 + 可用模型 + 注入落点 + 审计摘要
async function openKeyDetail(id) {
  state.detailKeyID = id;
  $('#detail-body').innerHTML = '<div class="detail-empty">正在读取详情…</div>';
  $('#detail-mask').classList.remove('hidden');
  try {
    const detail = await call('keyDetail', { id: id });
    renderKeyDetail(detail);
  } catch (err) {
    $('#detail-body').innerHTML = '<div class="detail-empty">读取详情失败：' + esc(String(err.message || err)) + '</div>';
  }
}

function closeKeyDetail() {
  state.detailKeyID = null;
  $('#detail-mask').classList.add('hidden');
}

function detailKV(k, v) {
  return '<div class="detail-kv"><span class="k">' + k + '</span><span class="v">' + v + '</span></div>';
}

/// 详情五段信息架构：身份 / 健康 / 模型 / 落点 / 时间线
function renderKeyDetail(detail) {
  const r = detail.record || {};
  const discovery = detail.discovery || null;
  const models = dedupeModels(detail.availableModels || []);
  const locations = detail.locations || [];
  const audit = detail.audit || [];

  $('#detail-title').textContent = '密钥详情：' + (r.label || '');
  $('#detail-provider').textContent = providerName(r.providerID);
  $('#detail-foot').textContent = '模型来源与依据如实标注；本工具不会据此自动改写宿主配置';

  let html = '<div class="detail-section"><h3>身份</h3><div class="detail-grid">' +
    detailKV('别名', esc(r.label)) +
    detailKV('厂商', esc(providerName(r.providerID)) + ' <code class="mono">' + esc(r.providerID) + '</code>') +
    detailKV('端点', r.baseURL ? '<code class="mono">' + esc(r.baseURL) + '</code>' : '<span class="dim">未填写，使用厂商默认</span>') +
    detailKV('掩码', '<code class="mono">' + esc(r.hint) + '</code>') +
    detailKV('指纹', '<code class="mono">' + esc(r.fingerprint) + '</code>') +
    detailKV('优先级', esc(String(r.priority))) +
    detailKV('启用状态', r.enabled ? '<span class="t-valid">● 已启用</span>' : '<span class="t-invalid">● 已禁用</span>') +
    detailKV('标签', (r.tags || []).length ? esc((r.tags || []).join('、')) : '<span class="dim">—</span>') +
    detailKV('备注', r.note ? esc(r.note) : '<span class="dim">—</span>') +
    detailKV('创建 / 更新', fmtTime(r.createdAt) + ' / ' + fmtTime(r.updatedAt)) +
    '</div></div>';

  const lc = r.lastCheck || {};
  html += '<div class="detail-section"><h3>健康探测 <span class="small dim">只代表此刻鉴权是否通过，不代表额度与模型可用性</span></h3>' +
    '<div class="detail-grid">' +
    detailKV('状态', '<span class="' + statusTextClass(lc.status) + '">● ' + esc(lc.label || '未探测') + '</span>') +
    detailKV('HTTP', lc.httpStatus ? esc(String(lc.httpStatus)) : '<span class="dim">—</span>') +
    detailKV('延迟', lc.latencyMS ? esc(lc.latencyMS + ' ms') : '<span class="dim">—</span>') +
    detailKV('探测时间', lc.checkedAt ? fmtTime(lc.checkedAt) : '<span class="dim">—</span>') +
    detailKV('消息', lc.message ? esc(lc.message) : '<span class="dim">—</span>') +
    '</div></div>';

  html += '<div class="detail-section"><h3>可提供的模型 ' +
    '<span class="chip ' + (discovery && discovery.probed ? 'src-probe' : 'src-hostMapped') + '">' +
    esc(discovery ? (discovery.sourceLabel || '未知') : '尚未识别') + '</span>' +
    '<span class="small dim">共 ' + models.length + ' 个</span></h3>';
  if (discovery) {
    html += '<div class="detail-note">识别说明：' + esc(discovery.note || '—') + '　·　识别于 ' +
      fmtTime(discovery.fetchedAt) + (discovery.endpoint ? '　·　端点 ' + esc(discovery.endpoint) : '') + '</div>';
  } else {
    html += '<div class="detail-note">尚未识别。点下方「重新探测模型」会请求该 Key 端点的 <code>/models</code>；' +
      '失败时自动降级到宿主声明映射，并如实标注来源与依据。</div>';
  }
  if (detail.probeable === false) {
    html += '<div class="detail-note" style="color:var(--orange)">⚠️ 这把 Key 目前没有可探测端点：厂商预设没有探测路径，' +
      '且未填写 Base URL。可在「编辑」里补上端点后再探测。</div>';
  }
  html += '<div style="margin-top:8px">';
  if (models.length) {
    models.forEach((m) => { html += modelEntry(r.id, m); });
  } else {
    html += '<div class="detail-empty">暂无模型记录（端点未探测成功，且宿主没有声明绑定这把 Key 的模型）。</div>';
  }
  html += '</div></div>';

  html += '<div class="detail-section"><h3>注入落点 <span class="small dim">来自审计日志的成功写入记录</span></h3>';
  if (locations.length) {
    locations.forEach((l) => {
      html += '<div class="detail-model-row">' +
        '<code class="km-model-id">' + esc(l.targetName) + '</code>' +
        '<span class="chip plain">' + esc(l.targetID) + '</span>' +
        (l.itemKey ? '<span class="chip plain">键名 ' + esc(l.itemKey) + '</span>' : '') +
        '<span class="small dim" style="margin-left:auto">最近 ' + fmtTime(l.lastInjectedAt) + '</span>' +
        '</div><div class="small dim evidence" style="padding:0 2px 6px 18px">' + esc(l.filePath) + '</div>';
    });
  } else {
    html += '<div class="detail-empty">这把 Key 尚未注入到任何落点。</div>';
  }
  html += '</div>';

  html += '<div class="detail-section"><h3>最近审计记录</h3>';
  if (audit.length) {
    audit.forEach((a) => {
      html += '<div class="detail-model-row">' +
        '<span class="chip plain">' + esc(a.actionLabel || a.action) + '</span>' +
        '<span class="small">' + esc(a.message) + '</span>' +
        '<span class="small dim" style="margin-left:auto">' + fmtTime(a.timestamp) + '</span>' +
        '</div>';
    });
  } else {
    html += '<div class="detail-empty">暂无与该密钥相关的审计记录。</div>';
  }
  html += '</div>';

  $('#detail-body').innerHTML = html;
}

$('#detail-close').addEventListener('click', closeKeyDetail);
$('#detail-close-2').addEventListener('click', closeKeyDetail);
$('#detail-mask').addEventListener('click', (e) => { if (e.target === $('#detail-mask')) closeKeyDetail(); });
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !$('#detail-mask').classList.contains('hidden')) closeKeyDetail();
});

$('#detail-body').addEventListener('click', async (e) => {
  const btn = e.target.closest('[data-act="copy-model"]');
  if (!btn) return;
  await call('copy', { text: btn.dataset.model || '' });
  banner('success', '已复制模型 ID：' + (btn.dataset.model || ''));
});

// 鉴权探测与模型探测是两件事，按钮文案必须说清：
// 「探测」= 该端点的健康检查（鉴权/额度）；「识别模型」= 读 /models 清单。
$('#detail-health').addEventListener('click', async () => {
  const id = state.detailKeyID;
  const record = state.keys.find((k) => k.id === id);
  if (!id || !record) return;
  try {
    banner('info', '正在探测「' + (record.label || '') + '」的鉴权状态…');
    const res = await call('checkKey', { id: id });
    banner(res.status === 'valid' ? 'success' : 'warning', '探测结果：' + res.label + ' — ' + res.message);
    await loadKeys();
    await openKeyDetail(id);
  } catch (err) {
    banner('error', String(err.message || err));
  }
});

$('#detail-probe').addEventListener('click', async () => {
  const id = state.detailKeyID;
  if (!id) return;
  try {
    banner('info', '正在识别这把密钥可提供的模型…');
    const result = await discoverKey(id);
    banner(result.probed ? 'success' : 'warning', result.probed
      ? '端点探测成功：' + result.endpoint
      : '端点探测未成功，已降级为' + (result.sourceLabel || '未知') + '：' + (result.note || ''));
    await loadKeys();
    await openKeyDetail(id);
  } catch (err) {
    banner('error', String(err.message || err));
  }
});

function injectForm() {
  const target = targetById(state.selectedTargetID) || state.targets[0];
  return {
    targetID: target ? target.id : '',
    keyID: $('#i-key') ? $('#i-key').value : '',
    overridePath: $('#i-path') ? $('#i-path').value.trim() : '',
    jsonPath: $('#i-jsonpath') ? $('#i-jsonpath').value.trim() : '',
    section: $('#i-section') ? $('#i-section').value.trim() : '',
    itemKey: $('#i-itemkey') ? $('#i-itemkey').value.trim() : '',
    reveal: state.reveal
  };
}

function renderInjectPicker() {
  if (!state.targets.length) {
    $('#inject-picker').innerHTML = '<div class="empty">没有可用的注入落点</div>';
    return;
  }

  // 默认选中目标
  if (!state.selectedTargetID || !targetById(state.selectedTargetID)) {
    const prevTarget = state.lastInjectForm ? state.lastInjectForm.targetID : '';
    state.selectedTargetID = prevTarget && targetById(prevTarget) ? prevTarget : state.targets[0].id;
  }
  const target = targetById(state.selectedTargetID) || state.targets[0];
  const filter = state.targetFilter || 'all';

  // 过滤落点
  const filteredTargets = state.targets.filter((t) => {
    if (filter === 'all') return true;
    return getTargetCategory(t) === filter;
  });

  // 密钥匹配：放宽规则，如果没有精准匹配，则接纳自定义通用网关 key 或任意可用 key
  const prevKey = state.lastInjectForm ? state.lastInjectForm.keyID : '';
  let candidates = state.keys.filter((k) => !target.providerID || k.providerID === target.providerID);
  if (!candidates.length) {
    // 自动兼容自定义/网关类型的 key
    candidates = state.keys.filter((k) => k.providerID === 'custom' || !k.providerID);
  }
  if (!candidates.length) {
    candidates = state.keys;
  }
  const selectedKey = candidates.find((k) => k.id === prevKey) || candidates[0];

  // 更新顶部一键注入栏说明
  const descEl = $('#one-click-desc');
  if (descEl) {
    descEl.textContent = '当前目标：' + target.name + ' · 将自动使用「' + (selectedKey ? selectedKey.label : '未匹配') + '」一键完成写入与备份';
  }

  let html = '<h2>选择注入目标（仅保留核心宿主）</h2>';
  
  // 简化的扩展按钮栏
  html += '<div class="target-categories" style="margin-bottom:12px;">' +
    '<span class="dim small">已为你净化无用落点，当前专注 DSH 与 Codex</span>' +
    '<button class="btn small" id="btn-quick-add-target">＋ 扩展新落点</button>' +
  '</div>';

  // 落点卡片选择矩阵
  html += '<div class="target-grid">';
  state.targets.forEach((t) => {
    const isSel = t.id === target.id;
    const icon = getTargetIcon(t);
    const fmtCls = (t.format || 'none').toLowerCase();
    html +=
      '<div class="target-card ' + (isSel ? 'selected' : '') + '" data-target-id="' + esc(t.id) + '">' +
        '<div class="target-card-head">' +
          '<div class="target-badge-wrap">' +
            '<span class="target-icon">' + icon + '</span>' +
            '<span class="target-card-name">' + esc(t.name) + '</span>' +
          '</div>' +
          '<span class="format-badge ' + fmtCls + '">' + esc(t.formatLabel) + '</span>' +
        '</div>' +
        '<div class="target-card-path">' + (t.filePath ? esc(t.filePath) : '<span class="dim">需填路径 / 仅生成片段</span>') + '</div>' +
        '<div class="target-card-foot">' +
          '<span class="dim">' + (t.providerID ? esc(providerName(t.providerID)) : '通用 / 兼容网关') + '</span>' +
          (t.isCustom ? '<button class="icon-btn" data-act="del-target" data-target-id="' + esc(t.id) + '" title="删除自定义落点">🗑</button>' : '') +
        '</div>' +
      '</div>';
  });
  html += '</div>';

  // 高级微调折叠抽屉（默认收起，极简呈现）
  html += '<details style="margin-top:16px;border:1px solid var(--line);border-radius:9px;padding:10px 14px;background:var(--panel);">' +
    '<summary style="cursor:pointer;font-size:12.5px;font-weight:600;color:var(--text-dim);user-select:none;">' +
    '⚙️ 展开高级微调与手动核对（可选）' +
    '</summary>';

  html += '<div class="grid-2" style="margin-top:12px;">';

  html += '<label class="field"><span>使用密钥</span><select id="i-key">' +
    (candidates.length
      ? candidates.map((k) =>
          '<option value="' + esc(k.id) + '"' + (selectedKey && k.id === selectedKey.id ? ' selected' : '') + '>' +
          esc(k.label) + ' · ' + esc(providerName(k.providerID)) + ' · ' + esc(k.hint) +
          (k.enabled ? '' : '（已禁用）') + '</option>').join('')
      : '<option value="">（该落点暂无匹配密钥，请先在密钥库录入）</option>') +
    '</select></label>';

  const showPath = target.writesFile;
  const showJson = target.format === 'json' || target.format === 'plist';
  const showSection = target.format === 'yaml' || target.format === 'toml';

  if (showPath) {
    html += '<label class="field"><span>目标文件绝对路径</span><input type="text" id="i-path" value="' +
      esc(state.lastInjectForm ? state.lastInjectForm.overridePath : target.filePath) +
      '" placeholder="' + (target.filePath ? esc(target.filePath) : '必填，例如 ~/.zshrc') + '"></label>';
  } else {
    html += '<div></div>';
  }
  html += '</div>';

  if (showJson || showSection || target.writesFile) {
    html += '<div class="grid-2">';
    if (showJson) {
      html += '<label class="field"><span>JSON 键路径（点号分隔）</span><input type="text" id="i-jsonpath" value="' +
        esc(state.lastInjectForm ? state.lastInjectForm.jsonPath : target.jsonPath) +
        '" placeholder="例如 env.OPENAI_API_KEY"></label>';
    }
    if (showSection) {
      html += '<label class="field"><span>YAML / TOML 区块名（可留空）</span><input type="text" id="i-section" value="' +
        esc(state.lastInjectForm ? state.lastInjectForm.section : target.section) +
        '" placeholder="例如 refs 或 openai"></label>';
    }
    html += '<label class="field"><span>写入键名（可留空取默认）</span><input type="text" id="i-itemkey" value="' +
      esc(state.lastInjectForm ? state.lastInjectForm.itemKey : (target.itemKey || '')) +
      '" placeholder="' + esc(target.itemKey || '按厂商默认环境变量名') + '"></label>';
    html += '</div>';
  }

  html += '<div class="warn-box" style="background:var(--panel-2);color:var(--text-dim);margin:10px 0;">' +
    '📌 <b>落点安全说明：</b>' + esc(target.note) + '</div>';

  html += '<div style="display:flex;gap:10px;margin-top:12px">' +
    '<button class="btn primary" id="btn-plan">生成注入计划（Dry-Run 差异比对）</button>' +
    '<button class="btn" id="btn-rollback-latest">回滚该落点最近一次注入</button>' +
    '</div></details>';

  $('#inject-picker').innerHTML = html;

  // 绑定一键注入大按钮
  const oneClickBtn = $('#btn-one-click-apply');
  if (oneClickBtn) {
    oneClickBtn.onclick = async () => {
      await doOneClickInject(target, selectedKey);
    };
  }

  // 绑定事件
  const targetTabs = $('#target-tabs');
  if (targetTabs) {
    targetTabs.addEventListener('click', (e) => {
      const tab = e.target.closest('.tab');
      if (!tab) return;
      state.targetFilter = tab.dataset.tfilter;
      renderInjectPicker();
    });
  }

  const quickAdd = $('#btn-quick-add-target');
  if (quickAdd) quickAdd.addEventListener('click', openTargetModal);

  const pickerEl = $('#inject-picker');
  if (pickerEl) {
    pickerEl.onclick = async (e) => {
      const delBtn = e.target.closest('[data-act="del-target"]');
      if (delBtn) {
        e.stopPropagation();
        const tid = delBtn.dataset.targetId;
        const t = targetById(tid);
        if (!confirm('确认删除自定义落点「' + (t ? t.name : tid) + '」？')) return;
        try {
          await call('deleteTarget', { id: tid });
          state.targets = await call('targets');
          if (state.selectedTargetID === tid) state.selectedTargetID = (state.targets[0] || {}).id;
          banner('success', '已删除落点');
          renderInjectPicker();
        } catch (err) {
          banner('error', '删除失败: ' + err.message);
        }
        return;
      }

      const card = e.target.closest('.target-card');
      if (card) {
        const tid = card.dataset.targetId;
        if (tid && tid !== state.selectedTargetID) {
          state.selectedTargetID = tid;
          state.lastInjectForm = null;
          state.plan = null;
          state.outcome = null;
          renderInjectPicker();
          renderPlan();
        }
      }
    };
  }

  $('#btn-plan').addEventListener('click', doPlan);
  $('#btn-rollback-latest').addEventListener('click', doRollbackLatest);
}

/* ---------- 扩展落点弹窗 ---------- */

function openTargetModal() {
  const sel = $('#tf-provider');
  sel.innerHTML = '<option value="">通用（支持任意厂商）</option>' +
    state.providers.map((p) => '<option value="' + esc(p.id) + '">' + esc(p.name) + '</option>').join('');
  $('#tf-name').value = '';
  $('#tf-format').value = 'json';
  $('#tf-path').value = '';
  $('#tf-jsonpath').value = '';
  $('#tf-section').value = '';
  $('#tf-itemkey').value = '';
  $('#tf-note').value = '';
  updateTargetFormFields();
  $('#modal-target-mask').classList.remove('hidden');
  $('#tf-name').focus();
}

function closeTargetModal() {
  $('#modal-target-mask').classList.add('hidden');
}

function updateTargetFormFields() {
  const fmt = $('#tf-format').value;
  $('#tf-path-wrap').classList.toggle('hidden', fmt === 'none');
  $('#tf-jsonpath-wrap').classList.toggle('hidden', fmt !== 'json' && fmt !== 'plist');
  $('#tf-section-wrap').classList.toggle('hidden', fmt !== 'yaml' && fmt !== 'toml');
  $('#tf-itemkey-wrap').classList.toggle('hidden', fmt === 'none');
}

$('#tf-format').addEventListener('change', updateTargetFormFields);
$('#btn-add-target').addEventListener('click', openTargetModal);
$('#modal-target-close').addEventListener('click', closeTargetModal);
$('#modal-target-cancel').addEventListener('click', closeTargetModal);
$('#modal-target-mask').addEventListener('click', (e) => {
  if (e.target.id === 'modal-target-mask') closeTargetModal();
});

$('#modal-target-save').addEventListener('click', async () => {
  const name = $('#tf-name').value.trim();
  const format = $('#tf-format').value;
  const filePath = $('#tf-path').value.trim();
  if (!name) { banner('warning', '请填写落点名称'); return; }
  if (format !== 'none' && !filePath) { banner('warning', '请填写目标文件路径'); return; }

  const payload = {
    name: name,
    providerID: $('#tf-provider').value,
    format: format,
    filePath: filePath,
    jsonPath: $('#tf-jsonpath').value.trim(),
    section: $('#tf-section').value.trim(),
    itemKey: $('#tf-itemkey').value.trim(),
    note: $('#tf-note').value.trim()
  };
  try {
    const newTarget = await call('saveTarget', payload);
    closeTargetModal();
    banner('success', '已成功扩展注入落点「' + newTarget.name + '」');
    state.targets = await call('targets');
    state.selectedTargetID = newTarget.id;
    state.lastInjectForm = null;
    state.plan = null;
    state.outcome = null;
    renderInjectPicker();
    renderPlan();
  } catch (err) {
    banner('error', '保存落点失败: ' + (err.message || err));
  }
});

/* ---------- 一键极简注入全流程 ---------- */

async function doOneClickInject(target, selectedKey) {
  if (!target) {
    banner('warning', '请先选择要注入的目标应用');
    return;
  }
  if (!selectedKey) {
    banner('warning', '当前目标应用暂无匹配的密钥，请先在「密钥库」添加对应密钥');
    return;
  }

  const btn = $('#btn-one-click-apply');
  if (btn) {
    btn.disabled = true;
    btn.textContent = '⏳ 正在全自动写入…';
  }

  const form = {
    targetID: target.id,
    keyID: selectedKey.id,
    overridePath: target.filePath || '',
    jsonPath: target.jsonPath || '',
    section: target.section || '',
    itemKey: target.itemKey || '',
    reveal: state.reveal
  };

  try {
    // 1. 生成并校验计划 (Dry-run)
    const plan = await call('plan', form);
    if (plan.blocked) {
      banner('error', '安全阻断：' + plan.blockedReason);
      if (btn) { btn.disabled = false; btn.textContent = '⚡ 一键注入生效'; }
      return;
    }

    // 2. 确认写入与原子备份
    const res = await call('apply', form);
    state.outcome = res;
    state.plan = null;
    renderPlan();
    banner(res.success ? 'success' : 'error',
      (res.success ? '🎉 一键注入成功！' : '❌ 写入失败：') + res.message +
      (res.backupPath ? '（已自动备份原文件）' : ''));
    await loadKeys();
    await loadAudit();
  } catch (err) {
    banner('error', '一键注入异常：' + (err.message || err));
  } finally {
    if (btn) {
      btn.disabled = false;
      btn.textContent = '⚡ 一键注入生效';
    }
  }
}

async function doPlan() {
  const form = injectForm();
  if (!form.targetID) { banner('warning', '请先选择注入落点'); return; }
  if (!form.keyID) { banner('warning', '该落点没有可用的密钥，请先在密钥库新增或选择有效密钥'); return; }
  state.lastInjectForm = form;
  try {
    const plan = await call('plan', form);
    state.plan = plan;
    state.outcome = null;
    renderPlan();
    updateStepper(3);
    if (plan.blocked) banner('error', '已按安全策略阻断：' + plan.blockedReason);
    else if (!plan.writesFile) banner('info', '该落点不写入任何文件，仅生成导出片段');
    else banner('info', '已生成注入计划，请核对差异后决定是否写入');
  } catch (err) {
    state.plan = null;
    renderPlan();
    banner('error', String(err.message || err));
  }
}

function renderPlan() {
  const host = $('#plan-host');
  if (!state.plan) {
    host.innerHTML = state.outcome ? outcomeCard(state.outcome) : '';
    return;
  }
  const p = state.plan;
  let html = '<div class="card"><h2>第三步：核对差异 (Dry-Run)<span class="hint">' +
    (p.writesFile ? '写入前会自动备份原文件' : '该落点不写文件') + '</span></h2>';

  html += '<div class="kv"><span class="k">落点</span><span class="v">' + esc(p.targetName) + '（' + esc(p.formatLabel) + '）</span></div>';
  if (p.writesFile) {
    html += '<div class="kv"><span class="k">写入路径</span><span class="v mono">' + esc(p.filePath) + '</span></div>';
    html += '<div class="kv"><span class="k">文件状态</span><span class="v">' +
      (p.existedBefore ? '已存在' : '不存在（将新建）') + '</span></div>';
  }
  html += '<div class="kv"><span class="k">注入键名</span><span class="v mono">' + esc(p.itemKey) + '</span></div>';
  html += '<div class="kv"><span class="k">使用密钥</span><span class="v">' + esc(p.keyLabel) +
    ' · 掩码 ' + esc(p.keyHint) + ' · 指纹 ' + esc(p.keyFingerprint) + '</span></div>';

  if (p.blocked) {
    html += '<div class="block-box">🛑 已按安全策略阻断：' + esc(p.blockedReason) + '</div>';
  }
  if (p.warnings && p.warnings.length) {
    html += '<div class="warn-box">' + p.warnings.map((w) => '• ' + esc(w)).join('<br>') + '</div>';
  }

  if (!p.writesFile) {
    html += '<div style="margin-top:10px"><div class="small dim" style="margin-bottom:4px">导出片段（自行粘贴到环境）</div>' +
      '<div class="snippet">' + esc(p.snippet) + '</div></div>';
  } else if (p.diff && p.diff.length) {
    html += '<div style="margin-top:10px"><div class="small dim" style="margin-bottom:4px">差异预览（Dry-Run）</div><div class="diff">';
    p.diff.forEach((line) => {
      const cls = line.kind === '+' ? 'added' : (line.kind === '-' ? 'removed' : 'context');
      html += '<div class="diff-line ' + cls + '"><span class="sign">' + esc(line.kind) + '</span><span>' +
        esc(line.text) + '</span></div>';
    });
    html += '</div></div>';
  }

  html += '<div style="display:flex;gap:8px;margin-top:12px">';
  if (!p.blocked && p.writesFile) {
    html += '<button class="btn primary" id="btn-apply">确认原子写入（自动备份）</button>';
  }
  html += '<button class="btn" id="btn-discard">放弃本次计划</button>';
  if (state.reveal) html += '<span class="small" style="color:var(--orange);align-self:center">⚠️ 正在显示明文</span>';
  html += '</div></div>';

  if (state.outcome) html += outcomeCard(state.outcome);
  host.innerHTML = html;

  const apply = $('#btn-apply');
  if (apply) apply.addEventListener('click', doApply);
  $('#btn-discard').addEventListener('click', () => {
    state.plan = null;
    renderPlan();
    updateStepper(2);
  });
}

function outcomeCard(o) {
  let html = '<div class="card"><h2>第四步：执行结果</h2>';
  html += '<div class="kv"><span class="k">结果</span><span class="v">' +
    (o.success ? '✅ ' : '❌ ') + esc(o.message) + '</span></div>';
  if (o.filePath) html += '<div class="kv"><span class="k">目标文件</span><span class="v mono">' + esc(o.filePath) + '</span></div>';
  if (o.backupPath) html += '<div class="kv"><span class="k">备份位置</span><span class="v mono">' + esc(o.backupPath) + '</span></div>';
  if (o.verifiedFingerprint) html += '<div class="kv"><span class="k">读回指纹</span><span class="v mono">' +
    esc(o.verifiedFingerprint) + '（写后读回校验通过）</span></div>';
  html += '</div>';
  return html;
}

async function doApply() {
  const form = state.lastInjectForm || injectForm();
  try {
    const res = await call('apply', form);
    state.outcome = res;
    state.plan = null;
    renderPlan();
    updateStepper(4);
    banner(res.success ? 'success' : 'error', res.message + (res.backupPath ? '（备份：' + res.backupPath + '）' : ''));
    await loadKeys();
    await loadAudit();
  } catch (err) {
    banner('error', String(err.message || err));
  }
}

async function doRollbackLatest() {
  const form = injectForm();
  try {
    const res = await call('rollbackLatest', { targetID: form.targetID, overridePath: form.overridePath });
    banner(res.success ? 'success' : 'error', res.message);
    await loadAudit();
  } catch (err) {
    banner('warning', String(err.message || err));
  }
}

function renderRollbackList() {
  const host = $('#rollback-host');
  const injects = state.audit.filter((a) => a.action === 'inject').slice(0, 10);
  let html = '<h2>回滚：最近注入记录</h2>';
  if (!injects.length) {
    html += '<div class="small dim">暂无注入记录。</div>';
  } else {
    injects.forEach((a) => {
      html += '<div class="audit-row">' +
        '<span class="audit-mark ' + (a.result === 'success' ? 's-valid' : 's-invalid') + '"></span>' +
        '<div class="audit-body">' +
          '<div class="audit-head"><span class="audit-action">' + esc(a.actionLabel) + '</span>' +
          '<span class="audit-time">' + esc(fmtTime(a.timestamp)) + '</span></div>' +
          '<div class="audit-msg">' + esc(a.message) + '</div>' +
          (a.filePath ? '<div class="audit-path">' + esc(a.filePath) + '</div>' : '') +
        '</div>' +
        (a.canRollback ? '<button class="btn small" data-rollback="' + esc(a.id) + '">回滚</button>' : '') +
      '</div>';
    });
  }
  host.innerHTML = html;
}

document.addEventListener('click', async (e) => {
  const btn = e.target.closest('[data-rollback]');
  if (!btn) return;
  try {
    const res = await call('rollback', { auditID: btn.dataset.rollback });
    banner(res.success ? 'success' : 'error', res.message);
    await loadAudit();
  } catch (err) {
    banner('error', String(err.message || err));
  }
});

/* ---------- 健康探测 ---------- */

function renderHealth() {
  const counts = { valid: 0, invalid: 0, quota: 0, unchecked: 0 };
  state.keys.forEach((k) => {
    const s = (k.lastCheck || {}).status || 'unchecked';
    if (counts[s] === undefined) counts.unchecked++;
    else if (s === 'unreachable' || s === 'unknown') counts.unchecked++;
    else counts[s]++;
  });

  $('#health-stats').innerHTML =
    statCard('有效', counts.valid, 's-valid') +
    statCard('无效', counts.invalid, 's-invalid') +
    statCard('额度/限流', counts.quota, 's-quota') +
    statCard('未探测', counts.unchecked, 's-unchecked');

  const host = $('#health-host');
  if (!state.keys.length) {
    host.innerHTML = '<div class="empty">还没有可探测的密钥，请先到「密钥库」新增。</div>';
    return;
  }
  let html = '<h2>逐项探测结果</h2>';
  state.keys.forEach((k) => {
    const c = k.lastCheck || {};
    const st = c.status || 'unchecked';
    html += '<div class="key-row">' +
      '<span class="status ' + statusClass(st) + '"></span>' +
      '<div class="key-main">' +
        '<div class="key-title"><span class="key-label">' + esc(k.label) + '</span>' +
        '<span class="chip">' + esc(providerName(k.providerID)) + '</span></div>' +
        '<div class="key-meta"><span class="' + statusTextClass(st) + '">' + esc(c.label || '未探测') + '</span>' +
        (c.latencyMS ? '<span>' + c.latencyMS + ' ms</span>' : '') +
        (c.checkedAt ? '<span>' + esc(fmtTime(c.checkedAt)) + '</span>' : '') + '</div>' +
        (c.message ? '<div class="small dim" style="margin-top:3px">' + esc(c.message) + '</div>' : '') +
      '</div>' +
      '<button class="btn small" data-check="' + esc(k.id) + '">探测</button>' +
    '</div>';
  });
  host.innerHTML = html;
}

function statCard(label, num, cls) {
  return '<div class="stat"><span class="dot ' + cls + '"></span><span class="num">' + num +
    '</span><span class="lbl">' + label + '</span></div>';
}

$('#health-host').addEventListener('click', async (e) => {
  const btn = e.target.closest('[data-check]');
  if (!btn) return;
  try {
    banner('info', '正在探测…');
    const res = await call('checkKey', { id: btn.dataset.check });
    banner(res.status === 'valid' ? 'success' : 'warning', '探测结果：' + res.label + ' — ' + res.message);
    await loadKeys();
  } catch (err) {
    banner('error', String(err.message || err));
  }
});

$('#btn-health-all').addEventListener('click', async () => {
  try {
    banner('info', '正在批量探测，请稍候…');
    const res = await call('checkAll', {});
    banner(res.valid === res.total ? 'success' : 'warning',
      '批量探测完成：' + res.valid + '/' + res.total + ' 个密钥鉴权通过');
    await loadKeys();
    await loadAudit();
  } catch (err) {
    banner('error', String(err.message || err));
  }
});

/* ---------- 审计日志 ---------- */

function auditMatch(a, filter) {
  if (filter === 'all') return true;
  if (filter === 'inject') return a.action === 'inject';
  if (filter === 'rollback') return a.action === 'rollback';
  if (filter === 'check') return a.action === 'healthCheck';
  if (filter === 'keys') return ['createKey', 'updateKey', 'deleteKey', 'enableKey', 'disableKey'].indexOf(a.action) >= 0;
  return true;
}

function renderAudit() {
  const host = $('#audit-host');
  const list = state.audit.filter((a) => auditMatch(a, state.auditFilter));
  if (!list.length) {
    host.innerHTML = '<div class="empty">暂无记录。新增密钥、执行注入或探测之后，这里会出现可追溯的记录。</div>';
    return;
  }
  let html = '';
  list.forEach((a) => {
    const cls = a.result === 'success' ? 's-valid' : (a.result === 'dryRun' ? 's-unknown' : 's-invalid');
    html += '<div class="audit-row">' +
      '<span class="audit-mark ' + cls + '"></span>' +
      '<div class="audit-body">' +
        '<div class="audit-head"><span class="audit-action">' + esc(a.actionLabel) + '</span>' +
        '<span class="audit-time">' + esc(fmtTime(a.timestamp)) + '</span></div>' +
        '<div class="audit-msg">' + esc(a.message) + '</div>' +
        (a.filePath ? '<div class="audit-path">文件：' + esc(a.filePath) + '</div>' : '') +
        (a.backupPath ? '<div class="audit-path">备份：' + esc(a.backupPath) + '</div>' : '') +
      '</div>' +
      (a.canRollback ? '<button class="btn small" data-rollback="' + esc(a.id) + '">回滚</button>' : '') +
    '</div>';
  });
  host.innerHTML = html;
}

document.querySelectorAll('#audit-tabs .tab').forEach((tab) => {
  tab.addEventListener('click', () => {
    document.querySelectorAll('#audit-tabs .tab').forEach((t) => t.classList.remove('active'));
    tab.classList.add('active');
    state.auditFilter = tab.dataset.filter;
    renderAudit();
  });
});

$('#btn-audit-refresh').addEventListener('click', loadAudit);

/* ---------- 设置 ---------- */

function renderSettings() {
  const i = state.info;
  $('#settings-info').innerHTML =
    '<h2>数据位置</h2>' +
    detailKV('数据目录', i.root || '—', true) +
    detailKV('密钥后端', i.storeBackend || '—') +
    detailKV('审计文件', i.auditFile || '—', true) +
    detailKV('厂商数量', i.providerCount || '0') +
    detailKV('落点数量', i.targetCount || '0') +
    ((i.bootWarnings && i.bootWarnings.length)
      ? '<div class="warn-box">' + i.bootWarnings.map(esc).join('<br>') + '</div>' : '');

  $('#settings-config').innerHTML =
    '<h2>配置模板（可覆盖内置预设）</h2>' +
    '<div class="small dim" style="line-height:1.7;margin-bottom:10px">' +
    '第三方工具的配置文件路径可能随版本变化。内置预设保持保守，并支持用配置模板覆盖，无需重新编译。' +
    '导出后编辑数据目录下的 config/providers.json 与 config/targets.json，重启应用即生效（同 id 覆盖，新 id 追加）。</div>' +
    '<button class="btn" id="btn-export-config">导出配置模板</button>' +
    '<div id="export-result" class="small dim" style="margin-top:8px"></div>';

  $('#settings-security').innerHTML =
    '<h2>安全等级与边界（请务必知悉）</h2>' +
    bullet('钥匙串后端（默认）', '密钥明文存放于 macOS 钥匙串，受系统加密与访问控制保护。') +
    bullet('本地加密文件后端', '降级方案。主密钥与密文位于同一台机器，只能防止「被误同步/被随手看到」，无法抵御已取得本机文件读取权限的攻击者。') +
    bullet('内存后端', '仅用于自动化测试与演示，进程退出即丢失。') +
    bullet('写入前必备份', '每次注入都会先备份原文件；回滚可精确还原，当初新建的文件回滚时会被删除。') +
    bullet('拒绝猜测', '目标键路径不存在、格式不匹配、文件不可写时一律阻断并报错，绝不擅自改写。') +
    bullet('不自动联网', '健康探测只在显式点击时发生，仅访问厂商官方域名，不向任何第三方上报。') +
    bullet('YAML/TOML 边界', '采用定点行替换而非全量解析：支持单层区块；不支持多层嵌套、流式写法、内联表与数组表。') +
    bullet('阻断条件', '受管区块标记不成对、JSON 键路径缺失等情形会直接阻断，不会留下半成品文件。');

  $('#settings-cli').innerHTML =
    '<h2>命令行基座（供 DSH 会话联动）</h2>' +
    '<div class="small dim" style="margin-bottom:8px">同仓库内置 keyinject 命令行工具，与界面共用同一套核心逻辑：</div>' +
    mono('keyinject keys list --json') +
    mono('keyinject inject --target shell-profile --key &lt;id&gt; --json    # 默认只预览') +
    mono('keyinject inject --target shell-profile --key &lt;id&gt; --yes     # 真实写入') +
    mono('keyinject rollback --target shell-profile --file ~/.zshrc') +
    '<div class="small dim" style="margin-top:8px;line-height:1.7">' +
    '约定：inject 默认 dry-run；输出中的密钥一律掩码；退出码 0 成功 / 1 失败 / 2 被安全策略阻断。</div>';

  const btn = $('#btn-export-config');
  if (btn) {
    btn.addEventListener('click', async () => {
      try {
        const res = await call('exportConfig', {});
        $('#export-result').textContent = res.written.length
          ? '已导出：' + res.written.join('、')
          : '配置模板已存在，未覆盖：' + res.dir;
        banner('success', '配置模板处理完成');
      } catch (err) {
        banner('error', String(err.message || err));
      }
    });
  }
}

function kv(k, v, mono) {
  return '<div class="kv"><span class="k">' + esc(k) + '</span><span class="v' +
    (mono ? ' mono' : '') + '">' + esc(v) + '</span></div>';
}

function bullet(t, d) {
  return '<div class="bullet-row"><span class="bullet-mark">•</span><span class="bullet-body">' +
    '<b>' + esc(t) + '</b><div class="small dim" style="line-height:1.65">' + esc(d) + '</div></span></div>';
}

function mono(t) {
  return '<div class="snippet" style="margin-bottom:6px">' + t + '</div>';
}

/* ---------- 启动 ---------- */

async function boot() {
  try {
    await loadAll();
    renderInjectPicker();
    renderPlan();
    renderSettings();
    switchPage('keys');
  } catch (err) {
    banner('error', '初始化失败：' + String(err.message || err));
  }
}

window.addEventListener('error', (e) => {
  banner('error', '前端脚本异常：' + e.message);
});

/* ---------- 自动化钩子（供应用内截图台账使用，不影响日常使用） ---------- */

window.__selectPage = function (page) { switchPage(page); };
window.__openAddKeyModal = function () { openModal(); };
window.__closeAddKeyModal = function () { closeModal(); };
window.__setBanner = function (kind, text) { banner(kind, text); };
window.__clearBanner = function () { var h = document.querySelector('#banner-host'); if (h) h.innerHTML = ''; };

/// 展开第一个分区的模型区块（截图台账用）
window.__expandKeyModels = function () {
  const boxes = document.querySelectorAll('#keys-host .key-models .km-body');
  boxes.forEach((b) => {
    b.classList.remove('hidden');
    const caret = b.parentNode.querySelector('.km-caret');
    if (caret) caret.textContent = '▾';
  });
  return 'expanded:' + boxes.length;
};

/// 关闭详情视图（截图台账用）
window.__closeKeyDetail = function () { closeKeyDetail(); };

/// 打开第一把密钥的详情视图（截图台账用）
window.__openKeyDetail = function () {
  const key = state.keys[0];
  if (!key) return 'no-keys';
  openKeyDetail(key.id);
  return 'detail:' + key.id;
};

window.__snapshotSetPath = function (path) {
  const el = document.querySelector('#i-path');
  if (el) el.value = path;
};
window.__snapshotPlan = function () { return doPlan(); };

window.addEventListener('DOMContentLoaded', boot);


/* ---------- 模型清单（Codex 模型目录可视化） ---------- */

state.models = null;
state.modelsOverview = null;

async function loadModels() {
  // 模型清单页以「跨宿主清单 + 网关事实源 + 同步计划」为唯一数据源。
  // 取舍：这里不读 Codex 目录的旧 models 接口——网关才是模型名的权威（REQ-018）。
  const all = $('#models-show-all') && $('#models-show-all').checked;
  try {
    await loadHostModels();
    renderGatewayCard();
    renderModelsOverview();
    renderHostModels();
    renderOverviewSummary();
    await loadModelsAdmin(all);
  } catch (e) {
    const host = $('#models-host');
    if (host) host.innerHTML = '<div class="empty">读取跨宿主模型清单失败：' + esc(e.message) + '</div>';
  }
}

/// 折叠区展开时的内容刷新钩子（供 details 的 toggle 事件调用）
function refreshOverviewFold() {
  const fold = $('#keys-overview');
  if (fold && fold.open) loadModels();
}

/* ---------- 模型清单：网关事实源卡片（REQ-018） ---------- */

function renderGatewayCard() {
  const host = $('#models-gateway');
  const gw = state.gatewayInfo;
  const plan = state.syncPlan;
  if (!host) return;
  if (!gw) {
    host.innerHTML = '<h2>网关事实源</h2><div class="empty">未读取到网关配置：' +
      '<code>~/.config/codex-gateway/config.json</code> 不存在或不可解析。本工具不猜测任何模型名，' +
      '因此同步动作已整体跳过。</div>';
    return;
  }
  const routes = gw.routes || [];
  let html = '<h2>网关事实源 <span class="chip ' + (gw.available ? 'src-probe' : 'src-inferred') + '">' +
    (gw.available ? '可用' : '不可用') + '</span></h2>' +
    '<div class="small">配置文件：<code class="mono">' + esc(gw.sourcePath || '-') + '</code>　·　' +
    '上游基址：<code class="mono">' + esc(gw.baseURL || '-') + '</code>　·　' +
    '上游模型 ' + (gw.models || []).length + ' 条　·　线路 ' + routes.length + ' 条</div>';
  if (routes.length) {
    html += '<div style="margin-top:8px">';
    routes.forEach((r) => {
      html += '<div class="detail-model-row"><code class="km-model-id">' + esc(r.route) + '</code>' +
        '<span class="dim small">→</span><code class="mono small">' + esc(r.upstreamModel) + '</code></div>';
    });
    html += '</div>';
  }
  if (plan) {
    const dsh = plan.dsh || {};
    const codex = plan.codex || {};
    html += '<div style="margin-top:10px" class="small">同步计划：' +
      (plan.allConsistent ? '两个宿主都已一致' : '存在差异，需要同步') + '　·　' +
      'DSH：' + esc(dsh.summary || '—') + '　·　Codex：' + esc(codex.summary || '—') + '</div>';
    [dsh, codex].forEach((t) => {
      (t.notes || []).forEach((n) => { html += '<div class="small dim">• ' + esc(n) + '</div>'; });
      if (t.failure) html += '<div class="small bad-text">⚠ ' + esc(t.failure) + '</div>';
    });
    html += '<div style="margin-top:10px">' +
      '<button class="btn primary" id="btn-sync-apply"' + (plan.allConsistent ? ' disabled' : '') +
      '>同步差异到 DSH 与 Codex（先备份）</button>' +
      '<span class="small dim" style="margin-left:8px">默认只增不减：DSH 侧不会删除你自建的模型</span></div>';
    const btn = $('#btn-sync-apply');
    if (btn) {
      btn.addEventListener('click', async () => {
        if (!confirm('确认把网关声明的差异同步到 DSH 与 Codex？\n写入前会自动备份原文件。')) return;
        btn.disabled = true;
        try {
          const res = await call('syncApply');
          banner('success', '同步完成：DSH ' + (res.dsh ? res.dsh.summary : '—') + '；Codex ' + (res.codex ? res.codex.summary : '—'));
        } catch (e) {
          banner('error', '同步失败：' + e.message);
        }
        await loadModels();
        await loadAudit();
      });
    }
  }
  host.innerHTML = html;
}

/* ---------- 模型清单：跨宿主总览（REQ-016） ---------- */

function renderModelsOverview() {
  const host = $('#models-origin');
  const ov = state.hostModelsOverview || {};
  if (!host) return;
  if (ov.loadError) {
    host.innerHTML = '<h2>清单从哪来</h2><div class="empty">读取失败：' + esc(ov.loadError) + '</div>';
    return;
  }
  const dshExists = ov.dshSettingsExists ? '' : '<span class="bad-text">文件不存在</span>';
  host.innerHTML = '<h2>清单从哪来</h2>' +
    '<div class="small">① <b>DSH 桌面端</b>：<code class="mono">' + esc(ov.dshSettingsPath || '-') + '</code> ' + dshExists +
      '　声明模型 <b>' + (ov.dshDeclared || 0) + '</b> 条，凭据已配置 <b>' + (ov.dshCredentialConfigured || 0) + '</b> 条' +
      '（只读：本工具不写入 settings.yaml）</div>' +
    '<div class="small">② <b>Codex 桌面端</b>：<code class="mono">' + esc(ov.codexCatalogPath || '-') + '</code>　' +
      '网关条目 <b>' + (ov.codexGatewayCount || 0) + '</b> 条，官方条目 ' + (ov.codexOfficialCount || 0) + ' 条；' +
      '当前默认模型 <code class="mono">' + esc(ov.codexConfigModel || '(未设置)') + '</code>' +
      '，供应商 <code class="mono">' + esc(ov.codexConfigProvider || '-') + '</code>' +
      '，路由体检 ' + (ov.codexRoutingHealthy ? '<span class="ok-text">正常</span>' : '<span class="bad-text">异常</span>') + '</div>' +
    '<div class="small dim" style="margin-top:8px">两份声明合并去重后共 <b>' + (ov.uniqueModels || 0) + '</b> 个模型身份' +
      '（原始声明 ' + (ov.total || 0) + ' 条，同一模型在两边的别名已归并为一条）；' +
      '其中已有密钥绑定 <b>' + (ov.boundKeyCount || 0) + '</b> 把。</div>' +
    '<div class="small dim">模型名与地址的事实源是网关自己的配置：本工具不内置任何模型名单，' +
      '网关加模型后执行一次同步即可补齐差异。</div>';
}

/* ---------- 模型清单：跨宿主模型明细 ---------- */

function renderHostModels() {
  const host = $('#models-host');
  const groups = state.hostModelGroups || [];
  if (!host) return;
  if (!groups.length) {
    host.innerHTML = '<div class="empty">没有读到任何宿主的模型声明。' +
      '<div class="small" style="margin-top:6px">请确认 DSH 的 settings.yaml 与 Codex 的 codex-gateway-models.json 至少存在一个。</div></div>';
    return;
  }
  const q = ($('#models-filter') && $('#models-filter').value || '').trim().toLowerCase();
  let html = '<h2>条目明细 <span class="small dim">共 ' + groups.length + ' 个模型身份</span></h2>';
  let shown = 0;
  groups.forEach((g) => {
    const haystack = [g.displayName, g.normalizedID, (g.aliases || []).join(' '),
      (g.records || []).map((r) => r.credentialKey + ' ' + r.endpoint + ' ' + r.owner).join(' ')].join(' ').toLowerCase();
    if (q && haystack.indexOf(q) < 0) return;
    shown++;
    html += '<div class="key-group" style="margin-bottom:10px">' +
      '<div class="model-group-head">' +
        '<span class="key-group-name">' + esc(g.displayName || g.normalizedID) + '</span>' +
        (g.isGateway ? '<span class="chip warn">网关模型</span>' : '') +
        (g.hosts || []).map((h) => '<span class="chip plain">' + esc(h.label) + '</span>').join('') +
        '<span class="chip plain">' + (g.records || []).length + ' 条声明</span>' +
      '</div><div style="padding:4px 0 0 4px">';
    (g.records || []).forEach((r) => {
      html += '<div class="detail-model-row">' +
        '<code class="km-model-id">' + esc(r.id) + '</code>' +
        '<span class="chip plain">' + esc(r.hostLabel) + '</span>' +
        (r.inMenu ? '<span class="chip plain">菜单可见</span>' : '<span class="chip plain">已隐藏</span>') +
        (r.credentialKey ? '<span class="chip plain">凭据 ' + esc(r.credentialKey) + '</span>' : '') +
        '<button class="icon-btn" style="margin-left:auto" data-act="copy-model" data-model="' + esc(r.id) + '" title="复制模型 ID">📋</button>' +
        '</div>' +
        '<div class="small dim evidence" style="padding:0 2px 6px 18px">来源 ' + esc(r.sourcePath) +
          (r.endpoint ? '　·　端点 ' + esc(r.endpoint) : '') + '</div>';
    });
    html += '</div></div>';
  });
  if (!shown) html += '<div class="empty">没有匹配「' + esc(q) + '」的模型。</div>';
  host.innerHTML = html;
}

$('#models-host') && $('#models-host').addEventListener('click', async (e) => {
  const btn = e.target.closest('[data-act="copy-model"]');
  if (!btn) return;
  await call('copy', { text: btn.dataset.model || '' });
  banner('success', '已复制模型 ID：' + (btn.dataset.model || ''));
});

/* ---------- 模型清单：Codex 目录管理区 ---------- */

function renderModelsAdmin(all) {
  const host = $('#models-admin-host');
  if (!host) return;
  const admin = state.modelsAdmin || {};
  const entries = state.models || [];
  const codex = (state.hostModelsOverview || {}).codex || {};
  let html = '<h2>Codex 模型目录管理</h2>' +
    '<div class="small">目录文件：<code class="mono">' + esc(codex.path || admin.catalogPath || '-') + '</code>　·　' +
    '共 ' + (admin.total || entries.length || 0) + ' 条，网关条目 ' + (admin.gateway || 0) + ' 条。' +
    '“菜单可见”决定该条目是否出现在 Codex 顶部模型选择器里。</div>';
  html += '<div style="margin-top:8px"><label class="mini-check"><input type="checkbox" id="models-show-all"' +
    (all ? ' checked' : '') + '><span>显示 Codex 官方条目（默认只看网关条目）</span></label></div>';
  html += '<div style="margin-top:10px"><button class="btn" id="btn-model-add">＋ 新增网关模型</button>' +
    '<span class="small dim" style="margin-left:8px">Slug 必须是网关侧真实的模型名（例如 ark/DeepSeek-V4.1-Flash）</span></div>';
  if (entries.length) {
    html += '<div style="margin-top:10px">';
    entries.forEach((m) => {
      html += '<div class="key-row">' +
        '<span class="status ' + (m.inPicker ? 's-valid' : 's-unchecked') + '"></span>' +
        '<div class="key-main">' +
          '<div class="key-title"><span class="key-label">' + esc(m.displayName) + '</span>' +
          '<span class="chip' + (m.isGateway ? ' warn' : '') + '">' + esc(m.source || (m.isGateway ? '公司网关' : 'Codex 官方')) + '</span>' +
          '<span class="chip">' + (m.inPicker ? '菜单可见' : '已隐藏') + '</span></div>' +
          '<div class="key-meta"><code>' + esc(m.slug) + '</code></div>' +
          (m.description ? '<div class="small dim" style="margin-top:3px">' + esc(m.description) + '</div>' : '') +
        '</div>' +
        '<button class="btn small" data-model-toggle="' + esc(m.slug) + '" data-in-picker="' + (m.inPicker ? '1' : '0') + '">' +
          (m.inPicker ? '隐藏' : '显示') + '</button>' +
        (m.isGateway ? '<button class="btn small danger" data-model-rm="' + esc(m.slug) + '">删除</button>' : '') +
        '</div>';
    });
    html += '</div>';
  }
  host.innerHTML = html;

  const allSwitch = $('#models-show-all');
  if (allSwitch) {
    allSwitch.addEventListener('change', () => loadModelsAdmin(allSwitch.checked));
  }
  const addBtn = $('#btn-model-add');
  if (addBtn) {
    addBtn.addEventListener('click', async () => {
      const slug = prompt('网关侧真实模型名（例如 ark/DeepSeek-V4.1-Flash）');
      if (!slug) return;
      const name = prompt('Codex 菜单里的显示名（例如 DeepSeek V4.1（公司网关））', slug + '（公司网关）');
      if (!name) return;
      try {
        const res = await call('addModel', { slug: slug, name: name, inPicker: true });
        banner(res.added ? 'success' : 'error', res.added ? '已新增 ' + slug + '，重启 Codex 后出现在顶部菜单' : '该 slug 已存在：' + slug);
        loadModels();
      } catch (e) {
        banner('error', '新增失败：' + e.message);
      }
    });
  }
  host.querySelectorAll('[data-model-toggle]').forEach((el) => {
    el.addEventListener('click', async () => {
      const slug = el.dataset.modelToggle;
      const next = el.dataset.inPicker !== '1';
      try {
        await call('setModelPicker', { slug: slug, inPicker: next });
        banner('success', '已把 ' + slug + ' 设为' + (next ? '菜单可见' : '隐藏') + '（重启 Codex 后生效）');
        loadModels();
      } catch (e) {
        banner('error', '切换失败：' + e.message);
      }
    });
  });
  host.querySelectorAll('[data-model-rm]').forEach((el) => {
    el.addEventListener('click', async () => {
      const slug = el.dataset.modelRm;
      if (!confirm('从模型目录删除 ' + slug + '？Codex 菜单里将不再出现该条目。')) return;
      try {
        const res = await call('removeModel', { slug: slug });
        banner(res.removed ? 'success' : 'error', res.removed ? '已删除 ' + slug : '未删除：' + slug);
        loadModels();
      } catch (e) {
        banner('error', '删除失败：' + e.message);
      }
    });
  });
}

/// 只重渲染管理区（勾选「显示全部」时不必重跑整个页面桥接）
async function loadModelsAdmin(all) {
  try {
    const data = await call('models', { all: !!all });
    state.models = data.models || [];
    state.modelsAdmin = data.overview || {};
  } catch (e) {
    banner('error', '读取 Codex 模型目录失败：' + e.message);
  }
  renderModelsAdmin(all);
}

// 跨宿主总览折叠区：展开时才加载（闭合性 + 不打扰首屏）。

// 注：原「模型清单」页的 #models-filter 搜索框已随页面合并移除；
// 总览内的搜索改由密钥页统一搜索框承担（格式塔：一个页面一个搜索入口）。
const keysOverviewFold = $('#keys-overview');
if (keysOverviewFold) {
  keysOverviewFold.addEventListener('toggle', () => {
    if (keysOverviewFold.open) loadModels();
  });
}
