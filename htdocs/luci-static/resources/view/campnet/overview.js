'use strict';
'require view';
'require view.campnet.common as common';

/* ============================================================
 * 状态页 —— 纯展示，**不放任何交互控件**。
 *
 * 之前的版本在这里堆了「立即登录全部」「重建多播线路」「强制重新登录全部」
 * 「撤销多播线路」以及每行的「登录」按钮，结果是同一类操作被拆到三个视觉
 * 区块、破坏性等级和对待方式不成比例，而且"重连"这件事本来就不需要按钮：
 * 每条线路一个 procd keeper 在周期探测，改了配置走设置页的「保存并应用」
 * 就会重载服务并重启全部 keeper（keeper 循环开头即探测+登录）。
 *
 * 所以这里只回答两个问题：现在通不通网、每条线路怎么样。
 * ============================================================ */

function statCell(label, value) {
	return E('div', {
		'style': 'margin-right:28px;margin-bottom:8px;display:inline-block;vertical-align:top'
	}, [
		E('div', { 'class': 'cbi-section-descr', 'style': 'margin:0' }, [ label ]),
		E('div', { 'style': 'line-height:1.4' }, [ String(value) ])
	]);
}

return view.extend({
	load: function () {
		/* 不吞异常：取状态失败时要看得见原因，而不是渲染成「没有线路」 */
		return common.getStatus().then(function (r) { return r || {}; })
			.catch(function (e) { return { error: (e && e.message) || String(e) }; });
	},

	render: function (st) {
		if (st.error)
			return common.errorCard(st.error, function () { window.location.reload(); });

		/* ---- 骨架：只建一次，之后靠 apply() 就地改文本 ---- */
		var bannerEl = E('div', { 'class': 'cbi-section' });
		var onlineEl = E('div', { 'style': 'font-size:20px;font-weight:600;line-height:1.4' });
		var updatedEl = E('div', { 'class': 'cbi-section-descr', 'style': 'margin:0' });

		var lineBody = E('tbody');
		var lineCard = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('线路') ]),
			E('table', { 'class': 'table cbi-section-table' }, [
				E('thead', { 'class': 'thead' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, [ _('线路') ]),
						E('th', { 'class': 'th' }, [ _('归属账号') ]),
						E('th', { 'class': 'th' }, [ _('设备') ]),
						E('th', { 'class': 'th' }, [ _('状态') ]),
						E('th', { 'class': 'th' }, [ _('IP') ])
					])
				]),
				lineBody
			])
		]);

		var acctBody = E('tbody');
		var acctHint = E('div', { 'class': 'cbi-section-descr' });
		var acctCard = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('账号') ]),
			E('table', { 'class': 'table cbi-section-table' }, [
				E('thead', { 'class': 'thead' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, [ _('账号') ]),
						E('th', { 'class': 'th' }, [ _('姓名') ]),
						E('th', { 'class': 'th' }, [ _('学号') ]),
						E('th', { 'class': 'th' }, [ _('用户组') ]),
						E('th', { 'class': 'th' }, [ _('余额') ])
					])
				]),
				acctBody
			]),
			acctHint
		]);

		/* 排障信息下沉到页尾：普通用户不需要在首屏看到网关和进程数 */
		var diagEl = E('div', { 'class': 'cbi-section' });

		var root = E('div', {}, [
			E('style', {}, [ common.badgeCss() ]),
			bannerEl,
			/* 首屏只留"几条线在线"和"数据是什么时候的" */
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-descr', 'style': 'margin:0' }, [ _('在线线路') ]),
				onlineEl,
				updatedEl
			]),
			lineCard,
			acctCard,
			diagEl
		]);

		function clear(node) {
			while (node.firstChild) node.removeChild(node.firstChild);
		}

		function apply(s) {
			var settings = s.settings || {};
			var lines = s.lines || [];
			var accounts = s.accounts || [];
			/* total/online 只数**启用**的线路：停用是用户有意关掉的，
			 * 算进分母会让横幅永远显示"未全部在线"—— 一个假警报。
			 * lines_all 用来区分「一条都没配」和「配了但全停用了」。 */
			var total = s.total || 0;
			var online = s.online || 0;
			var all = (s.lines_all == null) ? total : s.lines_all;
			var disabled = all - total;

			/* ---- 横幅：一句话回答"现在通不通网" ---- */
			var cls, txt;
			if (!settings.enabled) {
				cls = 'alert-message warning';
				txt = _('插件已停用 —— 不会自动认证，也不会编排线路。');
			} else if (all === 0) {
				cls = 'alert-message warning';
				txt = _('尚未配置线路。');
			} else if (total === 0) {
				cls = 'alert-message warning';
				txt = _('%d 条线路都处于停用状态。').format(all);
			} else if (online === total) {
				cls = 'alert-message success';
				txt = _('%d 条线路全部在线，外网正常。').format(total);
			} else if (online > 0) {
				cls = 'alert-message warning';
				txt = _('%d 条线路在线 / 共 %d 条。').format(online, total);
			} else {
				cls = 'alert-message error';
				txt = _('全部 %d 条线路均未认证，校园网可能已断线。').format(total);
			}
			bannerEl.className = 'cbi-section ' + cls;
			clear(bannerEl);
			bannerEl.appendChild(E('strong', {}, [ txt ]));

			/* ---- 首屏指标 ---- */
			clear(onlineEl);
			onlineEl.appendChild(document.createTextNode(online + ' / ' + total));
			clear(updatedEl);
			var meta = _('最后更新') + ' ' + common.clockText();
			if (disabled > 0)
				meta += ' · ' + _('另有 %d 条线路已停用').format(disabled);
			updatedEl.appendChild(document.createTextNode(meta));

			/* ---- 线路表 ---- */
			clear(lineBody);
			if (!lines.length) {
				lineBody.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'colspan': '5' }, [
						common.emptyText(_('尚未配置线路。'), common.settingsUrl(), _('到设置页添加'))
					])
				]));
			}
			lines.forEach(function (l) {
				/* 「最近结果」不再单独占一列（它和状态徽标语义重复，而且长度不可控
				 * 会把表格撑宽），改为挂在徽标的 title 上，鼠标悬停可见。 */
				lineBody.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, [
						l.id,
						l.enabled ? '' : E('span', { 'class': 'cbi-section-descr', 'style': 'margin-left:6px' },
							[ _('（已停用）') ])
					]),
					E('td', { 'class': 'td' }, [ l.account || E('em', {}, [ _('未绑定') ]) ]),
					E('td', { 'class': 'td' }, [ l.dev || '-' ]),
					E('td', { 'class': 'td' }, [ common.badge(l.status, l.msg || '') ]),
					E('td', { 'class': 'td' }, [ l.ip || '-' ])
				]));
			});

			/* ---- 账号实名（门户回传，按账号聚合） ---- */
			clear(acctBody);
			var anyInfo = false;
			if (!accounts.length) {
				acctBody.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'colspan': '5' }, [
						common.emptyText(_('尚未配置账号。'), common.settingsUrl(), _('到设置页添加'))
					])
				]));
			}
			accounts.forEach(function (a) {
				var src = null;
				lines.forEach(function (l) {
					if (l.account === a.id && l.puser && !src) src = l;
				});
				if (src) anyInfo = true;
				acctBody.appendChild(E('tr', { 'class': 'tr' }, [
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
			clear(acctHint);
			acctHint.appendChild(document.createTextNode(
				anyInfo ? _('实名信息由校园网门户回传。')
				        : _('实名信息由校园网门户回传，需要线路处于已认证状态。')));

			/* ---- 诊断信息 ---- */
			clear(diagEl);
			diagEl.appendChild(E('h3', {}, [ _('诊断信息') ]));
			diagEl.appendChild(E('div', {}, [
				statCell(_('认证网关'), settings.gateway || '-'),
				statCell(_('认证模式'), settings.auth_mode || '-'),
				statCell(_('保活进程'), s.keepers || 0),
				statCell(_('插件版本'), 'v' + (s.version || '?'))
			]));
		}

		apply(st);

		/* 8 秒轮询：keeper 在后台每 60 秒跑一轮，页面不该让用户对着
		 * 一个永远停在"离线"的徽标手动 F5。 */
		common.poll(function () {
			return common.getStatus().then(function (s) { apply(s || {}); });
		}, 8000, root);

		return root;
	},

	/* 只读页：显式关掉三个钩子，否则底部会多出没用的「保存并应用」。
	 * （luci.js 的 addFooter 判定 `if (handleSaveApply || handleSave || handleReset)`
	 *   —— 三个全空才不渲染 cbi-page-actions。） */
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
