'use strict';
'require rpc';
'require ui';

/* ============================================================
 * campnet 三页共用的东西：RPC 声明、状态徽标、错误态、模态、轮询。
 *
 * 这里**不用 form.Map / form.GridSection**。原因不是"Luci 不好"，而是
 * 本插件的数据模型和 CBI 不匹配：账号↔线路是引用关系（要级联删）、
 * 凭据存在 uci 之外、设备名由 section id 派生。硬套 CBI 的结果是
 * 「一页三种编辑范式」，以及两个实测出来的硬伤：
 *   1) 视图把 handleSave/handleSaveApply/handleReset 全设为 null 时，
 *      luci.js 的 addFooter() 判定 `if (handleSaveApply || handleSave || handleReset)`
 *      不成立 —— 整个 cbi-page-actions 不渲染，页面就没有提交入口；
 *   2) 非匿名 GridSection 的"添加"按钮要靠名字框有内容才由校验器点亮，
 *      且 handleAdd 恒走 renderMoreOptionsModal，而 cloneOptions 只克隆
 *      modalonly 字段 —— 没有 modalonly 字段的表，点添加会弹出**空弹窗**。
 * 自定义视图里这两个机制都不存在。
 *
 * 但 uci 那一套语义要保留：配置读写走 uci.js，提交走视图基类默认的
 * handleSaveApply（它会调 ui.changes.apply()），于是
 * "未保存的更改"角标与 diff 弹窗、带 rollback 的 apply 流程全自动生效。
 * ============================================================ */

/* ---------- RPC ----------
 * params 一律用**数组**（位置传参）。写成对象会让服务端收到嵌套对象，
 * jshn 对 object 返回的是类型标记 J_T1 而不是内容 —— 症状是
 * "什么都没报错，但功能全不生效"。后端 luci.campnet 里的 _bad_param
 * 也会拦截同一种误用并回一个可读原因。 */
var getStatus = rpc.declare({ object: 'luci.campnet', method: 'getStatus' });

var getLog = rpc.declare({
	object: 'luci.campnet', method: 'getLog',
	params: [ 'lines', 'level', 'line' ]
});

var setSecret = rpc.declare({
	object: 'luci.campnet', method: 'setSecret',
	params: [ 'account', 'username', 'password' ]
});

var deleteSecret = rpc.declare({
	object: 'luci.campnet', method: 'deleteSecret',
	params: [ 'account' ]
});

var checkUpdate = rpc.declare({
	object: 'luci.campnet', method: 'checkUpdate',
	params: [ 'refresh' ]
});

/* ---------- 状态徽标 ----------
 * 自绘，不用 `.label label-success`：Argon 只定义了 .label.warning 与
 * 暗色模式的 .label.success，**没有** .label.danger / .label.info ——
 * 这两个状态会落回 .label 的默认灰 #bfbfbf，等于"用颜色表状态"根本没生效。
 *
 * 取色一律用主题自己的 CSS 变量，不写死 hex：Argon 在 dark.css 里覆盖了
 * --oc-neutral 等，写死颜色会让暗色模式下的对比度失控。填充按 Argon 自身
 * --oc-accent-strong 的惯例用 color-mix 压暗，保证白字在两种主题下都够读；
 * 不支持 color-mix 时退回第一段的纯色。
 * 文本标签始终在，颜色只是辅助 —— 不靠颜色单独表意。 */
var STATUS = {
	authenticated: { text: _('已认证'), v: '--success',    fb: '#16a34a' },
	authing:       { text: _('认证中'), v: '--info',       fb: '#0284c7' },
	need_auth:     { text: _('需认证'), v: '--warning',    fb: '#ea580c' },
	no_ip:         { text: _('无 IP'),  v: '--oc-neutral', fb: '#64748b' },
	offline:       { text: _('离线'),   v: '--oc-neutral', fb: '#64748b' },
	error:         { text: _('错误'),   v: '--danger',     fb: '#dc2626' },
	unknown:       { text: _('未知'),   v: '--oc-neutral', fb: '#94a3b8' }
};

function badgeCss() {
	var out = [ '.campnet-badge{display:inline-block;padding:1px 8px;border-radius:10px;' +
		'font-size:12px;line-height:18px;color:#fff;white-space:nowrap}' ];
	Object.keys(STATUS).forEach(function (k) {
		var s = STATUS[k];
		out.push('.campnet-badge[data-st="' + k + '"]{background:' + s.fb + '}');
		/* color-mix 是 Argon 自己在 cascade.css 里就大量使用的特性；
		 * 78% 这个比例也是照抄它的 --oc-accent-strong。 */
		out.push('@supports (background:color-mix(in srgb,red,black)){' +
			'.campnet-badge[data-st="' + k + '"]{background:color-mix(in srgb,var(' +
			s.v + ',' + s.fb + ') 78%,black)}}');
	});
	return out.join('');
}

/* <status> 未知时落到 unknown，同时保留原始值供排查 */
function badge(status, title) {
	var key = STATUS[status] ? status : 'unknown';
	return E('span', {
		'class': 'campnet-badge',
		'data-st': key,
		'title': title || null
	}, [ STATUS[key].text ]);
}

function statusText(status) {
	return (STATUS[status] || STATUS.unknown).text;
}

/* ---------- 时间锚点 ----------
 * 一律用客户端时间：服务端时钟可能没同步，而且这只回答
 * "我看到的数据是几秒前的"，不需要绝对时间。 */
