'use strict';
'require view';
'require view.campnet.common as common';

var COUNTS = [ 100, 200, 300, 800 ];
var LEVELS = [ 'ALL', 'INFO', 'WARN', 'ERROR' ];

/* 日志区样式：一律不写死颜色。
 * 之前用 background:#f6f6f6，在 Argon 深色主题下文字是浅色 —— 浅底浅字，
 * 日志内容直接看不见。改用半透明灰罩 + color:inherit，深浅主题都成立。 */
var PRE_STYLE = [
	'white-space:pre-wrap',
	'word-break:break-all',
	'font-size:12px',
	'line-height:1.5',
	'max-height:65vh',
	'overflow:auto',
	'padding:10px',
	'margin:0',
	'border-radius:4px',
	'background:rgba(127,127,127,.12)',
	'color:inherit'
].join(';');

return view.extend({
	load: function () {
		/* 日志与线路列表一起取：线路下拉的选项来自后者。
		 * 任何一个失败都不该让整页变成错误 —— 日志失败时要看得见原因，
		 * 而线路列表失败只影响一个下拉。 */
		return Promise.all([
			common.getLog(200, '', '').then(function (r) { return r || {}; })
				.catch(function (e) { return { error: (e && e.message) || String(e) }; }),
			common.getStatus().then(function (r) { return r || {}; })
				.catch(function () { return {}; })
		]).then(function (r) {
			return { log: r[0], st: r[1] };
		});
	},

	render: function (data) {
		var logData = data.log || {};
		var st = data.st || {};

		if (logData.error)
			return common.errorCard(logData.error, function () { window.location.reload(); });

		var lines = st.lines || [];
		var raw = logData.log || '';
		var lastError = null;
		var busy = false;
		var stopPoll = null;

		var pre = E('pre', { 'id': 'campnet-log-body', 'style': PRE_STYLE });
		var captionEl = E('div', { 'class': 'cbi-section-descr', 'style': 'margin:0 0 6px 0' });
		var updatedEl = E('div', { 'class': 'cbi-section-descr', 'style': 'margin:6px 0 0 0' });

		/* ---- 三个下拉：**都在后端生效**，所以任何一个变化都要重新取数。
		 * 旧实现只有级别下拉绑了 change（而且是客户端过滤），行数下拉改了
		 * 必须再点一次「刷新」，同一排里两个控件行为不一致。 ---- */
		var countSel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' },
			COUNTS.map(function (n) {
				return E('option', { 'value': String(n), 'selected': (n === 200) ? 'selected' : null },
					[ n + ' 行' ]);
			}));

		var levelSel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' },
			LEVELS.map(function (lv) {
				return E('option', { 'value': lv }, [ lv === 'ALL' ? _('全部级别') : lv ]);
			}));

		var lineSel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' },
			[ E('option', { 'value': '' }, [ _('全部线路') ]) ].concat(
				lines.map(function (l) {
					return E('option', { 'value': l.id }, [ _('线路') + ': ' + l.id ]);
				})));

		var refreshBtn = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ _('刷新') ]);
		var autoChk = E('input', { 'type': 'checkbox', 'id': 'campnet-log-auto' });

		function val(sel) { return sel.options[sel.selectedIndex].value; }

		function applyContent() {
			var text = lastError ? '' : raw;
			if (lastError) {
				pre.textContent = _('读取日志失败：') + lastError;
			} else if (!text) {
				pre.textContent = _('（没有匹配的日志）');
			} else {
				/* 倒序渲染：最新在上。排查故障时人们想知道的是"刚才发生了什么"，
				 * 而原来正序渲染 + 每次刷新整体重建，屏幕最上方永远是这一段里
				 * 最旧的一行，自动刷新还会把滚动位置反复弹回顶部。 */
				var arr = text.split('\n').filter(function (l) { return l !== ''; });
				arr.reverse();
				pre.textContent = arr.join('\n');
			}

			var lv = val(levelSel), ln = val(lineSel);
			var scope = _('显示最近 %d 条匹配的日志').format(parseInt(val(countSel), 10));
			var cond = [];
			if (lv !== 'ALL') cond.push(lv);
			if (ln) cond.push(_('线路') + ' ' + ln);
			captionEl.textContent = cond.length
				? scope + '（' + cond.join(' / ') + '）' + _('，最新在最上。')
				: scope + _('，最新在最上。');

			updatedEl.textContent = _('最后更新') + ' ' + common.clockText();
		}

		function fetchLog() {
			if (busy) return Promise.resolve();
			busy = true;
			refreshBtn.disabled = true;
			refreshBtn.textContent = _('刷新中…');
			return common.getLog(parseInt(val(countSel), 10) || 200, val(levelSel), val(lineSel))
				.then(function (r) {
					raw = (r && r.log) || '';
					lastError = null;
				}).catch(function (e) {
					lastError = (e && e.message) || String(e);
				}).then(function () {
					busy = false;
					refreshBtn.disabled = false;
					refreshBtn.textContent = _('刷新');
					applyContent();
				});
		}

		refreshBtn.addEventListener('click', function (ev) { ev.preventDefault(); fetchLog(); });
		[ countSel, levelSel, lineSel ].forEach(function (s) {
			s.addEventListener('change', function () { fetchLog(); });
		});

		/* 自动刷新：默认关（避免无谓的网络请求），需要盯日志时再开。
		 * common.poll 自带"页面切走即停 + 后台标签页不请求"。 */
		autoChk.addEventListener('change', function () {
			if (stopPoll) { stopPoll(); stopPoll = null; }
			if (autoChk.checked)
				stopPoll = common.poll(fetchLog, 5000, pre);
		});

		applyContent();

		return E('div', { 'class': 'cbi-section' }, [
			E('div', { 'style': 'margin:0 0 6px 0' }, [
				countSel, ' ', levelSel, ' ', lineSel, ' ',
				E('label', { 'style': 'margin:0 8px' }, [ autoChk, ' ', _('自动刷新') ]),
				refreshBtn
			]),
			captionEl,
			pre,
			updatedEl
		]);
	},

	/* 只读页：必须显式关掉三个钩子，否则底部会多出没用的「保存并应用」 */
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
