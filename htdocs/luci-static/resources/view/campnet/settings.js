'use strict';
'require form';
'require rpc';
'require view';
'require ui';

var getStatus = rpc.declare({ object: 'luci.campnet', method: 'getStatus' });
var setSecret = rpc.declare({
	object: 'luci.campnet', method: 'setSecret',
	params: [ 'account', 'username', 'password' ]
});
var checkUpdate = rpc.declare({
	object: 'luci.campnet', method: 'checkUpdate', params: [ 'refresh' ]
});

var LINE_LIMIT = 2;

return view.extend({
	load: function () {
		/* 不吞异常：失败要看得见，而不是渲染成"没有账号" */
		return getStatus().then(function (r) { return r || {}; })
			.catch(function (e) { return { error: (e && e.message) || String(e) }; });
	},

	render: function (st) {
		if (st.error)
			return E('div', { 'class': 'cbi-section alert-message error' },
				[ _('读取状态失败：') + st.error ]);

		var accounts = st.accounts || [];
		var lines = st.lines || [];
		var limit = st.line_limit || LINE_LIMIT;
		var m, s, o;

		m = new form.Map('campnet', _('校园网认证'),
			_('账号 = 身份（用谁上网）；线路 = 一条独立认证会话。'));

		/* ---------------- 账号 ---------------- */
		s = m.section(form.GridSection, 'account', _('账号'),
			_('账号名与线路名共用一个命名空间，不能重复。'));
		s.addremove = true;
		s.anonymous = false;

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.DummyValue, '_lines', _('线路数'));
		o.modalonly = false;
		o.textvalue = function (sid) {
			var n = 0;
			lines.forEach(function (l) { if (l.account === sid) n++; });
			var txt = '%d / %d'.format(n, limit);
			/* 达到上限直接写出来，别让用户加第三条才发现不行 */
			return (n >= limit) ? txt + ' ' + _('（已达上限）') : txt;
		};

		o = s.option(form.DummyValue, '_cred', _('帐密'));
		o.modalonly = false;
		o.textvalue = function (sid) {
			var a = null;
			accounts.forEach(function (x) { if (x.id === sid) a = x; });
			return (a && a.has_credential) ? _('已配置') : _('未配置');
		};

		/* ---------------- 线路 ---------------- */
		s = m.section(form.GridSection, 'line', _('线路'),
			_('一条线路 = 一次独立认证。同一账号最多 %d 条；多条线路要带宽叠加，metric 必须填同一个值。')
				.format(limit));
		s.addremove = true;
		s.anonymous = false;

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'account', _('归属账号'),
			_('这条线路用哪个账号上网（每个账号最多 %d 条，超出会被拒绝生效）。').format(limit));
		accounts.forEach(function (a) { o.value(a.id, a.id); });
		o.rmempty = true;

		o = s.option(form.ListValue, 'type', _('类型'));
		o.value('wan', _('wan — 复用现有接口'));
		o.value('macvlan', _('macvlan — 独立设备（多拨）'));
		o.default = 'macvlan';
		o.rmempty = false;

		o = s.option(form.Value, 'iface', _('网络接口'), _('类型为 wan 时生效。'));
		o.default = 'wan';
		o.depends('type', 'wan');
		o.modalonly = true;

		o = s.option(form.Value, 'macaddr', _('macvlan MAC'), _('留空自动生成并固化。'));
		o.depends('type', 'macvlan');
		o.modalonly = true;
		o.rmempty = true;

		o = s.option(form.Value, 'metric', _('mwan3 metric'),
			_('要带宽叠加，各线路必须填同一个值；不同值只做故障切换。'));
		o.datatype = 'uinteger';
		o.default = '10';
		o.depends('type', 'macvlan');
		o.modalonly = true;
		o.rmempty = true;

		o = s.option(form.Value, 'weight', _('mwan3 权重'), _('等 metric 时的流量配比。'));
		o.datatype = 'uinteger';
		o.default = '10';
		o.depends('type', 'macvlan');
		o.modalonly = true;
		o.rmempty = true;

		o = s.option(form.Value, 'route_metric', _('默认路由 metric'), _('须大于主 wan 的 0。'));
		o.datatype = 'uinteger';
		o.default = '20';
		o.depends('type', 'macvlan');
		o.modalonly = true;
		o.rmempty = true;

		/* ---------------- 基本 ---------------- */
		s = m.section(form.NamedSection, 'settings', _('基本'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用'), _('关闭后停止保活与线路编排。'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'gateway', _('认证网关'));
		o.default = '10.0.1.51';
		o.placeholder = '10.0.1.51';

		o = s.option(form.ListValue, 'auth_mode', _('认证模式'), _('不确定就保持 auto。'));
		o.value('auto', _('auto（自动探测）'));
		o.value('ruijie', _('ruijie — axe_bras'));
		o.value('eportal', _('eportal — 锐捷门户'));
		o.default = 'auto';

		/* datatype 用 range 而不是 uinteger：0 会让 keeper 忙循环
		 * （保活周期 0 = 不停探测）、重试间隔 0 = 无间隔连打三次
		 * （校园网很容易因此风控/锁号）。后端 uciqmin 还会再钳一次。 */
		o = s.option(form.Value, 'check_interval', _('保活周期'), _('秒。掉线后最长等这么久才发现。'));
		o.datatype = 'range(5,3600)';
		o.default = '60';

		o = s.option(form.Value, 'max_retry', _('重试次数'));
		o.datatype = 'range(1,10)';
		o.default = '3';

		o = s.option(form.Value, 'retry_delay', _('重试间隔'), _('秒。'));
		o.datatype = 'range(1,600)';
		o.default = '5';

		o = s.option(form.Flag, 'dial_on_start', _('开机自动编排'));
		o.default = '1';
		o.rmempty = false;

		/* ---------------- 高级（渐进披露：默认折叠） ---------------- */
		/* 同一个 uci section 只能有一个 NamedSection：原来拆成两节，
		 * 生成的 DOM id 会重复，depends 求值也依赖 id 唯一性。
		 * 折叠本来就是靠 depends 实现的，拆节纯属冗余。 */
		o = s.option(form.Flag, 'show_advanced', _('展开高级参数'),
			_('显示锐捷表单字段与超时设置。'));
		o.default = '0';
		o.rmempty = true;
		/* 这是纯 UI 偏好，存 localStorage 而不是 uci：
		 * 写 uci 会触发 servic reload，勾一下开关就把所有认证 keeper 重启一遍。 */
		o.cfgvalue = function (sid) {
			return window.localStorage.getItem('campnet.show_advanced') || '0';
		};
		o.write = function (sid, val) {
			window.localStorage.setItem('campnet.show_advanced', val);
			return Promise.resolve();
		};
		o.remove = function () {
			window.localStorage.setItem('campnet.show_advanced', '0');
			return Promise.resolve();
		};

		o = s.option(form.Value, 'track_ips', _('探测 IP'),
			_('空格分隔。用于 mwan3 线路健康检查与外网连通判定。'));
		o.default = '223.5.5.5 119.29.29.29';
		o.depends('show_advanced', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'probe_url', _('在线探针'));
		o.default = 'http://connect.rom.miui.com/generate_204';
		o.depends('show_advanced', '1');

		o = s.option(form.Value, 'uplink', _('上行基础设备'), _('auto = 取类型为 wan 的线路的接口。'));
		o.default = 'auto';
		o.depends('show_advanced', '1');

		o = s.option(form.Value, 'auth_host', _('认证域名'), _('留空 = 直接用网关 IP。'));
		o.placeholder = 'auth.example.edu.cn';
		o.depends('show_advanced', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'server_ip', _('认证服务器 IP'), _('配合认证域名绕过 DNS。'));
		o.depends('show_advanced', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'wlanacname', _('wlanacname'));
		o.default = 'BRAS';
		o.depends('show_advanced', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'pageid', _('pageid'));
		o.datatype = 'uinteger';
		o.default = '5';
		o.depends('show_advanced', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'templatetype', _('templatetype'));
		o.datatype = 'uinteger';
		o.default = '1';
		o.depends('show_advanced', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'vlan', _('vlan'));
		o.datatype = 'uinteger';
		o.default = '0';
		o.depends('show_advanced', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'auth_type', _('auth_type'));
		o.datatype = 'uinteger';
		o.default = '0';
		o.depends('show_advanced', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'poll_max', _('拨号轮询上限'));
		o.datatype = 'range(1,200)';
		o.default = '20';
		o.depends('show_advanced', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'poll_interval', _('拨询间隔'), _('秒。'));
		o.datatype = 'range(1,60)';
		o.default = '2';
		o.depends('show_advanced', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'curl_connect_timeout', _('连接超时'), _('秒。'));
		o.datatype = 'range(1,60)';
		o.default = '5';
		o.depends('show_advanced', '1');
		o.rmempty = true;

		o = s.option(form.Value, 'curl_timeout', _('请求超时'), _('秒。'));
		o.datatype = 'range(1,120)';
		o.default = '12';
		o.depends('show_advanced', '1');
		o.rmempty = true;

		return E('div', {}, [
			m.render(),
			renderSecretCard(accounts),
			renderVersionCard(st)
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});

/* ------------------------------------------------------------
 * 帐密：每个账号一行，不再用下拉选择。
 * 下拉的问题：隐藏了"有哪些账号"，也看不出谁配了谁没配。
 * 帐密存 /etc/campnet/.config（0600），不走 uci，所以单独一张卡片。
 * ---------------------------------------------------------- */
function renderSecretCard(accounts) {
	var rows = [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, [ _('账号') ]),
			E('th', { 'class': 'th' }, [ _('状态') ]),
			E('th', { 'class': 'th' }, [ _('用户名') ]),
			E('th', { 'class': 'th' }, [ _('密码') ]),
			E('th', { 'class': 'th cbi-section-actions' }, [])
		])
	];

	if (!accounts.length) {
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': '5' }, [
				E('em', {}, [ _('尚未配置账号 —— 请先在上面「账号」里添加。') ])
			])
		]));
	}

	accounts.forEach(function (a) {
		var userIn = E('input', {
			'class': 'cbi-input-text', 'type': 'text', 'autocomplete': 'off',
			'placeholder': _('学号 / 用户名')
		});
		var passIn = E('input', {
			'class': 'cbi-input-text', 'type': 'password', 'autocomplete': 'new-password',
			'placeholder': _('密码')
		});

		var btn = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ _('保存') ]);
		btn.addEventListener('click', function (ev) {
			ev.preventDefault();
			var user = userIn.value.trim();
			var pass = passIn.value;
			if (!user || !pass) {
				ui.addNotification(null, E('p', {}, [ _('用户名与密码都不能为空') ]), 'warning');
				return;
			}
			btn.disabled = true;
			btn.textContent = _('保存中…');
			setSecret(a.id, user, pass).then(function (r) {
				btn.disabled = false;
				btn.textContent = _('保存');
				if (r && r.ok !== false) {
					passIn.value = '';
					ui.addNotification(null, E('p', {}, [ _('账号 %s 的帐密已保存').format(a.id) ]), 'info');
				} else {
					ui.addNotification(null, E('p', {}, [ _('保存失败，详见「插件日志」页') ]), 'error');
				}
			}).catch(function (e) {
				btn.disabled = false;
				btn.textContent = _('保存');
				ui.addNotification(null, E('p', {}, [ _('调用失败：') + e ]), 'error');
			});
		});

		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, [
				a.id,
				a.enabled ? '' : E('span', { 'class': 'cbi-section-descr', 'style': 'margin-left:6px' },
					[ _('（已停用）') ])
			]),
			E('td', { 'class': 'td' }, [ a.has_credential ? _('已配置') : _('未配置') ]),
			E('td', { 'class': 'td' }, [ userIn ]),
			E('td', { 'class': 'td' }, [ passIn ]),
			E('td', { 'class': 'td cbi-section-actions' }, [ btn ])
		]));
	});

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ _('帐密') ]),
		E('div', { 'class': 'cbi-section-descr' },
			[ _('保存在 /etc/campnet/.config（0600），不写入 uci；保存后保活下一周期即生效。') ]),
		E('table', { 'class': 'table cbi-section-table' }, rows)
	]);
}

