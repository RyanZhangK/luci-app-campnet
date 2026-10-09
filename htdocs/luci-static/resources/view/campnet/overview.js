'use strict';
'require view';
'require rpc';
'require ui';

var getStatus = rpc.declare({ object: 'luci.campnet', method: 'getStatus' });
var authLine = rpc.declare({ object: 'luci.campnet', method: 'auth', params: [ 'line' ] });
var lineApply = rpc.declare({ object: 'luci.campnet', method: 'lineApply' });
var lineTeardown = rpc.declare({ object: 'luci.campnet', method: 'lineTeardown' });

/* 状态徽标自绘。
 * 注意：不要用 `label label-success` 这类 bootstrap 类 —— 本机主题是 Argon，
 * 它的 CSS 里**没有** .label-* 修饰类，所有徽标会变成同一种灰色，
 * 等于"用颜色表状态"这件事根本没生效。这里显式给底色 + 白字，
 * 在深浅两种主题下都成立。 */
var BADGE_CSS = '.campnet-badge{display:inline-block;padding:1px 8px;border-radius:10px;'
	+ 'font-size:12px;line-height:18px;color:#fff;white-space:nowrap}';

var STATUS = {
	authenticated: { text: _('已认证'), bg: '#16a34a' },
	authing:       { text: _('认证中'), bg: '#0284c7' },
	need_auth:     { text: _('需认证'), bg: '#ea580c' },
	no_ip:         { text: _('无 IP'),  bg: '#64748b' },
	offline:       { text: _('离线'),   bg: '#64748b' },
	error:         { text: _('错误'),   bg: '#dc2626' },
	unknown:       { text: _('未知'),   bg: '#94a3b8' }
};

function badge(st) {
	var s = STATUS[st] || STATUS.unknown;
	return E('span', { 'class': 'campnet-badge', 'style': 'background:%s'.format(s.bg) }, [ s.text ]);
}

/* 按钮：点击后进入加载态（改文案 + 禁用），而不是只变灰 ——
 * 状态可见性要求用户知道"我点的东西正在发生"。 */
function actionBtn(text, busyText, cls, fn) {
	var b = E('button', { 'class': 'cbi-button ' + cls }, [ text ]);
	b.addEventListener('click', function (ev) {
		ev.preventDefault();
		var orig = b.textContent;
		b.disabled = true;
		if (busyText) b.textContent = busyText;
		Promise.resolve().then(fn).then(function (r) {
			var ok = !r || r.ok !== false;
			ui.addNotification(null, E('p', {}, [
				ok ? _('操作已执行') : _('操作失败，详见「插件日志」页')
			]), ok ? 'info' : 'error');
			window.setTimeout(function () { location.reload(); }, 800);
		}).catch(function (e) {
			b.disabled = false;
			b.textContent = orig;
			ui.addNotification(null, E('p', {}, [ _('调用失败：') + (e && e.message || e) ]), 'error');
		});
	});
	return b;
}

