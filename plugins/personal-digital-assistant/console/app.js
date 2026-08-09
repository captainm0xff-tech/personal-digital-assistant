let state = null;
const $ = selector => document.querySelector(selector);
const $$ = selector => [...document.querySelectorAll(selector)];
const esc = value => String(value ?? '').replace(/[&<>'"]/g, char => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
})[char]);
const active = item => !['completed', 'cancelled'].includes(item.status);

function fmt(value) {
  if (!value) return '未设置';
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime())
    ? value.slice(0, 16).replace('T', ' ')
    : parsed.toLocaleString('zh-CN', {month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false});
}

const methodName = value => ({
  dingtalk_auto: '钉钉自动联系', dingtalk_approval: '钉钉联系，发送前审批', remind_me: '只提醒我处理'
})[value] || '钉钉联系，发送前审批';

function period(minutes) {
  minutes = Number(minutes || 0);
  if (!minutes) return '仅一次';
  if (minutes % 10080 === 0) return `每 ${minutes / 10080} 周`;
  if (minutes % 1440 === 0) return `每 ${minutes / 1440} 天`;
  if (minutes % 60 === 0) return `每 ${minutes / 60} 小时`;
  return `每 ${minutes} 分钟`;
}

function toast(text, error = false) {
  const element = $('#toast');
  element.textContent = text;
  element.className = error ? 'show error' : 'show';
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => element.className = '', 3000);
}

async function api(path, options = {}) {
  const response = await fetch(path, {headers: {'Content-Type': 'application/json'}, ...options});
  const data = await response.json();
  if (!response.ok) throw new Error(data.message || '操作失败');
  return data;
}

function showView(name) {
  $$('.view').forEach(view => view.classList.toggle('active', view.id === `view-${name}`));
  $$('.nav-item').forEach(item => item.classList.toggle('active', item.dataset.view === name));
  const titles = {
    overview: '今日总览', tasks: '我的待办', followups: '单项跟进', projects: '项目管理',
    emails: '企业邮箱', knowledge: '知识库', whitelist: '白名单管理', channels: '沟通渠道', system: '系统设置'
  };
  $('#page-title').textContent = titles[name];
}

$$('.nav-item').forEach(button => button.onclick = () => { location.hash = button.dataset.view; showView(button.dataset.view); });
$$('[data-jump]').forEach(button => button.onclick = () => showView(button.dataset.jump));

function workRow(item) {
  const owner = item.owner_name || (item.kind === 'daily' ? '个人待办' : '');
  return `<div class="work-row"><i class="priority"></i><span><b>${esc(item.title)}</b><small>${esc(owner)} · ${fmt(item.next_action_at || item.due_at)}</small></span><em class="badge ${item.status === 'overdue' ? 'red' : 'gray'}">${esc(item.priority)}</em></div>`;
}

function renderOverview() {
  const counts = state.counts;
  ['tasks', 'followups', 'projects', 'emails'].forEach(key => $(`#metric-${key}`).textContent = counts[key]);
  const total = counts.tasks + counts.followups + counts.projects + counts.emails;
  $('#hero-title').textContent = counts.overdue ? `有 ${counts.overdue} 项工作已经逾期` : total ? `今天有 ${total} 项工作在推进` : '工作一切正常';
  $('#hero-copy').textContent = counts.overdue ? '建议先处理逾期事项，助理会继续跟进其他任务。' : '助理正在后台整理消息、任务和项目节点。';
  const work = [...state.tasks, ...state.followups, ...state.projects].filter(active).sort((a, b) => (a.priority || 'P3').localeCompare(b.priority || 'P3')).slice(0, 5);
  $('#overview-work').className = work.length ? 'stack' : 'stack empty';
  $('#overview-work').innerHTML = work.length ? work.map(workRow).join('') : '暂无需要处理的工作';
  const connectedChannel = (state.channels || []).find(item => item.status === 'connected');
  $('#message-dot').className = `status-dot ${connectedChannel ? 'good' : ''}`;
  $('#message-brief').textContent = connectedChannel ? `${connectedChannel.display_name || connectedChannel.channel_type} 实时连接` : '等待绑定并启动沟通平台适配器';
  $('#message-state').textContent = connectedChannel ? '运行中' : '待连接';
  const taskReady = Boolean(state.profile?.setup_completed);
  $('#task-dot').className = `status-dot ${taskReady ? 'good' : ''}`;
  $('#task-brief').textContent = taskReady ? '由 WorkBuddy / Agent 按规则推进' : '请先完成助理初始化';
  $('#task-state').textContent = taskReady ? '已启用' : '待设置';
  const emailOk = state.email_status.includes('已授权');
  $('#email-dot').className = `status-dot ${emailOk ? 'good' : ''}`;
  $('#email-brief').textContent = emailOk ? '自动收取并生成拟回复' : '等待第三方客户端安全密码';
  $('#email-state').textContent = emailOk ? '已授权' : '待授权';
}