/* ------------------------------------------------------------
 * 版本与更新
 * ---------------------------------------------------------- */
function renderVersionCard(st) {
	var box = E('div', { 'class': 'cbi-section-descr' });

	var btn = E('button', { 'class': 'cbi-button cbi-button-action' }, [ _('检查更新') ]);
	btn.addEventListener('click', function (ev) {
		ev.preventDefault();
		btn.disabled = true;
		btn.textContent = _('检查中…');
		checkUpdate('--refresh').then(function (r) {
			btn.disabled = false;
			btn.textContent = _('检查更新');
			r = r || {};
			while (box.firstChild) box.removeChild(box.firstChild);
			if (!r.checked) {
				box.appendChild(E('span', {}, [
					_('暂时无法获取远端版本（检查网络，或仓库尚无 tag）。') + ' '
				]));
			} else if (!r.latest) {
				box.appendChild(E('span', {}, [
					_('已是最新版本（%s）。').format('v' + (r.version || '?')) + ' '
				]));
			} else {
				box.appendChild(E('span', {}, [
					_('发现新版本 %s').format(r.latest) + ' — ',
					E('a', { 'href': r.url || '#', 'target': '_blank', 'rel': 'noreferrer' },
						[ _('打开项目主页') ])
				]));
			}
		}).catch(function (e) {
			btn.disabled = false;
			btn.textContent = _('检查更新');
			while (box.firstChild) box.removeChild(box.firstChild);
			box.appendChild(E('span', {}, [ _('检查失败：') + e ]));
		});
	});

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ _('版本') ]),
		E('div', {}, [
			E('span', { 'style': 'margin-right:16px' }, [ E('strong', {}, [ 'v' + (st.version || '?') ]) ]),
			btn
		]),
		box,
		E('div', { 'class': 'cbi-section-descr' }, [
			E('a', {
				'href': 'https://github.com/RyanZhangK/luci-app-campnet',
				'target': '_blank', 'rel': 'noreferrer'
			}, [ _('项目主页') ])
		])
	]);
}
