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
  lastInjectForm: null,
  selectedTargetID: '',
  targetFilter: 'all',
  editingKey: null,
  editingTarget: null
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

/* ---------- 导航 ---------- */

function switchPage(page) {
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
  } else if (page === 'models') {
    loadModels();
  }
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

function renderKeys() {
  const host = $('#keys-host');
  if (!state.keys.length) {
    host.innerHTML = '<div class="empty"><div class="big">🔑</div>' +
      '<div>密钥库还是空的</div>' +
      '<div class="small" style="margin-top:6px">点击右上角「新增密钥」，把大模型平台申请的 API Key 存进本机密钥后端。</div></div>';
    return;
  }

  let html = '';
  state.keys.forEach((k) => {
    const st = (k.lastCheck || {}).status || 'unchecked';
    const stLabel = (k.lastCheck || {}).label || '未探测';
    const shown = state.reveal && k.secret ? k.secret : k.hint;
    html +=
      '<div class="key-card" data-id="' + esc(k.id) + '">' +
        '<div class="key-card-left">' +
          '<div class="key-card-title-row">' +
            '<span class="status ' + statusClass(st) + '" title="' + esc(stLabel) + '"></span>' +
            '<span class="key-card-label">' + esc(k.label) + '</span>' +
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
        '</div>' +
        '<div class="key-card-dock">' +
          '<button class="btn small" data-act="edit" data-id="' + esc(k.id) + '">✏️ 编辑</button>' +
          '<button class="btn small" data-act="check" data-id="' + esc(k.id) + '">🩺 探测</button>' +
          '<label class="switch" title="启用/禁用"><input type="checkbox" data-act="toggle" data-id="' +
            esc(k.id) + '"' + (k.enabled ? ' checked' : '') + '><span></span></label>' +
          '<button class="icon-btn" data-act="delete" data-id="' + esc(k.id) + '" title="删除">🗑</button>' +
        '</div>' +
      '</div>';
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
  try {
    if (act === 'edit') {
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

/* ---------- 注入中心 ---------- */

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


/* ---------- 模型清单（Codex 模型目录可视化） ---------- */

state.models = null;
state.modelsOverview = null;

async function loadModels() {
  try {
    const all = $('#models-show-all') && $('#models-show-all').checked;
    const data = await call('models', { all: !!all });
    state.models = data.models || [];
    state.modelsOverview = data.overview || {};
    renderRouteCard();
    renderModels();
  } catch (e) {
    $('#models-host').innerHTML = '<div class="empty">读取模型目录失败：' + esc(e.message) + '</div>';
  }
}

async function renderRouteCard() {
  const host = $('#route-card');
  try {
    const r = await call('gatewayCheck');
    const ok = r.healthy;
    host.innerHTML =
      '<h2>Codex 网关路由体检</h2>' +
      '<div class="small ' + (ok ? 'ok-text' : 'bad-text') + '">' + esc(r.summary) + '</div>' +
      '<div class="small dim" style="margin-top:6px">配置文件：' + esc(r.configPath) + '</div>' +
      '<div style="margin-top:10px"><button class="btn ' + (ok ? '' : 'primary') + '" id="btn-route-fix"' + (ok ? ' disabled' : '') + '>修复路由（写回 codex_gateway）</button>' +
      '<span class="small dim" style="margin-left:8px">launchd 常驻守护每 10 秒自动体检一次，通常无需手动修复</span></div>';
    const btn = $('#btn-route-fix');
    if (btn) {
      btn.addEventListener('click', async () => {
        btn.disabled = true;
        try {
          const res = await call('gatewayRepair');
          banner('success', '已修复路由：' + res.summary + (res.backupPath ? '（备份：' + res.backupPath + '）' : ''));
        } catch (e) {
          banner('error', '修复失败：' + e.message);
        }
        renderRouteCard();
      });
    }
  } catch (e) {
    host.innerHTML = '<div class="empty">路由体检失败：' + esc(e.message) + '</div>';
  }
}

function renderModels() {
  const ov = state.modelsOverview || {};
  if ($('#catalog-path')) $('#catalog-path').textContent = ov.catalogPath || '~/.codex/codex-gateway-models.json';

  $('#models-origin').innerHTML =
    '<h2>清单从哪来</h2>' +
    '<div class="small">① Codex 官方条目：来自 Codex 自带的 <code>codex debug models --bundled</code>，本工具不改动它们。</div>' +
    '<div class="small">② 公司网关条目：由「密钥库 → 一键注入」或 <code>keyinject models add</code> 写入，' +
    '显示名带「（公司网关）」后缀，并在 <code>config.toml</code> 里通过 <code>model_provider = "codex_gateway"</code> 路由到你的网关 <code>' + esc(ov.configProvider || '-') + '</code>。</div>' +
    '<div class="small dim" style="margin-top:8px">目录共 ' + (ov.total || 0) + ' 条：公司网关 ' + (ov.gateway || 0) + ' 条（菜单可见 ' + (ov.gatewayInPicker || 0) + '），官方 ' + ((ov.total || 0) - (ov.gateway || 0)) + ' 条（菜单可见 ' + (ov.officialInPicker || 0) + '）。' +
    '已注册到 config.toml：' + (ov.registeredInConfig ? '是' : '否') + '；当前默认模型：' + esc(ov.configModel || '(未设置)') + '。</div>';

  const host = $('#models-host');
  if (!state.models || !state.models.length) {
    host.innerHTML = '<div class="empty">还没有公司网关模型。点右上角「＋ 新增网关模型」，或到「注入中心」执行一键注入来自动登记。</div>';
    return;
  }
  let html = '<h2>条目明细</h2>';
  state.models.forEach((m) => {
    const chipCls = m.isGateway ? 'chip warn' : 'chip';
    html += '<div class="key-row">' +
      '<span class="status ' + (m.inPicker ? 's-valid' : 's-unchecked') + '"></span>' +
      '<div class="key-main">' +
        '<div class="key-title"><span class="key-label">' + esc(m.displayName) + '</span>' +
        '<span class="' + chipCls + '">' + esc(m.source) + '</span>' +
        '<span class="chip">' + (m.inPicker ? '菜单可见' : '已隐藏') + '</span></div>' +
        '<div class="key-meta"><code>' + esc(m.slug) + '</code></div>' +
        (m.description ? '<div class="small dim" style="margin-top:3px">' + esc(m.description) + '</div>' : '') +
      '</div>' +
      '<button class="btn small" data-model-toggle="' + esc(m.slug) + '" data-in-picker="' + (m.inPicker ? '1' : '0') + '">' + (m.inPicker ? '隐藏' : '显示') + '</button>' +
      (m.isGateway ? '<button class="btn small danger" data-model-rm="' + esc(m.slug) + '">删除</button>' : '') +
      '</div>';
  });
  host.innerHTML = html;

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

document.addEventListener('DOMContentLoaded', () => {
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
  const allSwitch = $('#models-show-all');
  if (allSwitch) allSwitch.addEventListener('change', loadModels);
});