function renderTasks() {
  const items = state.tasks.filter(active);
  $('#task-list').innerHTML = items.length ? items.map(item => `<article class="item-card"><div class="item-main"><div class="item-title"><h3>${esc(item.title)}</h3><span class="badge ${item.status === 'overdue' ? 'red' : ''}">${esc(item.priority)}</span><span class="badge gray">${esc(item.status)}</span></div><div class="item-meta"><span>提醒 ${fmt(item.next_action_at || item.due_at)}</span><span>编号 ${item.code}</span></div></div><div class="item-actions"><button class="small-button" data-task-complete="${item.id}">完成</button><button class="small-button" data-task-delay="${item.id}">延期</button><button class="small-button delete" data-task-delete="${item.id}">删除</button></div></article>`).join('') : '<div class="empty">还没有待办。点击“新增待办”开始记录。</div>';
}

function renderFollowups() {
  const items = state.followups.filter(active);
  const count = method => items.filter(item => (item.metadata.followup_method || 'dingtalk_approval') === method).length;
  $('#fu-active').textContent = items.length;
  $('#fu-auto').textContent = count('dingtalk_auto');
  $('#fu-approval').textContent = count('dingtalk_approval');
  $('#fu-remind').textContent = count('remind_me');
  $('#followup-list').innerHTML = items.length ? items.map(item => `<article class="item-card"><div class="item-main"><div class="item-title"><h3>${esc(item.title)}</h3><span class="badge">${esc(methodName(item.metadata.followup_method))}</span><span class="badge gray">${esc(item.status)}</span></div><p class="item-desc">期望结果：${esc(item.target_answer || '未单独设置')}</p>${item.metadata.custom_rules ? `<p class="item-desc"><b>补充规则：</b>${esc(item.metadata.custom_rules)}</p>` : ''}<div class="item-meta"><span>对象 ${esc(item.owner_name)}</span><span>下次 ${fmt(item.next_action_at)}</span><span>${esc(period(item.metadata.repeat_minutes))}</span><span>聊天归档 ${Number(item.chat_count || 0)} 条</span><span>编号 ${item.code}</span></div><p class="item-desc"><b>任务档案：</b>${esc(item.document_path || '尚未生成')}</p></div><div class="item-actions"><button class="small-button" data-followup-edit="${item.id}">编辑</button><button class="small-button" data-followup-close="${item.id}">结束</button><button class="small-button delete" data-followup-delete="${item.id}">删除</button></div></article>`).join('') : '<div class="empty">暂无进行中的单项跟进。</div>';
}

function renderProjects() {
  const items = state.projects.filter(active);
  $('#project-list').innerHTML = items.length ? items.map(project => `<article class="item-card"><div class="item-main"><div class="item-title"><h3>${esc(project.title)}</h3><span class="badge">${esc(project.approval_state === 'approved' ? '已批准' : '待批准')}</span><span class="badge gray">${esc(project.status)}</span></div><div class="item-meta"><span>${project.nodes.length} 个节点</span><span>截止 ${fmt(project.due_at)}</span><span>编号 ${project.code}</span></div><ul class="node-list">${project.nodes.map(node => `<li><span>${esc(node.title)}</span><span>${esc(node.owner_name)}</span><span>${fmt(node.due_at)}</span><span>${esc(node.status)}</span></li>`).join('')}</ul></div><div class="item-actions">${project.approval_state !== 'approved' ? `<button class="small-button" data-project-approve="${project.id}">批准并启动</button>` : ''}</div></article>`).join('') : '<div class="empty">还没有项目计划。</div>';
}