return view.extend({
	load: function () {
		/* 不吞异常：取状态失败时要在页面上看见原因，而不是渲染成「没有线路」 */
		return getStatus().then(function (r) { return r || {}; })
			.catch(function (e) { return { error: (e && e.message) || String(e) }; });
	},

	render: function (st) {
		if (st.error)
			return E('div', { 'class': 'cbi-section alert-message error' },
				[ _('读取状态失败：') + st.error ]);

		var s = st.settings || {};
		var lines = st.lines || [];
		var accounts = st.accounts || [];
		var total = st.total || 0;
		var online = st.online || 0;
		var enabled = s.enabled;

		/* ---------- 1) 总状态横幅：首屏回答"现在通不通网" ---------- */
		var bannerCls, bannerTxt;
		if (!enabled) {
			bannerCls = 'alert-message warning';
			bannerTxt = _('插件已停用 —— 不会自动认证，也不会编排线路。');
		} else if (total === 0) {
			bannerCls = 'alert-message warning';
			bannerTxt = _('尚未配置线路 —— 请到「插件设置」页添加。');
		} else if (online === total) {
			bannerCls = 'alert-message success';
			bannerTxt = _('%d 条线路全部在线，外网正常。').format(total);
		} else if (online > 0) {
			bannerCls = 'alert-message warning';
			bannerTxt = _('%d 条线路在线 / 共 %d 条。').format(online, total);
		} else {
			bannerCls = 'alert-message error';
			bannerTxt = _('全部 %d 条线路均未认证，校园网可能已断线。').format(total);
		}
		var banner = E('div', { 'class': 'cbi-section ' + bannerCls }, [
			E('strong', {}, [ bannerTxt ])
		]);

		/* ---------- 2) 首要指标 ---------- */
		function stat(label, value) {
			return E('div', { 'style': 'margin-right:28px;display:inline-block;vertical-align:top' }, [
				E('div', { 'class': 'cbi-section-descr', 'style': 'margin:0' }, [ label ]),
				E('div', { 'style': 'font-size:20px;font-weight:600;line-height:1.4' }, [ String(value) ])
			]);
		}
		var stats = E('div', { 'class': 'cbi-section' }, [
			stat(_('在线线路'), online + ' / ' + total),
			stat(_('保活进程'), st.keepers || 0),
			stat(_('认证网关'), s.gateway || '-'),
			stat(_('认证模式'), s.auth_mode || '-'),
			stat(_('版本'), 'v' + (st.version || '?'))
		]);

		/* ---------- 3) 线路表（主体）---------- */
		var rows = [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, [ _('线路') ]),
				E('th', { 'class': 'th' }, [ _('归属账号') ]),
				E('th', { 'class': 'th' }, [ _('设备') ]),
				E('th', { 'class': 'th' }, [ _('状态') ]),
				E('th', { 'class': 'th' }, [ _('IP') ]),
				E('th', { 'class': 'th' }, [ _('最近结果') ]),
				E('th', { 'class': 'th cbi-section-actions' }, [])
			])
		];

		if (!lines.length) {
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': '7' }, [
					E('em', {}, [ _('尚未配置线路 —— 请到「插件设置 → 线路」添加。') ])
				])
			]));
		}

		lines.forEach(function (l) {
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, [
					l.id,
					l.enabled ? '' : E('span', { 'class': 'cbi-section-descr', 'style': 'margin-left:6px' },
						[ _('（已停用）') ])
				]),
				E('td', { 'class': 'td' }, [ l.account || E('em', {}, [ _('未绑定') ]) ]),
				E('td', { 'class': 'td' }, [ l.dev || '-' ]),
				E('td', { 'class': 'td' }, [ badge(l.status) ]),
				E('td', { 'class': 'td' }, [ l.ip || '-' ]),
				E('td', { 'class': 'td' }, [ l.msg || '-' ]),
				E('td', { 'class': 'td cbi-section-actions' }, [
					actionBtn(_('登录'), _('登录中…'), 'cbi-button-action',
						function () { return authLine(l.id); })
				])
			]));
		});

		var lineCard = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('线路') ]),
			E('table', { 'class': 'table cbi-section-table' }, rows)
		]);

		/* ---------- 4) 账号实名信息（门户回传）---------- */
		var accountRows = [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, [ _('账号') ]),
				E('th', { 'class': 'th' }, [ _('姓名') ]),
				E('th', { 'class': 'th' }, [ _('学号') ]),
				E('th', { 'class': 'th' }, [ _('用户组') ]),
				E('th', { 'class': 'th' }, [ _('余额') ])
			])
		];
		var anyInfo = false;
		accounts.forEach(function (a) {
			/* 门户信息挂在"线路"上，按账号聚合（取该账号下第一条拿到数据的线路） */
			var src = null;
			lines.forEach(function (l) {
				if (l.account === a.id && l.puser && !src) src = l;
			});
			if (src) anyInfo = true;
			accountRows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, [
					a.id,
					a.enabled ? '' : E('span', { 'class': 'cbi-section-descr', 'style': 'margin-left:6px' },
						[ _('（已停用）') ]),
					a.has_credential ? '' : E('span', { 'class': 'cbi-section-descr', 'style': 'margin-left:6px' },
						[ _('（未配置帐密）') ])
				]),
				E('td', { 'class': 'td' }, [ (src && src.pname) || '-' ]),
				E('td', { 'class': 'td' }, [ (src && src.puser) || '-' ]),
				E('td', { 'class': 'td' }, [ (src && src.pgroup) || '-' ]),
				E('td', { 'class': 'td' }, [ (src && src.pfee) || '-' ])
			]));
		});
		if (!accounts.length) {
			accountRows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': '5' }, [ E('em', {}, [ _('尚未配置账号。') ]) ])
			]));
		}

		var accountCard = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('账号') ]),
			E('table', { 'class': 'table cbi-section-table' }, accountRows),
			anyInfo ? E([]) : E('div', { 'class': 'cbi-section-descr' },
				[ _('实名信息由校园网门户回传，需要线路处于已认证状态。') ])
		]);

		/* ---------- 5) 操作 ---------- */
		var ops = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('操作') ]),
			E('div', {}, [
				actionBtn(_('立即登录全部'), _('登录中…'), 'cbi-button-action',
					function () { return authLine('all'); }),
				' ',
				actionBtn(_('重建多播线路'), _('编排中…'), 'cbi-button-apply',
					function () { return lineApply(); })
			])
		]);

		/* ---------- 6) 危险区域 ---------- */
		var danger = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('危险操作') ]),
			E('div', { 'class': 'cbi-section-descr' },
				[ _('撤销会删除本插件创建的全部 macvlan 设备、防火墙与 mwan3 条目，之后需要重新「重建多播线路」。') ]),
			actionBtnTearDown()
		]);

		function actionBtnTearDown() {
			var b = E('button', { 'class': 'cbi-button cbi-button-negative' }, [ _('撤销多播线路') ]);
			b.addEventListener('click', function (ev) {
				ev.preventDefault();
				/* 破坏性操作用模态二次确认，不用 window.confirm
				 * （不可样式化、不可翻译）。参 package-manager.js 的写法。 */
				ui.showModal(_('撤销多播线路'), [
					E('p', {}, [
						_('将删除本插件创建的全部 macvlan 设备、防火墙规则与 mwan3 均衡配置。'),
						E('br'),
						_('校园网认证本身不受影响；如需恢复，请重新点「重建多播线路」。')
					]),
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('取消') ]),
						' ',
						E('button', {
							'class': 'btn cbi-button-negative',
							'click': function () {
								ui.hideModal();
								lineTeardown().then(function (r) {
									ui.addNotification(null, E('p', {}, [
										(r && r.ok !== false) ? _('已撤销多播线路') : _('撤销失败，详见日志')
									]), (r && r.ok !== false) ? 'info' : 'error');
									window.setTimeout(function () { location.reload(); }, 800);
								}).catch(function (e) {
									ui.addNotification(null, E('p', {}, [ _('调用失败：') + e ]), 'error');
								});
							}
						}, [ _('确认撤销') ])
					])
				]);
			});
			return b;
		}

		return E('div', {}, [
			E('style', {}, [ BADGE_CSS ]),
			banner,
			stats,
			lineCard,
			accountCard,
			ops,
			danger
		]);
	},

	/* 只读页：必须显式关掉三个钩子，否则底部会多出没用的「保存并应用」 */
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
