'use strict';
'require view';
'require uci';
'require ui';
'require view.campnet.common as common';

/* ============================================================
 * 设置页 —— 自定义视图（不用 form.Map / form.GridSection）。
 *
 * 为什么不用 CBI：本插件的模型和 CBI 对不上 —— 账号↔线路是引用关系
 * （删账号要级联删线路）、凭据存在 uci **之外**（/etc/campnet/.config）、
 * 设备名由 section id 派生。硬套的结果是「一页三种编辑范式」外加两个
 * 实测到的硬伤（详见 common.js 顶部注释）。
 *
 * 这里配置读写全部走 uci.js，提交仍由**视图基类默认的**
 * handleSaveApply 完成 —— 于是「未保存的更改」菜单角标、diff 弹窗、
 * 带 rollback 的 apply 流程全自动生效，不需要自己实现一套。
 *
 * 唯一的例外是帐密：它不在 uci 里，但要和 uci 变更**在同一个提交点**落盘，
 * 所以先暂存在内存里，由 handleSave 统一 flush。
 * ============================================================ */

var W = 'width:100%';
var SEC = 'settings';

function notify(msg, kind) {
	ui.addNotification(null, E('p', {}, [ msg ]), kind || 'info');
}

function clear(node) {
	while (node.firstChild) node.removeChild(node.firstChild);
}

/* uci.get 对"段不存在"返回 null、对"选项未设置"返回 undefined，
 * 两种情况都要回退到默认值，否则取到的是 null 而不是 ''。 */
function uval(opt, def) {
	var v = uci.get('campnet', SEC, opt);
	return (v == null || v === '') ? (def == null ? '' : def) : v;
}

function uon(opt, def) {
	var v = uci.get('campnet', SEC, opt);
	if (v == null || v === '') return def === '1';
	return v === '1';
}

function rowEl(label, descr, node) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, [ label ]),
		E('div', { 'class': 'cbi-value-field' }, [
			node,
			descr ? E('div', { 'class': 'cbi-value-description' }, [ descr ]) : ''
		])
	]);
}

function sectionEl(title, descr, nodes) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ title ]),
		descr ? E('div', { 'class': 'cbi-section-descr' }, [ descr ]) : ''
	].concat(nodes));
}

/* ---------------- 认证参数 pane 的控件 ---------------- */

function textOpt(opt, o) {
	o = o || {};
	var input = E('input', {
		'type': 'text', 'class': 'cbi-input-text', 'style': W,
		'value': uval(opt, o.def),
		'placeholder': (o.def == null || o.def === '') ? null : o.def
	});

	input.addEventListener('change', function () {
		var v = input.value.trim();
		if (v === '') {
			/* uci.set 对空串是**空操作**（"设置为空"必须用 unset），
			 * 这里不特判的话会把一个字段"改成空"却什么都不发生。 */
			if (o.rmempty) { uci.unset('campnet', SEC, opt); return; }
			v = o.def || '';
			input.value = v;
		}
		if (o.num) {
			var n = parseInt(v, 10);
			if (isNaN(n)) {
				notify(_('%s 必须是数字').format(o.label || opt), 'warning');
				input.value = uval(opt, o.def);
				return;
			}
			var c = n;
			if (o.min != null && n < o.min) c = o.min;
			if (o.max != null && n > o.max) c = o.max;
			if (c !== n)
				notify(_('%s 超出范围 %d–%d，已纠正为 %d')
					.format(o.label || opt, o.min, o.max, c), 'warning');
			v = String(c);
			input.value = v;
		}
		uci.set('campnet', SEC, opt, v);
	});

	return input;
}

function flagOpt(opt, def) {
	var cb = E('input', { 'type': 'checkbox', 'checked': uon(opt, def) ? 'checked' : null });
	cb.addEventListener('change', function () {
		uci.set('campnet', SEC, opt, cb.checked ? '1' : '0');
	});
	return cb;
}