function renderEmails() {
  const items = state.emails.filter(active);
  $('#email-banner').textContent = state.email_status;
  $('#email-list').innerHTML = items.length ? items.map(item => `<article class="item-card"><div class="item-main"><div class="item-title"><h3>${esc(item.title)}</h3><span class="badge">待审批</span></div><div class="item-meta"><span>发件人 ${esc(item.owner_name)}</span><span>编号 ${item.code}</span></div><p class="item-desc">${esc((item.description || '').slice(0, 280))}</p><p class="item-desc"><b>拟回复：</b>${esc(item.metadata.draft_reply || '尚未形成拟回复')}</p></div><div class="item-actions"><button class="small-button" data-email-send="${item.id}">审批发送</button><button class="small-button delete" data-email-cancel="${item.id}">取消</button></div></article>`).join('') : '<div class="empty">当前没有待处理邮件。</div>';
}

function renderWhitelist() {
  const items = state.whitelist || [];
  $('#whitelist-list').innerHTML = items.length ? items.map(item => {
    const access = (item.knowledge_access_events || []).slice(0, 3).map(event => `<li>${esc(event.category || '未分类')} · ${esc(event.source || '无来源')} · ${fmt(event.created_at)}</li>`).join('') || '<li>尚无知识使用记录</li>';
    const changes = (item.permission_events || []).slice(0, 3).map(event => `<li>${esc(event.event_type)} · ${fmt(event.created_at)}</li>`).join('') || '<li>尚无权限变更记录</li>';
    return `<article class="item-card"><div class="item-main"><div class="item-title"><h3>${esc(item.name)}</h3><label class="inline-switch" title="开启后，你人工回复该联系人后的120秒内，助理不会抢答"><input type="checkbox" data-whitelist-guard="${item.id}" ${item.human_reply_guard_enabled ? 'checked' : ''}><span>120秒保护</span></label><span class="badge ${item.enabled ? '' : 'gray'}">${item.enabled ? '自动回复已启用' : '已停用'}</span><span class="badge gray">${esc(state.permission_catalog?.roles?.[item.permission_role] || '普通同事')}</span></div><p class="item-desc">${esc(item.notes || '暂无备注')}</p><p class="permission-summary">${esc(item.permission_summary || '')}</p>${item.custom_reply_rules ? `<p class="item-desc"><b>补充规则：</b>${esc(item.custom_reply_rules)}</p>` : ''}<details class="permission-audit"><summary>查看权限与知识使用记录</summary><div class="audit-grid"><div><b>最近授权变更</b><ul>${changes}</ul></div><div><b>最近使用知识</b><ul>${access}</ul></div></div></details><div class="item-meta"><span>userId ${esc(item.user_id || '未设置')}</span><span>openDingTalkId ${esc(item.open_id || '未设置')}</span></div></div><div class="item-actions"><button class="small-button" data-whitelist-simulate="${item.id}">模拟提问</button><button class="small-button" data-whitelist-edit="${item.id}">编辑权限</button><button class="small-button delete" data-whitelist-delete="${item.id}">移除</button></div></article>`;
  }).join('') : '<div class="empty">白名单为空。添加后，助理可自动回复该联系人的普通问题。</div>';
}

function knowledgeScopeOptions(type) {
  const data = state.knowledge_permissions || {};
  if (type === 'project') return (data.projects || []).map(value => [value, value]);
  if (type === 'folder') return (data.folders || []).map(value => [value, value]);
  if (type === 'category') return Object.entries(data.categories || {}).map(([value, label]) => [value, label]);
  return [['', '全部资料']];
}

function refreshKnowledgeScopeOptions() {
  const form = $('#knowledge-permission-form'), type = form.elements.scope_type.value;
  const select = form.elements.scope_value, options = knowledgeScopeOptions(type);
  select.disabled = type === 'all';
  select.innerHTML = options.map(([value, label]) => `<option value="${esc(value)}">${esc(label)}</option>`).join('');
}

