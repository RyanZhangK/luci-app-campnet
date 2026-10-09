'use strict';
'require view';
'require rpc';
'require ui';

var getLog = rpc.declare({
	object: 'luci.campnet',
	method: 'getLog',
	params: [ 'lines' ]
});

var LINES = [ 100, 200, 300, 800 ];
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
		/* 不吞异常：调用失败时要能在页面上看见原因，否则和「日志为空」无法区分 */
		return getLog(200).then(function (r) { return r || {}; })
			.catch(function (e) { return { error: (e && e.message) || String(e) }; });
	},

	render: function (data) {
		var raw = data.log || '';
		var error = data.error;

		var pre = E('pre', { 'id': 'campnet-log-body', 'style': PRE_STYLE });

		var levelSel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' },
			LEVELS.map(function (lv) {
				return E('option', { 'value': lv }, [ lv === 'ALL' ? _('全部级别') : lv ]);
			}));

		var lineSel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' },
			LINES.map(function (n) {
				return E('option', { 'value': String(n), 'selected': (n === 200) ? 'selected' : null },
					[ n + ' 行' ]);
			}));

		function applyFilter() {
			if (error) { pre.textContent = _('读取日志失败：') + error; return; }
			var lv = levelSel.value;
			if (lv === 'ALL' || !raw) { pre.textContent = raw || _('（暂无日志）'); return; }
			var kept = raw.split('\n').filter(function (l) {
				if (!l) return false;
				/* 行格式: [时间] [LEVEL] 消息 —— 同时保留异常堆栈/续行 */
				return l.indexOf('[' + lv + ']') >= 0
					|| !/\[\d{4}-\d{2}-\d{2}/.test(l);
			});
			pre.textContent = kept.length ? kept.join('\n') : _('（该级别暂无日志）');
		}

		var refreshBtn = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ _('刷新') ]);
		refreshBtn.addEventListener('click', function (ev) {
			ev.preventDefault();
			refreshBtn.disabled = true;
			refreshBtn.textContent = _('刷新中…');
			getLog(parseInt(lineSel.value, 10) || 200).then(function (r) {
				raw = (r && r.log) || '';
				error = null;
				applyFilter();
			}).catch(function (e) {
				error = (e && e.message) || String(e);
				applyFilter();
			}).then(function () {
				refreshBtn.disabled = false;
				refreshBtn.textContent = _('刷新');
			});
		});

		/* 自动刷新：默认关（避免无谓的网络请求），需要盯日志时再开 */
		var autoChk = E('input', { 'type': 'checkbox', 'id': 'campnet-log-auto' });
		var timer = null;
		autoChk.addEventListener('change', function () {
			if (timer) { window.clearInterval(timer); timer = null; }
			if (autoChk.checked) {
				timer = window.setInterval(function () {
					if (document.hidden) return;      /* 后台标签页不刷 */
					refreshBtn.click();
				}, 5000);
			}
		});
		levelSel.addEventListener('change', applyFilter);

		applyFilter();

		return E('div', { 'class': 'cbi-section' }, [
			E('div', { 'style': 'margin:0 0 8px 0' }, [
				lineSel, ' ', levelSel, ' ',
				E('label', { 'style': 'margin:0 8px' }, [ autoChk, ' ', _('自动刷新') ]),
				refreshBtn
			]),
			pre
		]);
	},

	/* 只读页：必须显式关掉三个钩子，否则底部会多出没用的「保存并应用」 */
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