function selectOpt(opt, choices, def) {
	var cur = uval(opt, def);
	var sel = E('select', { 'class': 'cbi-input-select', 'style': W },
		choices.map(function (c) {
			return E('option', { 'value': c[0], 'selected': (c[0] === cur) ? 'selected' : null },
				[ c[1] ]);
		}));
	sel.addEventListener('change', function () { uci.set('campnet', SEC, opt, sel.value); });
	return sel;
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('campnet'),
			common.getStatus().then(function (r) { return r || {}; })
				.catch(function (e) { return { error: (e && e.message) || String(e) }; })
		]).then(function (r) { return { st: r[1] }; });
	},

	render: function (data) {
		var st = data.st || {};
		if (st.error)
			return common.errorCard(st.error, function () { window.location.reload(); });

		var self = this;

		/* 待提交的帐密。凭据不在 uci 里，但和 uci 变更同一个提交点落盘，
		 * 这样全页只有一种提交语义（原来的版本是"帐密点了立刻生效、
		 * 表单要保存、表格在弹窗里保存"三种混在一起）。 */
		self.credWrites = {};	/* sid -> {username, password} */
		self.credDeletes = [];	/* [sid] */

		function acctRuntime(sid) {
			var list = st.accounts || [];
			for (var i = 0; i < list.length; i++)
				if (list[i].id === sid) return list[i];
			return null;
		}

		function accountsSec() { return uci.sections('campnet', 'account') || []; }
		function linesSec() { return uci.sections('campnet', 'line') || []; }
		function linesOf(sid) {
			return linesSec().filter(function (l) { return l.account === sid; });
		}

		function credState(sid) {
			if (self.credWrites[sid]) return _('待保存');
			var rt = acctRuntime(sid);
			return (rt && rt.has_credential) ? _('已配置') : _('未配置');
		}

		/* ================= 账号 ================= */
		var acctBody = E('tbody');

		function renderAccounts() {
			clear(acctBody);
			var accounts = accountsSec();

			if (!accounts.length) {
				acctBody.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'colspan': '5' }, [
						E('em', {}, [ _('还没有账号 —— 在下面的输入框里起个名字（如 main）再点「添加」。') ])
					])
				]));
				return;
			}

			accounts.forEach(function (a) {
				var sid = a['.name'];
				var n = linesOf(sid).length;

				var enabled = E('input', {
					'type': 'checkbox', 'checked': (a.enabled !== '0') ? 'checked' : null
				});
				enabled.addEventListener('change', function () {
					uci.set('campnet', sid, 'enabled', enabled.checked ? '1' : '0');
				});

				var credBtn = E('button', { 'class': 'cbi-button cbi-button-edit' }, [ _('帐密') ]);
				credBtn.addEventListener('click', function (ev) {
					ev.preventDefault();
					openCred(sid);
				});

				var delBtn = E('button', { 'class': 'cbi-button cbi-button-remove' }, [ _('删除') ]);
				delBtn.addEventListener('click', function (ev) {
					ev.preventDefault();
					delAccount(sid);
				});

				acctBody.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, [ sid ]),
					E('td', { 'class': 'td' }, [ enabled ]),
					E('td', { 'class': 'td' }, [ String(n) ]),
					E('td', { 'class': 'td' }, [ credState(sid) ]),
					E('td', { 'class': 'td cbi-section-actions' }, [ credBtn, ' ', delBtn ])
				]));
			});
		}

		function openCred(sid) {
			var rt = acctRuntime(sid);
			var configured = !!(rt && rt.has_credential);
			var known = (rt && rt.username) || '';

			var userIn = E('input', {
				'type': 'text', 'class': 'cbi-input-text', 'style': W,
				'value': known || '',
				'placeholder': _('学号 / 用户名'),
				'readonly': configured ? 'readonly' : null
			});
			var passIn = E('input', {
				'type': 'password', 'class': 'cbi-input-text', 'style': W,
				'autocomplete': 'new-password',
				'placeholder': configured ? _('留空 = 不修改密码') : _('密码')
			});

			/* 已配置时用户名**回填并只读**：最常见的一次操作是"只改密码"，
			 * 而原来那个空输入框要求把学号重新完整敲一遍，否则保存时报
			 * 「用户名与密码都不能为空」—— 最常用的操作反而最容易失败。 */
			var userBox = E('div', {}, [ userIn ]);
			if (configured) {
				var editBtn = E('button', {
					'class': 'cbi-button cbi-button-neutral', 'style': 'margin-top:4px'
				}, [ _('修改用户名') ]);
				editBtn.addEventListener('click', function (ev) {
					ev.preventDefault();
					userIn.readOnly = false;
					userIn.focus();
					editBtn.disabled = true;
				});
				userBox.appendChild(editBtn);
			}

			var rows = [
				{ label: _('用户名'), node: userBox,
				  descr: configured ? _('已回填已保存的学号；要换成别的学号，点「修改用户名」。') : null },
				{ label: _('密码'), node: passIn,
				  descr: _('密码只存在路由器本地（/etc/campnet/.config，0600），不写入 uci、不会上传。') }
			];

			common.formModal(_('帐密') + ' — ' + sid, rows, _('确定'), function () {
				var u = userIn.value.trim(), p = passIn.value;
				if (!u) { notify(_('用户名不能为空'), 'warning'); return false; }
				if (!p) {
					/* 没动密码也没换用户名 = 什么都没改，不该报「密码不能为空」。
					 * 这是最常见的一次误报（用户只想改密码，却被要求重填学号）。 */
					if (configured && u === known) { notify(_('未做任何修改')); return true; }
					notify(_('请输入密码'), 'warning');
					return false;
				}
				self.credWrites[sid] = { username: u, password: p };
				/* 之前排过删除的，现在又要写回来 */
				self.credDeletes = self.credDeletes.filter(function (x) { return x !== sid; });
				renderAccounts();
				notify(_('账号 %s 的帐密已记入待保存，点页面底部「保存并应用」后才写入').format(sid));
				return true;
			});
		}

		function delAccount(sid) {
			var owned = linesOf(sid);
			var names = owned.map(function (l) { return l['.name']; });

			common.confirm(_('删除账号') + ' ' + sid, [
				E('p', {}, [
					owned.length
						? _('将同时删除该账号名下的 %d 条线路（%s）。').format(owned.length, names.join('、'))
						: _('该账号名下没有线路。')
				]),
				E('p', {}, [ _('已保存的帐密也会一并删除。') ]),
				E('p', { 'class': 'cbi-section-descr' }, [
					_('这些改动在点击页面底部「保存并应用」之前不会生效；')
				])
			], _('删除'), true, function () {
				/* 级联：账号段 + 它名下的线路段。
				 * 只删账号段的话，线路会变成孤儿 —— 归属账号列还显示着
				 * 一个不存在的名字，而 dal 后端的 acct_enabled() 对
				 * 不存在的段曾经默认返回 1（已修为返回 0），
				 * 于是它还会带着残留凭据继续认证。两头都要堵。 */
				linesSec().forEach(function (l) {
					if (l.account === sid) uci.remove('campnet', l['.name']);
				});
				uci.remove('campnet', sid);
				delete self.credWrites[sid];
				if (self.credDeletes.indexOf(sid) < 0) self.credDeletes.push(sid);
				renderAccounts();
				renderLines();
			});
		}

		var acctNameIn = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width:auto',
			'placeholder': _('新账号名（如 acc2）')
		});
		var acctAddBtn = E('button', { 'class': 'cbi-button cbi-button-add' }, [ _('添加') ]);
		acctAddBtn.addEventListener('click', function (ev) {
			ev.preventDefault();
			var name = acctNameIn.value.trim();
			if (!name) { notify(_('请先填写账号名'), 'warning'); return; }
			if (uci.get('campnet', name) != null) {
				notify(_('名字「%s」已被占用（账号与线路共用一个命名空间）').format(name), 'warning');
				return;
			}
			uci.add('campnet', 'account', name);
			uci.set('campnet', name, 'enabled', '1');
			acctNameIn.value = '';
			renderAccounts();
			renderLines();
			notify(_('已添加账号 %s —— 请点该行的「帐密」填写学号与密码').format(name));
		});

		/* ================= 线路 ================= */
		var lineBody = E('tbody');

		function renderLines() {
			clear(lineBody);
			var lines = linesSec();
			var accounts = accountsSec();

			if (!lines.length) {
				lineBody.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'colspan': '5' }, [
						E('em', {}, [ _('还没有线路 —— 先在上面的「账号」页签建一个账号，再回这里添加线路。') ])
					])
				]));
				return;
			}

			lines.forEach(function (l) {
				var sid = l['.name'];

				var enabled = E('input', {
					'type': 'checkbox', 'checked': (l.enabled !== '0') ? 'checked' : null
				});
				enabled.addEventListener('change', function () {
					uci.set('campnet', sid, 'enabled', enabled.checked ? '1' : '0');
				});

				var acc = l.account || '';
				var accKnown = accounts.some(function (a) { return a['.name'] === acc; });

				var editBtn = E('button', { 'class': 'cbi-button cbi-button-edit' }, [ _('编辑') ]);
				editBtn.addEventListener('click', function (ev) {
					ev.preventDefault();
					openLine(sid, false);
				});

				var delBtn = E('button', { 'class': 'cbi-button cbi-button-remove' }, [ _('删除') ]);
				delBtn.addEventListener('click', function (ev) {
					ev.preventDefault();
					common.confirm(_('删除线路') + ' ' + sid, [
						E('p', {}, [ _('该线路的 macvlan 设备、防火墙与 mwan3 条目会在提交后由编排过程自动回收。') ]),
						E('p', { 'class': 'cbi-section-descr' }, [
							_('这些改动在点击页面底部「保存并应用」之前不会生效。')
						])
					], _('删除'), true, function () {
						uci.remove('campnet', sid);
						renderAccounts();
						renderLines();
					});
				});

				lineBody.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, [ sid ]),
					E('td', { 'class': 'td' }, [ enabled ]),
					E('td', { 'class': 'td' }, [
						acc
							? [ acc, accKnown ? '' : E('span',
								{ 'class': 'cbi-section-descr', 'style': 'margin-left:6px' },
								[ _('（账号不存在）') ]) ]
							: E('em', {}, [ _('未绑定') ])
					]),
					E('td', { 'class': 'td' }, [ l.type || 'macvlan' ]),
					E('td', { 'class': 'td cbi-section-actions' }, [ editBtn, ' ', delBtn ])
				]));
			});
		}

		/* <sid> 为空 = 新建；isNew 时字段用默认值 */
		function openLine(sid, isNew) {
			var accounts = accountsSec();
			if (!accounts.length) {
				notify(_('请先到「账号」页签创建一个账号 —— 每条线路都必须归属一个账号'), 'warning');
				return;
			}

			var get = function (opt, def) {
				if (isNew) return def;
				var v = uci.get('campnet', sid, opt);
				return (v == null || v === '') ? def : v;
			};

			var accSel = E('select', { 'class': 'cbi-input-select', 'style': W },
				accounts.map(function (a) {
					var name = a['.name'];
					return E('option', {
						'value': name, 'selected': (name === get('account', '')) ? 'selected' : null
					}, [ name ]);
				}));

			var typeSel = E('select', { 'class': 'cbi-input-select', 'style': W }, [
				E('option', { 'value': 'macvlan', 'selected': (get('type', 'macvlan') === 'macvlan') ? 'selected' : null },
					[ _('macvlan — 独立设备（多拨）') ]),
				E('option', { 'value': 'wan', 'selected': (get('type', 'macvlan') === 'wan') ? 'selected' : null },
					[ _('wan — 复用现有接口') ])
			]);

			var ifaceIn = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': W,
				'value': get('iface', 'wan') });
			var macIn = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': W,
				'value': get('macaddr', ''), 'placeholder': _('留空自动生成并固化') });
			var metricIn = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': W,
				'value': get('metric', '10') });
			var weightIn = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': W,
				'value': get('weight', '10') });
			var rmetricIn = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': W,
				'value': get('route_metric', '20') });
			var ifbaseIn = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': W,
				'value': get('ifbase', ''), 'placeholder': _('可选，影响设备名 campnet_<短名>') });

			/* 类型决定哪些字段有意义 —— 渐进披露，而不是把 8 个字段
			 * 一股脑摊在用户面前（其中一半与当前类型无关）。 */
			var rowIface = rowEl(_('网络接口'), _('类型为 wan 时生效。'), ifaceIn);
			var rowMac = rowEl(_('macvlan MAC'), null, macIn);
			var rowMetric = rowEl(_('mwan3 metric'),
				_('要带宽叠加，各线路必须填**同一个值**；不同值只会做故障切换。'), metricIn);
			var rowWeight = rowEl(_('mwan3 权重'), _('metric 相同时的流量配比。'), weightIn);
			var rowRmetric = rowEl(_('默认路由 metric'), _('须大于主 wan 的 0，避免抢走默认路由。'),
				rmetricIn);

			function syncType() {
				var isWan = typeSel.value === 'wan';
				rowIface.style.display = isWan ? '' : 'none';
				[ rowMac, rowMetric, rowWeight, rowRmetric ].forEach(function (r) {
					r.style.display = isWan ? 'none' : '';
				});
			}
			typeSel.addEventListener('change', syncType);
			syncType();

			var body = E('div', { 'class': 'cbi-section' }, [
				rowEl(_('归属账号'), _('这条线路用哪个账号上网。一个账号可以有多条线路。'), accSel),
				rowEl(_('类型'), _('要带宽叠加就用 macvlan（独立设备 + 独立 MAC）。'), typeSel),
				rowIface, rowMac, rowMetric, rowWeight, rowRmetric,
				rowEl(_('短名'), null, ifbaseIn)
			]);

			var ok = E('button', { 'class': 'cbi-button cbi-button-positive important' },
				[ isNew ? _('创建') : _('确定') ]);
			ok.addEventListener('click', function (ev) {
				ev.preventDefault();

				var metric = parseInt(metricIn.value, 10);
				var weight = parseInt(weightIn.value, 10);
				var rmetric = parseInt(rmetricIn.value, 10);
				if (typeSel.value === 'macvlan' &&
					(isNaN(metric) || isNaN(weight) || isNaN(rmetric))) {
					notify(_('metric / 权重 / 默认路由 metric 都必须是数字'), 'warning');
					return;
				}

				if (isNew) {
					uci.add('campnet', 'line', sid);
					uci.set('campnet', sid, 'enabled', '1');
				}
				uci.set('campnet', sid, 'account', accSel.value);
				uci.set('campnet', sid, 'type', typeSel.value);
				if (typeSel.value === 'wan') {
					uci.set('campnet', sid, 'iface', ifaceIn.value.trim() || 'wan');
					/* 切回 wan 后这些字段没有意义，留着会让人以为还在生效 */
					[ 'macaddr', 'metric', 'weight', 'route_metric' ].forEach(function (o) {
						uci.unset('campnet', sid, o);
					});
				} else {
					if (macIn.value.trim()) uci.set('campnet', sid, 'macaddr', macIn.value.trim());
					uci.set('campnet', sid, 'metric', String(metric));
					uci.set('campnet', sid, 'weight', String(weight));
					uci.set('campnet', sid, 'route_metric', String(rmetric));
				}
				if (ifbaseIn.value.trim()) uci.set('campnet', sid, 'ifbase', ifbaseIn.value.trim());

				ui.hideModal();
				renderLines();
				renderAccounts();
				if (isNew) notify(_('已创建线路 %s，点页面底部「保存并应用」后生效').format(sid));
			});

			ui.showModal(isNew ? _('新建线路') + ' — ' + sid : _('编辑线路') + ' — ' + sid, [
				body,
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('取消') ]),
					' ', ok
				])
			]);
		}

		var lineNameIn = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width:auto',
			'placeholder': _('新线路名（如 line2）')
		});
		var lineAddBtn = E('button', { 'class': 'cbi-button cbi-button-add' }, [ _('添加') ]);
		lineAddBtn.addEventListener('click', function (ev) {
			ev.preventDefault();
			var name = lineNameIn.value.trim();
			if (!name) { notify(_('请先填写线路名'), 'warning'); return; }
			if (uci.get('campnet', name) != null) {
				notify(_('名字「%s」已被占用（账号与线路共用一个命名空间）').format(name), 'warning');
				return;
			}
			lineNameIn.value = '';
			openLine(name, true);
		});

		/* ================= 认证参数 ================= */
		var advBox = E('div', { 'style': 'margin-top:8px' });

		var advChk = E('input', { 'type': 'checkbox' });
		/* 纯 UI 偏好：只影响本地显示，**不写 uci**。
		 * 写 uci 的话，勾一下开关就会触发 procd reload，把所有认证 keeper
		 * 重启一遍 —— 一个折叠开关不该有这种副作用。 */
		advChk.checked = window.localStorage.getItem('campnet.show_advanced') === '1';
		advChk.addEventListener('change', function () {
			window.localStorage.setItem('campnet.show_advanced', advChk.checked ? '1' : '0');
			advBox.style.display = advChk.checked ? '' : 'none';
		});

		var authPane = E('div', {}, [
			sectionEl(_('基本'), null, [
				rowEl(_('启用'), _('关闭后停止保活与线路编排。'), flagOpt('enabled', '1')),
				rowEl(_('认证网关'), null, textOpt('gateway', { def: '10.0.1.51', label: _('认证网关') })),
				rowEl(_('认证模式'), _('不确定就保持 auto。'),
					selectOpt('auth_mode', [
						[ 'auto', _('auto（自动探测）') ],
						[ 'ruijie', _('ruijie — axe_bras') ],
						[ 'eportal', _('eportal — 锐捷门户') ]
					], 'auto')),
				rowEl(_('保活周期'), _('秒。掉线后最长等这么久才发现。'),
					textOpt('check_interval', { def: '60', num: true, min: 5, max: 3600, label: _('保活周期') })),
				rowEl(_('重试次数'), null,
					textOpt('max_retry', { def: '3', num: true, min: 1, max: 10, label: _('重试次数') })),
				rowEl(_('重试间隔'), _('秒。'),
					textOpt('retry_delay', { def: '5', num: true, min: 1, max: 600, label: _('重试间隔') })),
				rowEl(_('开机自动编排'), null, flagOpt('dial_on_start', '1'))
			]),
			sectionEl(_('高级参数'), null, [
				E('label', {}, [ advChk, ' ', _('展开高级参数'), ' ',
					E('span', { 'class': 'cbi-section-descr' },
						[ _('（这里只是显示/隐藏，不改任何配置、不会重启服务）') ]) ]),
				advBox
			])
		]);

		clear(advBox);
		[
			rowEl(_('探测 IP'), _('空格分隔，用于线路健康检查与外网连通判定。'),
				textOpt('track_ips', { def: '223.5.5.5 119.29.29.29', rmempty: true })),
			rowEl(_('在线探针'), _('返回 204 视为已认证。'),
				textOpt('probe_url', { def: 'http://connect.rom.miui.com/generate_204' })),
			rowEl(_('上行基础设备'), _('auto = 取类型为 wan 的线路的接口。'),
				textOpt('uplink', { def: 'auto' })),
			rowEl(_('认证域名'), _('留空 = 直接用网关 IP。'),
				textOpt('auth_host', { rmempty: true, placeholder: 'auth.example.edu.cn' })),
			rowEl(_('认证服务器 IP'), _('配合认证域名绕过 DNS。'),
				textOpt('server_ip', { rmempty: true })),
			rowEl('wlanacname', null, textOpt('wlanacname', { def: 'BRAS', rmempty: true })),
			rowEl('pageid', null, textOpt('pageid', { def: '5', num: true, min: 0, max: 9999 })),
			rowEl('templatetype', null, textOpt('templatetype', { def: '1', num: true, min: 0, max: 9999 })),
			rowEl('vlan', null, textOpt('vlan', { def: '0', num: true, min: 0, max: 4095 })),
			rowEl('auth_type', null, textOpt('auth_type', { def: '0', num: true, min: 0, max: 9999 })),
			rowEl(_('拨号轮询上限'), null,
				textOpt('poll_max', { def: '20', num: true, min: 1, max: 200, label: _('拨号轮询上限') })),
			rowEl(_('拨询间隔'), _('秒。'),
				textOpt('poll_interval', { def: '2', num: true, min: 1, max: 60, label: _('拨询间隔') })),
			rowEl(_('连接超时'), _('秒。'),
				textOpt('curl_connect_timeout', { def: '5', num: true, min: 1, max: 60, label: _('连接超时') })),
			rowEl(_('请求超时'), _('秒。'),
				textOpt('curl_timeout', { def: '12', num: true, min: 1, max: 120, label: _('请求超时') }))
		].forEach(function (r) { advBox.appendChild(r); });
		advBox.style.display = advChk.checked ? '' : 'none';

		/* ================= 关于 ================= */
		var verBox = E('div', { 'class': 'cbi-section-descr' });
		var verBtn = E('button', { 'class': 'cbi-button cbi-button-action' }, [ _('检查更新') ]);
		verBtn.addEventListener('click', function (ev) {
			ev.preventDefault();
			verBtn.disabled = true;
			verBtn.textContent = _('检查中…');
			common.checkUpdate('--refresh').then(function (r) {
				r = r || {};
				clear(verBox);
				if (!r.checked) {
					verBox.appendChild(E('span', {},
						[ _('暂时无法获取远端版本（检查网络，或仓库尚无 tag）。') ]));
				} else if (!r.latest) {
					verBox.appendChild(E('span', {},
						[ _('已是最新版本（%s）。').format('v' + (r.version || '?')) ]));
				} else {
					verBox.appendChild(E('span', {}, [
						_('发现新版本 %s').format(r.latest) + ' — ',
						E('a', { 'href': r.url || '#', 'target': '_blank', 'rel': 'noreferrer' },
							[ _('打开项目主页') ])
					]));
				}
			}).catch(function (e) {
				clear(verBox);
				verBox.appendChild(E('span', {}, [ _('检查失败：') + e ]));
			}).then(function () {
				verBtn.disabled = false;
				verBtn.textContent = _('检查更新');
			});
		});

		var aboutPane = E('div', {}, [
			sectionEl(_('关于'), null, [
				rowEl(_('当前版本'), null,
					E('strong', {}, [ 'v' + (st.version || '?') ])),
				rowEl(_('检查更新'), null, E('div', {}, [ verBtn, verBox ])),
				rowEl(_('项目主页'), null,
					E('a', {
						'href': 'https://github.com/RyanZhangK/luci-app-campnet',
						'target': '_blank', 'rel': 'noreferrer'
					}, [ 'https://github.com/RyanZhangK/luci-app-campnet' ])),
				rowEl(_('许可证'), null, E('span', {}, [ 'WTFPL 2.0' ]))
			])
		]);

		/* ================= 组装 ================= */
		renderAccounts();
		renderLines();

		var acctPane = E('div', { 'data-tab': 'account', 'data-tab-title': _('账号'), 'data-tab-active': 'true' }, [
			sectionEl(_('账号'), _('账号 = 身份（学号 / 密码）。线路 = 一次独立认证会话，必须归属一个账号。'), [
				E('table', { 'class': 'table cbi-section-table' }, [
					E('thead', { 'class': 'thead' }, [
						E('tr', { 'class': 'tr table-titles' }, [
							E('th', { 'class': 'th' }, [ _('账号') ]),
							E('th', { 'class': 'th' }, [ _('启用') ]),
							E('th', { 'class': 'th' }, [ _('线路数') ]),
							E('th', { 'class': 'th' }, [ _('帐密') ]),
							E('th', { 'class': 'th cbi-section-actions' }, [ _('操作') ])
						])
					]),
					acctBody
				]),
				E('div', { 'class': 'cbi-section-create' }, [ acctNameIn, ' ', acctAddBtn ])
			])
		]);

		var linePane = E('div', { 'data-tab': 'line', 'data-tab-title': _('线路') }, [
			sectionEl(_('线路'),
				_('一条线路 = 一次独立认证。要带宽叠加就多加几条 macvlan 线路，并入同一账号，且 metric 填同一个值。'), [
				E('table', { 'class': 'table cbi-section-table' }, [
					E('thead', { 'class': 'thead' }, [
						E('tr', { 'class': 'tr table-titles' }, [
							E('th', { 'class': 'th' }, [ _('线路') ]),
							E('th', { 'class': 'th' }, [ _('启用') ]),
							E('th', { 'class': 'th' }, [ _('归属账号') ]),
							E('th', { 'class': 'th' }, [ _('类型') ]),
							E('th', { 'class': 'th cbi-section-actions' }, [ _('操作') ])
						])
					]),
					lineBody
				]),
				E('div', { 'class': 'cbi-section-create' }, [ lineNameIn, ' ', lineAddBtn ])
			])
		]);

		var authTab = E('div', { 'data-tab': 'settings', 'data-tab-title': _('认证参数') }, [ authPane ]);
		var aboutTab = E('div', { 'data-tab': 'about', 'data-tab-title': _('关于') }, [ aboutPane ]);

		var group = E('div', { 'class': 'cbi-map-tabbed' },
			[ acctPane, linePane, authTab, aboutTab ]);

		var root = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('校园网认证') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('账号 = 身份；线路 = 一次独立认证会话。')
			]),
			group,
			E('div', { 'class': 'cbi-section-descr' }, [
				_('所有改动（包括帐密）都在点击底部「保存并应用」后一次性生效；')
			])
		]);

		/* 页签容器必须是"游离但已有父节点"的树 —— initTabGroup 会往
		 * group 前面插 <ul class="cbi-tabmenu">，所以 group.parentNode 不能为空。
		 * group 已经挂在 root 下面了，这里直接调即可（form.js 也是这么做的）。 */
		ui.tabs.initTabGroup(group.childNodes);

		return root;
	},

	/* ---------------- 提交 ----------------
	 * 必须自己调 uci.save()：视图基类默认的 handleSave 只遍历 `.cbi-map`
	 * 里的表单实例，自定义视图没有表单实例，于是它是**空操作** ——
	 * 点「保存」会什么都不发生。这正是 v1.0.x 设置页"改了存不下去"
	 * 的同一类坑，所以这里显式实现，并加了静态检查防止它被改回去。
	 *
	 * handleSaveApply **不覆写**：基类默认实现会先调本方法，再
	 * ui.changes.apply() —— 于是页脚三按钮、「未保存的更改」菜单角标、
	 * diff 弹窗、带 rollback 的确认流程全部自动生效。 */
	handleSave: function () {
		var self = this;
		var chain = Promise.resolve();

		(this.credDeletes || []).forEach(function (acc) {
			chain = chain.then(function () {
				return common.deleteSecret(acc).then(function (r) {
					if (!r || r.ok === false)
						throw new Error(_('删除账号 %s 的帐密失败').format(acc));
				});
			});
		});

		/* 串行而非并发：这些写的是同一个 /etc/campnet/.config，
		 * 并发写会互相覆盖。 */
		Object.keys(this.credWrites || {}).forEach(function (acc) {
			var w = self.credWrites[acc];
			chain = chain.then(function () {
				return common.setSecret(acc, w.username, w.password).then(function (r) {
					if (!r || r.ok === false)
						throw new Error(_('保存账号 %s 的帐密失败').format(acc));
				});
			});
		});

		return chain.then(function () {
			return uci.save();
		}).then(function () {
			self.credWrites = {};
			self.credDeletes = [];
		});
	},

	handleReset: function () {
		/* 基类默认同样是空操作（只遍历 .cbi-map），所以也自己来：
		 * 丢掉 uci 挂起变更 + 清空待写帐密。 */
		this.credWrites = {};
		this.credDeletes = [];
		ui.changes.revert();
	}
});