function renderKnowledgePermissions() {
  const data = state.knowledge_permissions || {counts: {}, documents: [], events: []};
  $('#knowledge-total').textContent = data.total || 0;
  $('#knowledge-internal').textContent = data.counts?.internal_shareable || 0;
  $('#knowledge-private').textContent = data.counts?.private || 0;
  refreshKnowledgeScopeOptions();
  const query = ($('#knowledge-library-filter')?.value || '').trim().toLowerCase();
  const documents = (data.documents || []).filter(item => !query || [
    item.title, item.path, item.folder, item.category_label, ...(item.projects || []),
  ].join(' ').toLowerCase().includes(query));
  $('#knowledge-document-list').innerHTML = documents.length ? documents.map(item => `<article class="knowledge-document-row"><div><h4>${esc(item.title)}</h4><p>${esc(item.path)}</p><small>${esc(item.category_label)} · ${esc((item.projects || []).join('、') || '未识别项目')}</small></div><div class="knowledge-document-actions"><span class="badge ${item.visibility === 'private' ? 'red' : ''}">${esc(item.visibility_label)}</span><button class="small-button" data-knowledge-visibility="${item.id}" data-current-visibility="${item.visibility}">${item.visibility === 'private' ? '改为内部公开' : '改为仅本人'}</button></div></article>`).join('') : '<div class="empty">没有符合条件的知识资料。</div>';
  $('#knowledge-permission-events').innerHTML = (data.events || []).length ? (data.events || []).map(event => `<div class="permission-event-row"><b>${esc(event.target_visibility === 'internal_shareable' ? '内部公开' : '仅本人')}</b><span>${esc(event.scope_type)} · ${esc(event.scope_value || '全部')}</span><span>${event.affected_count}份资料</span><small>${fmt(event.created_at)}</small></div>`).join('') : '<div class="empty">暂无权限变更记录。</div>';
}

const listValues = value => String(value || '').split(/[,，、;；\n]/).map(item => item.trim()).filter(Boolean);
function permissionFormPayload(form) {
  return {
    permission_role: form.get('permission_role'),
    allow_private_knowledge: form.get('allow_private_knowledge') === 'true',
    allowed_projects: listValues(form.get('allowed_projects')).map(value => value.toUpperCase()),
    allowed_categories: form.getAll('allowed_categories'),
    denied_categories: form.getAll('denied_categories'),
    custom_reply_rules: form.get('custom_reply_rules'),
  };
}
function updatePermissionPreview() {
  const formElement = $('#whitelist-form'), form = new FormData(formElement), payload = permissionFormPayload(form);
  const roles = state?.permission_catalog?.roles || {}, categories = state?.permission_catalog?.categories || {};
  const categoryText = payload.allowed_categories.length ? payload.allowed_categories.map(value => categories[value] || value).join('、') : '未授权任何资料类别';
  const projectText = payload.allowed_projects.join('、') || '未指定项目';
  const deniedText = payload.denied_categories.map(value => categories[value] || value).join('、') || '无';
  $('#permission-preview').textContent = `${roles[payload.permission_role] || '自定义'}｜${payload.allow_private_knowledge ? '允许读取已明确授权的私有资料' : '仅使用内部可共享资料'}｜类别：${categoryText}｜项目：${projectText}｜禁止：${deniedText}`;
}

const capabilityLabel = {
  receive_realtime: '实时接收消息', fetch_history: '读取历史消息', reply_to_message: '指定回复消息',
  send_as_user: '以本人身份发送', send_as_bot: '以应用/机器人身份发送', supports_ai_label: 'AI 标识设置', group_mentions: '群聊 @ 识别'
};

