/* ==========================================================================
   Key 注入器 · 前端逻辑
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
      reject(new Error('桥接不可用：请通过 Key 注入器应用打开本页面'));
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
    }, 30000);
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
  lastInjectForm: null
};

/* ---------- 工具 ---------- */

const $ = (sel) => document.querySelector(sel);

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

/* ---------- 导航 ---------- */

function switchPage(page) {
  state.page = page;
  document.querySelectorAll('.nav-item').forEach((el) => {
    el.classList.toggle('active', el.dataset.page === page);
  });
  document.querySelectorAll('.page').forEach((el) => {
    el.classList.toggle('hidden', el.id !== 'page-' + page);
  });
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
  await loadAudit();
  renderFoot();
}

async function loadKeys() {
  state.keys = await call('keys', { reveal: state.reveal });
  renderKeys();
  renderHealth();
  renderNavCounts();
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

function renderKeys() {
  const host = $('#keys-host');
  if (!state.keys.length) {
    host.innerHTML = '<div class="empty"><div class="big">🔑</div>' +
      '<div>密钥库还是空的</div>' +
      '<div class="small" style="margin-top:6px">点击右上角「新增密钥」，把大模型平台申请的 API Key 存进本机密钥后端。</div></div>';
    return;
  }

  let html = '<div class="card">';
  state.keys.forEach((k) => {
    const st = (k.lastCheck || {}).status || 'unchecked';
    const stLabel = (k.lastCheck || {}).label || '未探测';
    const shown = state.reveal && k.secret ? k.secret : k.hint;
    html +=
      '<div class="key-row">' +
        '<span class="status ' + statusClass(st) + '" title="' + esc(stLabel) + '"></span>' +
        '<div class="key-main">' +
          '<div class="key-title">' +
            '<span class="key-label">' + esc(k.label) + '</span>' +
            '<span class="chip">' + esc(providerName(k.providerID)) + '</span>' +
            (k.enabled ? '' : '<span class="chip plain">已禁用</span>') +
            (k.tags || []).map((t) => '<span class="chip plain">' + esc(t) + '</span>').join('') +
          '</div>' +
          '<div class="key-meta">' +
            '<span>' + esc(shown) + '</span>' +
            '<span>指纹 ' + esc(k.fingerprint) + '</span>' +
            '<span class="' + statusTextClass(st) + '">' + esc(stLabel) +
              (k.lastCheck && k.lastCheck.latencyMS ? ' · ' + k.lastCheck.latencyMS + 'ms' : '') + '</span>' +
            '<span>优先级 ' + esc(k.priority) + '</span>' +
          '</div>' +
        '</div>' +
        '<div class="key-actions">' +
          '<button class="btn small" data-act="check" data-id="' + esc(k.id) + '">探测</button>' +
          '<button class="btn small" data-act="copy" data-id="' + esc(k.id) + '">复制指纹</button>' +
          '<label class="switch" title="启用/禁用"><input type="checkbox" data-act="toggle" data-id="' +
            esc(k.id) + '"' + (k.enabled ? ' checked' : '') + '><span></span></label>' +
          '<button class="icon-btn" data-act="delete" data-id="' + esc(k.id) + '" title="删除">🗑</button>' +
        '</div>' +
      '</div>';
  });
  html += '</div>';

  if (state.reveal) {
    html += '<div class="warn-box">⚠️ 当前正在显示完整明文，请注意屏幕共享与录屏。</div>';
  }
  host.innerHTML = html;
}

$('#keys-host').addEventListener('click', async (e) => {
  const btn = e.target.closest('[data-act]');
  if (!btn) return;
  const id = btn.dataset.id;
  const act = btn.dataset.act;
  const record = state.keys.find((k) => k.id === id);
  try {
    if (act === 'check') {
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

/* ---------- 新增密钥弹窗 ---------- */

function openModal() {
  const sel = $('#f-provider');
  sel.innerHTML = state.providers.map((p) => '<option value="' + esc(p.id) + '">' + esc(p.name) + '</option>').join('');
  $('#f-label').value = '';
  $('#f-secret').value = '';
  $('#f-priority').value = '100';
  $('#f-tags').value = '';
  $('#f-note').value = '';
  $('#f-warnings').classList.add('hidden');
  renderProviderInfo();
  $('#modal-mask').classList.remove('hidden');
  $('#f-label').focus();
}

function closeModal() { $('#modal-mask').classList.add('hidden'); }

function clientWarnings(secret, provider) {
  const out = [];
  if (!secret) return out;
  if (secret !== secret.trim()) out.push('密钥首尾含空白字符，保存时会自动去除');
  if (/\s/.test(secret.trim())) out.push('密钥中间含空格或换行，疑似复制错误');
  const t = secret.trim();
  if (t.length < 16) out.push('密钥长度短于 16 字符，多数厂商密钥不会这么短');
  const prefixes = (provider && provider.secretPrefixes) || [];
  if (prefixes.length && !prefixes.some((p) => t.startsWith(p))) {
    out.push('该厂商密钥通常以 ' + prefixes.join(' / ') + ' 开头，请复核是否贴错');
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

$('#btn-add-key').addEventListener('click', openModal);
$('#modal-close').addEventListener('click', closeModal);
$('#modal-cancel').addEventListener('click', closeModal);
$('#modal-mask').addEventListener('click', (e) => { if (e.target.id === 'modal-mask') closeModal(); });

$('#modal-save').addEventListener('click', async () => {
  const payload = {
    providerID: $('#f-provider').value,
    label: $('#f-label').value.trim(),
    secret: $('#f-secret').value,
    priority: parseInt($('#f-priority').value, 10) || 100,
    tags: $('#f-tags').value.split(',').map((s) => s.trim()).filter(Boolean),
    note: $('#f-note').value.trim()
  };
  if (!payload.secret.trim()) { banner('warning', '请先粘贴密钥明文'); return; }
  if (!payload.label) payload.label = providerName(payload.providerID) + ' 密钥';
  try {
    const res = await call('addKey', payload);
    closeModal();
    const w = res.warnings || [];
    banner(w.length ? 'warning' : 'success',
      '已保存密钥「' + res.record.label + '」（掩码 ' + res.record.hint + '）' +
      (w.length ? '；注意：' + w.join('；') : ''));
    await loadKeys();
    await loadAudit();
  } catch (err) {
    banner('error', String(err.message || err));
  }
});

/* ---------- 注入中心 ---------- */

function injectForm() {
  const target = targetById($('#i-target') ? $('#i-target').value : '');
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
  const prevTarget = state.lastInjectForm ? state.lastInjectForm.targetID : (state.targets[0] || {}).id;
  const target = targetById(prevTarget) || state.targets[0];
  if (!target) { $('#inject-picker').innerHTML = '<div class="empty">没有可用的注入落点</div>'; return; }

  const prevKey = state.lastInjectForm ? state.lastInjectForm.keyID : '';
  const candidates = state.keys.filter((k) => !target.providerID || k.providerID === target.providerID);

  let html = '<h2>第一步：选择注入落点与密钥</h2>';
  html += '<div class="grid-2">';

  html += '<label class="field"><span>注入落点</span><select id="i-target">' +
    state.targets.map((t) =>
      '<option value="' + esc(t.id) + '"' + (t.id === target.id ? ' selected' : '') + '>' +
      esc(t.name) + ' · ' + esc(t.formatLabel) + (t.requiresPath ? '（需填路径）' : '') + '</option>').join('') +
    '</select></label>';

  html += '<label class="field"><span>使用密钥</span><select id="i-key">' +
    (candidates.length
      ? candidates.map((k) =>
          '<option value="' + esc(k.id) + '"' + (k.id === prevKey ? ' selected' : '') + '>' +
          esc(k.label) + ' · ' + esc(providerName(k.providerID)) + ' · ' + esc(k.hint) +
          (k.enabled ? '' : '（已禁用）') + '</option>').join('')
      : '<option value="">（该落点没有匹配的密钥）</option>') +
    '</select></label>';

  html += '</div>';
  html += '<div class="warn-box" style="background:var(--panel-2);color:var(--text-dim)">' + esc(target.note) + '</div>';

  const showPath = target.writesFile;
  const showJson = target.format === 'json' || target.format === 'plist';
  const showSection = target.format === 'yaml' || target.format === 'toml';

  html += '<div class="grid-3">';
  if (showPath) {
    html += '<label class="field"><span>目标文件路径</span><input type="text" id="i-path" value="' +
      esc(state.lastInjectForm ? state.lastInjectForm.overridePath : target.filePath) +
      '" placeholder="' + (target.filePath ? esc(target.filePath) : '必填，例如 ~/.zshrc') + '"></label>';
  }
  if (showJson) {
    html += '<label class="field"><span>键路径（点号分隔）</span><input type="text" id="i-jsonpath" value="' +
      esc(state.lastInjectForm ? state.lastInjectForm.jsonPath : target.jsonPath) +
      '" placeholder="例如 env.OPENAI_API_KEY"></label>';
  }
  if (showSection) {
    html += '<label class="field"><span>区块名（可留空）</span><input type="text" id="i-section" value="' +
      esc(state.lastInjectForm ? state.lastInjectForm.section : target.section) +
      '" placeholder="例如 openai"></label>';
  }
  html += '<label class="field"><span>键名（可留空取默认）</span><input type="text" id="i-itemkey" value="' +
    esc(state.lastInjectForm ? state.lastInjectForm.itemKey : (target.itemKey || '')) +
    '" placeholder="' + esc(target.itemKey || '按厂商默认环境变量名') + '"></label>';
  html += '</div>';

  html += '<div style="display:flex;gap:8px;margin-top:4px">' +
    '<button class="btn primary" id="btn-plan">生成注入计划（dry-run）</button>' +
    '<button class="btn" id="btn-rollback-latest">回滚该落点最近一次注入</button>' +
    '</div>';

  $('#inject-picker').innerHTML = html;

  $('#i-target').addEventListener('change', () => {
    state.lastInjectForm = null;
    state.plan = null;
    renderInjectPicker();
    renderPlan();
  });
  $('#btn-plan').addEventListener('click', doPlan);
  $('#btn-rollback-latest').addEventListener('click', doRollbackLatest);
}

async function doPlan() {
  const form = injectForm();
  if (!form.targetID) { banner('warning', '请先选择注入落点'); return; }
  if (!form.keyID) { banner('warning', '该落点没有可用的密钥，请先到「密钥库」新增'); return; }
  state.lastInjectForm = form;
  try {
    const plan = await call('plan', form);
    state.plan = plan;
    state.outcome = null;
    renderPlan();
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
  let html = '<div class="card"><h2>第二步：核对差异<span class="hint">' +
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
    html += '<div style="margin-top:10px"><div class="small dim" style="margin-bottom:4px">差异预览</div><div class="diff">';
    p.diff.forEach((line) => {
      const cls = line.kind === '+' ? 'added' : (line.kind === '-' ? 'removed' : 'context');
      html += '<div class="diff-line ' + cls + '"><span class="sign">' + esc(line.kind) + '</span><span>' +
        esc(line.text) + '</span></div>';
    });
    html += '</div></div>';
  }

  html += '<div style="display:flex;gap:8px;margin-top:12px">';
  if (!p.blocked && p.writesFile) {
    html += '<button class="btn primary" id="btn-apply">确认写入（自动备份）</button>';
  }
  html += '<button class="btn" id="btn-discard">放弃本次计划</button>';
  if (state.reveal) html += '<span class="small" style="color:var(--orange);align-self:center">⚠️ 正在显示明文</span>';
  html += '</div></div>';

  if (state.outcome) html += outcomeCard(state.outcome);
  host.innerHTML = html;

  const apply = $('#btn-apply');
  if (apply) apply.addEventListener('click', doApply);
  $('#btn-discard').addEventListener('click', () => { state.plan = null; renderPlan(); });
}

function outcomeCard(o) {
  let html = '<div class="card"><h2>第三步：执行结果</h2>';
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
    kv('数据目录', i.root || '—', true) +
    kv('密钥后端', i.storeBackend || '—') +
    kv('审计文件', i.auditFile || '—', true) +
    kv('厂商数量', i.providerCount || '0') +
    kv('落点数量', i.targetCount || '0') +
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
window.__snapshotSetPath = function (path) {
  const el = document.querySelector('#i-path');
  if (el) el.value = path;
};
window.__snapshotPlan = function () { return doPlan(); };

window.addEventListener('DOMContentLoaded', boot);