function clockText() {
	var d = new Date(), p = function (n) { return (n < 10 ? '0' : '') + n; };
	return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

/* ---------- 错误态 ----------
 * 网络类失败对这个插件是常态而不是异常（它要跟校园网门户打交道），
 * 所以失败时必须给出出路，而不是"一段错误文字，页面到此为止"。 */
function errorCard(msg, onRetry) {
	var btn = E('button', { 'class': 'cbi-button cbi-button-action' }, [ _('重试') ]);
	btn.addEventListener('click', function (ev) {
		ev.preventDefault();
		if (typeof onRetry === 'function') onRetry();
		else window.location.reload();
	});

	return E('div', { 'class': 'cbi-section' }, [
		E('div', { 'class': 'alert-message error' }, [
			E('strong', {}, [ _('读取失败：') + msg ])
		]),
		E('div', { 'class': 'cbi-section-descr' }, [
			_('常见原因：rpcd 未运行、当前用户缺少 luci-app-campnet 的 ACL 权限，或服务正在重启。'),
			E('br'),
			_('可在路由器上执行 '),
			E('code', {}, [ '/etc/init.d/rpcd restart' ]),
			_(' 后再重试。')
		]),
		E('div', {}, [ btn ])
	]);
}

/* ---------- 模态 ----------
 * 统一"破坏性/中断性操作走模态确认"的语言，不用 window.confirm
 * （不可样式化、不可翻译）。 */
function confirm(title, lines, okText, danger, onOk) {
	var ok = E('button', {
		'class': 'cbi-button ' + (danger ? 'cbi-button-negative' : 'cbi-button-positive important')
	}, [ okText || _('确定') ]);

	ok.addEventListener('click', function (ev) {
		ev.preventDefault();
		ok.disabled = true;
		var orig = ok.textContent;
		ok.textContent = _('处理中…');
		Promise.resolve().then(onOk).then(function () {
			ui.hideModal();
		}).catch(function (e) {
			ok.disabled = false;
			ok.textContent = orig;
			ui.addNotification(null, E('p', {}, [ _('操作失败：') + (e && e.message || e) ]), 'error');
		});
	});

	ui.showModal(title, [
		E('div', {}, lines),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('取消') ]),
			' ',
			ok
		])
	]);
}

/* 表单式模态：rows = [{label, descr, node}]
 * onSubmit 返回 false 表示"校验没过，别关窗"。 */
function formModal(title, rows, okText, onSubmit) {
	var body = E('div', { 'class': 'cbi-section' });
	rows.forEach(function (r) {
		body.appendChild(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ r.label ]),
			E('div', { 'class': 'cbi-value-field' }, [
				r.node,
				r.descr ? E('div', { 'class': 'cbi-value-description' }, [ r.descr ]) : ''
			])
		]));
	});

	var ok = E('button', { 'class': 'cbi-button cbi-button-positive important' },
		[ okText || _('确定') ]);
	ok.addEventListener('click', function (ev) {
		ev.preventDefault();
		ok.disabled = true;
		var orig = ok.textContent;
		ok.textContent = _('处理中…');
		Promise.resolve().then(onSubmit).then(function (r) {
			if (r === false) {
				ok.disabled = false;
				ok.textContent = orig;
				return;
			}
			ui.hideModal();
		}).catch(function (e) {
			ok.disabled = false;
			ok.textContent = orig;
			ui.addNotification(null, E('p', {}, [ _('操作失败：') + (e && e.message || e) ]), 'error');
		});
	});

	ui.showModal(title, [
		body,
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('取消') ]),
			' ',
			ok
		])
	]);

	return ok;
}

/* ---------- 空状态 ----------
 * 空状态必须给出路：告诉用户去哪、并且能直接点过去。
 * 纯文本"请到「插件设置」页添加"等于让新用户自己摸索。 */
function emptyText(text, href, linkText) {
	var out = [ text ];
	if (href)
		out.push(' ', E('a', { 'href': href }, [ linkText || _('前往设置') ]));
	return E('em', {}, out);
}

function settingsUrl() {
	return L.url('admin/services/campnet/settings');
}

/* ---------- 轮询 ----------
 * LuCI 这个版本没有视图卸载钩子，所以不能用 setInterval：离开页面后
 * 定时器会一直跑。改成自调度 setTimeout，每一跳先确认根节点还在文档里，
 * 不在就自然停；后台标签页不请求。
 * <root> 传节点或"返回节点的函数"（节点可能是渲染后才挂上去的）。 */
function poll(fn, ms, root) {
	var timer = null;

	function alive() {
		var n = (typeof root === 'function') ? root() : root;
		return !!n && document.contains(n);
	}

	(function tick() {
		timer = window.setTimeout(function () {
			if (!alive())
				return;				/* 页面已切走 —— 停在这里，不再排下一跳 */
			if (!document.hidden)
				Promise.resolve().then(fn).catch(function () { /* 后台轮询失败不弹窗 */ });
			tick();
		}, ms);
	})();

	return function () { if (timer) window.clearTimeout(timer); };
}

return {
	getStatus: getStatus,
	getLog: getLog,
	setSecret: setSecret,
	deleteSecret: deleteSecret,
	checkUpdate: checkUpdate,

	STATUS: STATUS,
	badgeCss: badgeCss,
	badge: badge,
	statusText: statusText,
	clockText: clockText,

	errorCard: errorCard,
	confirm: confirm,
	formModal: formModal,
	emptyText: emptyText,
	settingsUrl: settingsUrl,
	poll: poll
};