function renderChannels() {
  const bindings = state.channels || [];
  $('#channel-list').innerHTML = (state.channel_catalog || []).map(meta => {
    const item = bindings.find(value => value.channel_type === meta.channel_type);
    const connected = item?.status === 'connected';
    const capabilities = item?.capabilities || meta.capabilities;
    const shown = Object.entries(capabilities).filter(([key]) => capabilityLabel[key]).map(([key, enabled]) => `<li class="${enabled ? '' : 'off'}">${esc(capabilityLabel[key])}</li>`).join('');
    const identity = (item?.sending_identity || meta.sending_identity) === 'user' ? '本人身份' : '应用/机器人身份';
    return `<article class="channel-card ${connected ? 'connected' : ''}"><div class="channel-head"><div class="channel-name"><span class="channel-logo">${esc(meta.display_name.slice(0, 1))}</span><div><h3>${esc(meta.display_name)}</h3><div class="channel-sub">${connected ? '已连接' : '尚未绑定'} · ${identity}</div></div></div><span class="badge ${connected ? '' : 'gray'}">${connected ? '连接正常' : '未连接'}</span></div><ul class="capability-list">${shown}</ul>${item?.last_error ? `<div class="channel-warning">${esc(item.last_error)}</div>` : ''}<div class="channel-actions">${item ? `<button class="small-button" data-channel-test="${item.id}">检测连接</button><button class="small-button delete" data-channel-unbind="${item.id}">解除绑定</button>` : `<button class="primary" data-channel-bind="${meta.channel_type}">绑定${esc(meta.display_name)}</button>`}</div></article>`;
  }).join('');
}

function renderSystem() {
  const channelGood = (state.channels || []).some(item => item.status === 'connected');
  const profile = state.profile || {};
  $('#side-health').className = 'good';
  $('#side-health-text').textContent = '管理台运行正常';
  $('#workspace-label').textContent = `${profile.owner_name || '我的'} · ${profile.workspace_name || '个人助理'}`;
  $('#system-status').innerHTML = `<div><i class="status-dot ${channelGood ? 'good' : ''}"></i><span><b>消息托管适配器</b><small>钉钉 / 企业微信 / 飞书</small></span><em>${channelGood ? '运行中' : '待连接'}</em></div><div><i class="status-dot good"></i><span><b>管理台</b><small>仅本机可访问</small></span><em>运行中</em></div><div><i class="status-dot ${state.email_status.includes('已授权') ? 'good' : ''}"></i><span><b>企业邮箱</b><small>IMAP / SMTP SSL</small></span><em>${state.email_status.includes('已授权') ? '已授权' : '待授权'}</em></div>`;
  $('#system-settings-form').elements.dingtalk_ai_tag.value = String(Boolean(state.settings?.dingtalk_ai_tag));
  const form = $('#profile-form');
  form.elements.owner_name.value = profile.owner_name || '';
  form.elements.workspace_name.value = profile.workspace_name || '个人助理';
  form.elements.timezone.value = profile.timezone || 'Asia/Shanghai';
  form.elements.daily_digest_time.value = profile.daily_digest_time || '20:00';
  let note = $('#profile-setup-note');
  if (!profile.setup_completed) {
    if (!note) {
      note = document.createElement('div');
      note.id = 'profile-setup-note';
      note.className = 'setup-note';
      form.prepend(note);
    }
    note.textContent = '尚未完成初始化，请确认下面的基础信息。';
  } else if (note) note.remove();
}

function render() {
  renderOverview(); renderTasks(); renderFollowups(); renderProjects(); renderEmails();
  renderKnowledgePermissions(); renderWhitelist(); renderChannels(); renderSystem();
  $('#updated-at').textContent = `更新于 ${new Date(state.generated_at).toLocaleTimeString('zh-CN', {hour: '2-digit', minute: '2-digit'})}`;
}

async function load() {
  try { state = await api('/api/snapshot'); render(); }
  catch (error) { toast(error.message, true); $('#side-health-text').textContent = '无法连接管理台'; }
}

async function action(payload) {
  try {
    const result = await api('/api/action', {method: 'POST', body: JSON.stringify(payload)});
    toast(result.message); await load(); return true;
  } catch (error) { toast(error.message, true); return false; }
}

$('#refresh').onclick = load;
setInterval(load, 30000);
function openDialog(id) { $(id).showModal(); }
$$('.dialog-close').forEach(button => button.onclick = () => button.closest('dialog').close());

