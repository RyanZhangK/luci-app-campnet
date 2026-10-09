#!/bin/sh
# ============================================================
# status.sh —— 状态输出（被 campnet status 调用；JSON 依赖 jshn）
# 以**线路**为输出单位：一条线路可能是一个账号的一次会话。
# ============================================================

# 版本号统一由 lib.sh 的 camp_version() 提供（此前这里有一份重复实现，
# 两处行为还略有差异，容易改一处漏一处）

# 服务存活：keeper 进程数
_service_keepers() {
	pgrep -f '/usr/libexec/campnet/keeper.sh' 2>/dev/null | wc -l
}

# 状态文件里读一个键；缺失返回 unknown（供 UI 区分「未知」与「空」）
_line_state() {
	local v
	v=$(state_read "$1" "$2")
	[ -n "$v" ] && printf '%s' "$v" || printf 'unknown'
}

# 该账号是否已配置帐密（不打印凭据本身）
_cred_ok() {
	secret_read "$1" >/dev/null 2>&1 && echo 1 || echo 0
}

text_status() {
	local l acc iface dev ip st
	load_settings
	echo "=================================================="
	echo " luci-app-campnet 校园网认证状态    v$(camp_version)"
	echo "=================================================="
	echo " 启用      : $([ "$S_ENABLED" = "1" ] && echo 是 || echo 否)"
	echo " 认证模式  : $S_AUTH_MODE   (网关 $S_GATEWAY)"
	echo " 保活周期  : ${S_CHECK_INTERVAL}s  重试: ${S_MAX_RETRY}×${S_RETRY_DELAY}s"
	echo " 服务keeper: $(_service_keepers) 个进程"
	echo "--------------------------------------------------"
	local lines_n=0
	lines_n=$(camp_line_ids | grep -c .)
	[ "$lines_n" -gt 0 ] || echo "（尚未配置任何线路）"
	for l in $(camp_line_ids); do
		acc=$(line_account "$l"); [ -n "$acc" ] || acc="-"
		iface=$(line_iface "$l"); dev=$(iface_to_dev "$iface")
		ip=$(dev_ip "$dev")
		st=$(_line_state "$l" status)
		printf ' 线路[%-8s] %-13s %-15s 账号=%-8s 设备=%s\n' \
			"$l" "$st" "${ip:--}" "$acc" "$dev"
	done
	echo "--------------------------------------------------"
	echo " 最近日志 5 行:"
	tail -n 5 "$CAMP_LOG" 2>/dev/null | sed 's/^/  /' || true
}

json_status() {
	local HAVE_JSHN=0
	if [ -f /usr/share/libubox/jshn.sh ]; then
		. /usr/share/libubox/jshn.sh
		HAVE_JSHN=1
	fi
	load_settings
	local l acc iface dev ip st mac msg

	if [ "$HAVE_JSHN" != "1" ]; then
		printf '{"error":"jshn missing"}\n'
		return 0
	fi

	json_init
	json_add_object "settings"
		json_add_boolean "enabled" "$S_ENABLED"
		json_add_string "auth_mode" "$S_AUTH_MODE"
		json_add_string "gateway" "$S_GATEWAY"
		json_add_int "check_interval" "$S_CHECK_INTERVAL"
		json_add_int "max_retry" "$S_MAX_RETRY"
		json_add_int "retry_delay" "$S_RETRY_DELAY"
		json_add_string "uplink" "$S_UPLINK"
		json_add_boolean "dial_on_start" "$S_DIAL_ON_START"
	json_close_object

	json_add_string "version" "$(camp_version)"
	json_add_int "keepers" "$(_service_keepers)"

	# ---- 线路 ----
	# total/online 只统计**启用**的线路：停用是用户有意关掉的，
	# 把它算进分母会让状态页横幅永远显示"未全部在线" —— 一个假警报。
	# 停用的线路仍会出现在 lines[] 里（表格上标「已停用」），只是不计入分母。
	local online=0 total=0 nall=0 en
	json_add_array "lines"
	for l in $(camp_line_ids); do
		nall=$((nall + 1))
		acc=$(line_account "$l")
		iface=$(line_iface "$l"); dev=$(iface_to_dev "$iface")
		ip=$(dev_ip "$dev"); mac=$(dev_mac "$dev")
		st=$(_line_state "$l" status)
		msg=$(state_read "$l" msg)
		en=$(line_enabled "$l")
		if [ "$en" = "1" ]; then
			total=$((total + 1))
			[ "$st" = "authenticated" ] && online=$((online + 1))
		fi

		json_add_object ""
			json_add_string "id" "$l"
			json_add_boolean "enabled" "$en"
			json_add_string "account" "${acc:-}"
			json_add_string "type" "$(line_type "$l")"
			json_add_string "iface" "$iface"
			json_add_string "dev" "$dev"
			json_add_string "ip" "${ip:-}"
			json_add_string "mac" "${mac:-}"
			json_add_string "status" "$st"
			json_add_string "msg" "$(sanitize_msg "${msg:-}")"
			# 门户回传的实名信息（可能为空，UI 需降级显示）
			json_add_string "pname" "$(state_read "$l" pname)"
			json_add_string "puser" "$(state_read "$l" puser)"
			json_add_string "pgroup" "$(state_read "$l" pgroup)"
			json_add_string "pfee" "$(state_read "$l" pfee)"
		json_close_object
	done
	json_close_array

	# ---- 账号（身份）----
	local ids n cred uname_
	json_add_array "accounts"
	ids=$(camp_account_ids)
	for acc in $ids; do
		n=$(acct_line_count "$acc")
		# 凭据是否已配置，以及**用户名**（仅用于 UI 回填）。
		# 没有它，「只改密码」就要求用户把学号重新完整敲一遍 ——
		# 最常用的操作反而最容易失败。密码本身绝不外传。
		# secret_read 会把用户名/密码写进全局 USERNAME/PASSWORD，故不能放进 $( )。
		cred=0; uname_=""
		if secret_read "$acc" >/dev/null 2>&1; then
			cred=1; uname_="$USERNAME"
		fi
		json_add_object ""
			json_add_string "id" "$acc"
			json_add_boolean "enabled" "$(acct_enabled "$acc")"
			json_add_int "lines" "$n"
			json_add_boolean "has_credential" "$cred"
			json_add_string "username" "$uname_"
			# 该账号名下的线路（供 UI 表达归属关系）
			json_add_string "line_ids" "$(acct_line_ids "$acc" | tr '\n' ' ')"
		json_close_object
	done
	json_close_array

	# total/online = 仅启用线路；lines_all = 全部线路（含停用）。
	# 两者一起给出，UI 才能区分「一条线路都没配」和「配了但全停用了」。
	json_add_int "total" "$total"
	json_add_int "online" "$online"
	json_add_int "lines_all" "$nall"
	json_dump
}