$('#add-task').onclick = () => openDialog('#task-dialog');
$('#task-form').onsubmit = async event => {
  event.preventDefault(); const form = new FormData(event.target);
  if (await action({action: 'task-create', text: `${form.get('schedule')} ${form.get('priority')} ${form.get('title')}`})) { event.target.reset(); $('#task-dialog').close(); }
};

$('#add-followup').onclick = () => {
  const form = $('#followup-form'); form.reset(); form.elements.id.value = ''; form.elements.owner_name.disabled = false;
  form.elements.schedule.required = true; $('#followup-dialog-title').textContent = '新增单项跟进'; openDialog('#followup-dialog');
};
$('#followup-form').onsubmit = async event => {
  event.preventDefault(); const form = new FormData(event.target), id = form.get('id');
  const payload = {action: id ? 'followup-update-structured' : 'followup-create-structured', id, title: form.get('title'), owner_name: form.get('owner_name'), target_answer: form.get('target_answer'), schedule: form.get('schedule'), followup_method: form.get('followup_method'), repeat_value: Number(form.get('repeat_value')), repeat_unit: form.get('repeat_unit'), reminder_text: form.get('reminder_text'), custom_rules: form.get('custom_rules')};
  if (await action(payload)) $('#followup-dialog').close();
};

$('#add-project').onclick = () => openDialog('#project-dialog');
$('#project-form').onsubmit = async event => { event.preventDefault(); const form = new FormData(event.target); if (await action({action: 'project-create', text: form.get('plan')})) { event.target.reset(); $('#project-dialog').close(); } };
$('#add-whitelist').onclick = () => { const form = $('#whitelist-form'); form.reset(); form.elements.id.value = ''; form.elements.enabled.value = 'true'; form.elements.permission_role.value = 'colleague'; form.elements.allow_private_knowledge.value = 'false'; $('#whitelist-dialog-title').textContent = '添加白名单联系人'; updatePermissionPreview(); openDialog('#whitelist-dialog'); };
$('#whitelist-form').onsubmit = async event => { event.preventDefault(); const form = new FormData(event.target), id = form.get('id'); const payload = {action: id ? 'whitelist-update' : 'whitelist-create', id, name: form.get('name'), user_id: form.get('user_id'), open_id: form.get('open_id'), notes: form.get('notes'), enabled: form.get('enabled') === 'true', ...permissionFormPayload(form)}; if (await action(payload)) $('#whitelist-dialog').close(); };
$('#system-settings-form').onsubmit = async event => { event.preventDefault(); const form = new FormData(event.target); await action({action: 'settings-update', dingtalk_ai_tag: form.get('dingtalk_ai_tag') === 'true'}); };
$('#knowledge-permission-form').elements.scope_type.onchange = refreshKnowledgeScopeOptions;
$('#knowledge-permission-form').onsubmit = async event => {
  event.preventDefault(); const form = new FormData(event.target);
  const type = form.get('scope_type'), value = type === 'all' ? '' : form.get('scope_value');
  const label = form.elements.visibility.options[form.elements.visibility.selectedIndex].text;
  if (confirm(`确认把所选范围的资料设置为“${label}”？系统会立即重建索引。`)) {
    await action({action: 'knowledge-permission-bulk', scope_type: type, scope_value: value, visibility: form.get('visibility')});
  }
};
$('#knowledge-library-filter').oninput = renderKnowledgePermissions;
$('#profile-form').onsubmit = async event => { event.preventDefault(); const form = new FormData(event.target); await action({action: 'instance-initialize', owner_name: form.get('owner_name'), workspace_name: form.get('workspace_name'), timezone: form.get('timezone'), daily_digest_time: form.get('daily_digest_time')}); };

function openChannelDialog(type) {
  const meta = state.channel_catalog.find(item => item.channel_type === type), form = $('#channel-form'), local = type === 'dingtalk';
  form.reset(); form.elements.channel_type.value = type; $('#channel-dialog-title').textContent = `绑定${meta.display_name}`;
  $('#channel-help').textContent = local ? '将登记并检查当前电脑上正在运行的钉钉实时连接，不需要填写账号密钥。' : type === 'wecom' ? '填写企业 ID（CorpID）和自建应用 Secret。验证成功后仍以企业应用身份工作。' : '填写企业自建应用的 App ID 和 App Secret。验证成功后仍以应用机器人身份工作。';
  $('#channel-account-row').style.display = local ? 'none' : 'grid'; $('#channel-secret-row').style.display = local ? 'none' : 'grid';
  form.elements.account_id.required = !local; form.elements.secret.required = !local; openDialog('#channel-dialog');
}
$('#channel-form').onsubmit = async event => { event.preventDefault(); const form = new FormData(event.target); if (await action({action: 'channel-bind', channel_type: form.get('channel_type'), account_id: form.get('account_id'), secret: form.get('secret')})) $('#channel-dialog').close(); };

document.addEventListener('change', async event => {
  const input = event.target.closest('input[data-whitelist-guard]'); if (!input) return;
  input.disabled = true; const ok = await action({action: 'whitelist-update', id: input.dataset.whitelistGuard, human_reply_guard_enabled: input.checked});
  if (!ok) { input.checked = !input.checked; input.disabled = false; }
});

document.addEventListener('click', async event => {
  const button = event.target.closest('button'); if (!button) return;
  if (button.dataset.whitelistEdit) { const item = state.whitelist.find(value => value.id === button.dataset.whitelistEdit), form = $('#whitelist-form'); form.reset(); form.elements.id.value = item.id; form.elements.name.value = item.name; form.elements.user_id.value = item.user_id || ''; form.elements.open_id.value = item.open_id || ''; form.elements.notes.value = item.notes || ''; form.elements.enabled.value = String(item.enabled); form.elements.permission_role.value = item.permission_role || 'colleague'; form.elements.allow_private_knowledge.value = String(Boolean(item.allow_private_knowledge)); form.elements.allowed_projects.value = (item.allowed_projects || []).join('、'); $$('input[name="allowed_categories"]', form).forEach(input => input.checked = (item.allowed_categories || []).includes(input.value)); $$('input[name="denied_categories"]', form).forEach(input => input.checked = (item.denied_categories || []).includes(input.value)); form.elements.custom_reply_rules.value = item.custom_reply_rules || ''; $('#whitelist-dialog-title').textContent = '编辑联系人权限'; updatePermissionPreview(); openDialog('#whitelist-dialog'); }
  if (button.dataset.whitelistDelete && confirm('确认将该联系人移出白名单？之后其消息只会记录，不会拟回复或送审批。')) await action({action: 'whitelist-delete', id: button.dataset.whitelistDelete});
  if (button.dataset.whitelistSimulate) { const question = prompt('输入要模拟的问题：', 'Q05项目排期发我看看'); if (question) { try { const result = await api('/api/action', {method: 'POST', body: JSON.stringify({action: 'whitelist-permission-simulate', id: button.dataset.whitelistSimulate, query: question})}); alert(result.message); await load(); } catch (error) { toast(error.message, true); } } }
  if (button.dataset.knowledgeVisibility) { const target = button.dataset.currentVisibility === 'private' ? 'internal_shareable' : 'private'; const label = target === 'internal_shareable' ? '内部公开' : '仅本人'; if (confirm(`确认将这份资料设置为“${label}”？`)) await action({action: 'knowledge-permission-bulk', scope_type: 'document', scope_value: button.dataset.knowledgeVisibility, visibility: target}); }
  if (button.dataset.channelBind) openChannelDialog(button.dataset.channelBind);
  if (button.dataset.channelTest) await action({action: 'channel-test', id: button.dataset.channelTest});
  if (button.dataset.channelUnbind && confirm('解除绑定后，助理将删除本机保存的该渠道密钥。确认继续？')) await action({action: 'channel-unbind', id: button.dataset.channelUnbind});
  if (button.dataset.taskComplete) await action({action: 'task-complete', text: button.dataset.taskComplete});
  if (button.dataset.taskDelay) { const value = prompt('延期到什么时候？例如：明天下午3点'); if (value) await action({action: 'task-delay', text: `${value} ${button.dataset.taskDelay}`}); }
  if (button.dataset.taskDelete && confirm('删除这条待办？审计记录仍会保留。')) await action({action: 'task-delete', id: button.dataset.taskDelete});
  if (button.dataset.followupEdit) { const item = state.followups.find(value => value.id === button.dataset.followupEdit), form = $('#followup-form'); form.reset(); form.elements.id.value = item.id; form.elements.title.value = item.title; form.elements.owner_name.value = item.owner_name; form.elements.owner_name.disabled = true; form.elements.target_answer.value = item.target_answer || ''; form.elements.schedule.value = ''; form.elements.schedule.required = false; form.elements.followup_method.value = item.metadata.followup_method || 'dingtalk_approval'; const minutes = Number(item.metadata.repeat_minutes || 0); let unit = 'minutes', value = minutes; if (minutes && minutes % 10080 === 0) { unit = 'weeks'; value = minutes / 10080; } else if (minutes && minutes % 1440 === 0) { unit = 'days'; value = minutes / 1440; } else if (minutes && minutes % 60 === 0) { unit = 'hours'; value = minutes / 60; } form.elements.repeat_value.value = value; form.elements.repeat_unit.value = unit; form.elements.reminder_text.value = item.metadata.reminder_text || ''; form.elements.custom_rules.value = item.metadata.custom_rules || ''; $('#followup-dialog-title').textContent = '编辑单项跟进'; openDialog('#followup-dialog'); }
  if (button.dataset.followupClose && confirm('确认结束这项跟进？')) await action({action: 'followup-close', text: button.dataset.followupClose});
  if (button.dataset.followupDelete && confirm('删除这项跟进？任务会停止，审计记录仍会保留。')) await action({action: 'followup-delete', id: button.dataset.followupDelete});
  if (button.dataset.projectApprove && confirm('批准后，计划内节点将按设定时间自动推进。确认批准？')) await action({action: 'project-approve', text: button.dataset.projectApprove});
  if (button.dataset.emailSend) { const item = state.emails.find(value => value.id === button.dataset.emailSend), replacement = prompt('确认邮件正文；可修改后发送：', item.metadata.draft_reply || ''); if (replacement !== null && confirm(`确认发送给 ${item.metadata.reply_to}？`)) await action({action: 'email-send', text: `${item.id} ${replacement}`}); }
  if (button.dataset.emailCancel && confirm('取消这封邮件的待回复任务？')) await action({action: 'email-cancel', text: button.dataset.emailCancel});
});

async function searchKnowledge() {
  const query = $('#knowledge-query').value.trim(); if (!query) return;
  try { const result = await api(`/api/knowledge?q=${encodeURIComponent(query)}`); $('#knowledge-results').innerHTML = result.results.length ? result.results.map(item => `<article class="knowledge-card"><h3>${esc(item.title)}${item.heading ? ` · ${esc(item.heading)}` : ''}</h3><p>${esc(item.snippet)}</p><small>来源：${esc(item.provenance || item.source)} · 更新 ${fmt(item.updated_at)}</small></article>`).join('') : '<div class="empty">没有找到相关的已确认知识。</div>'; }
  catch (error) { toast(error.message, true); }
}

$('#knowledge-search').onclick = searchKnowledge;
$('#knowledge-query').onkeydown = event => { if (event.key === 'Enter') searchKnowledge(); };
$('#whitelist-form').addEventListener('input', updatePermissionPreview);
$('#whitelist-form').addEventListener('change', event => {
  const input = event.target;
  if (input.matches('input[name="allowed_categories"], input[name="denied_categories"]') && input.checked) {
    const opposite = input.name === 'allowed_categories' ? 'denied_categories' : 'allowed_categories';
    const conflicting = $(`input[name="${opposite}"][value="${input.value}"]`, $('#whitelist-form'));
    if (conflicting) conflicting.checked = false;
  }
  updatePermissionPreview();
});
load().then(() => {
  const requested = location.hash.slice(1);
  if ($(`#view-${requested}`)) showView(requested);
});
