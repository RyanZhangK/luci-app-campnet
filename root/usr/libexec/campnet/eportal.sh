#!/bin/sh
# ============================================================
# eportal.sh —— Ruijie eportal（InterFace.do?method=login）登录
# 算法移植自调研：kanoverse《OpenWrt 校园网共享》引用的社区实现
# （eportal/index.jsp?<queryString> → 双 URL 编码 → POST 登录）。
# 适用于“纯网关 IP 门户”型校园网（如 10.0.1.51 自托管门户）。
# 被 run_login 以 auth_eportal 调用；调用方需已准备 S_*/USERNAME/PASSWORD/ACCOUNT/DEV。
# ============================================================

# 提取 eportal queryString
#
# 来源判定（实测）：queryString **不在**网关根页面里。
#   * GET http://<gw>/          → 302 到 /eportal/redirectortosuccess.jsp（正文空）
#   * GET <任意校外明文 HTTP>    → 被门户劫持，正文为
#       <script>top.self.location.href='http://<gw>/eportal/index.jsp?<queryString>'</script>
#   queryString 里 wlanuserip/mac/nasip 都是 NAS 按源 IP/MAC 现算的哈希，
#   与「哪个接口发起的请求」强绑定 —— 所以必须在目标接口上抓、当场用，不能复用。
_eportal_query_string() {
	local dev="$1" resp qs
	# 1) 权威来源：被劫持的外部明文 HTTP 响应
	resp=$(harvest_portal_response "$dev")
	qs=$(printf '%s' "$resp" | tr -d '\r' \
		| grep -o "eportal/index\.jsp?[^'\"]*" | head -1 | sed 's#^.*index\.jsp?##')
	[ -n "$qs" ] && { printf '%s' "$qs"; return 0; }
	# 2) 兜底：网关根的 302 Location（部分门户直接把 queryString 挂在 Location 上）
	resp=$(curl -si -m 8 --interface "$dev" --noproxy '*' "http://$S_GATEWAY/" 2>/dev/null)
	printf '%s' "$resp" | tr -d '\r' \
		| grep -o "eportal/index\.jsp?[^'\"]*" | head -1 | sed 's#^.*index\.jsp?##'
}

# ------------------------------------------------------------
# auth_eportal —— eportal 一键登录；成功返回 0
# ------------------------------------------------------------
auth_eportal() {
	local dev="$DEV" qs enc1 enc2 u_enc p_enc i post resp result msg _ip
	_ip=$(dev_ip "$dev")
	[ -n "$_ip" ] || { log ERROR "线路[${LINE:-$ACCOUNT}]（账号[$ACCOUNT]） 接口 $dev 无 IPv4，无法认证"; return 1; }

	log INFO "线路[${LINE:-$ACCOUNT}]（账号[$ACCOUNT]） eportal 模式登录 (gateway=$S_GATEWAY dev=$dev)"
	qs=$(_eportal_query_string "$dev")
	if [ -z "$qs" ]; then
		# 已在线时门户不再劫持，天然抓不到 queryString —— 这是成功态而非错误。
		if verify_internet "$dev"; then
			log INFO "线路[${LINE:-$ACCOUNT}]（账号[$ACCOUNT]） 接口 $dev 已在线，无需重复登录"
			return 0
		fi
		log WARN "线路[${LINE:-$ACCOUNT}]（账号[$ACCOUNT]） 未能取得 eportal queryString（未在线且无劫持，可能不在认证环境）"
		return 1
	fi
	log INFO "线路[${LINE:-$ACCOUNT}]（账号[$ACCOUNT]） 已取得 queryString(len=${#qs})"

	# 门户 JS 对所有字段一律 encodeURIComponent(encodeURIComponent(x))
	# （见 index_files/pc/login_bch.js 的 doauthen），故此处全部两次编码。
	enc1=$(urlencode "$qs")
	enc2=$(urlencode "$enc1")
	u_enc=$(urlencode "$(urlencode "$USERNAME")")
	p_enc=$(urlencode "$(urlencode "$PASSWORD")")

	post="userId=${u_enc}&password=${p_enc}&service="
	post="${post}&queryString=${enc2}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false"

	resp=$(curl -sS -m 15 --interface "$dev" --noproxy '*' \
		-X POST "http://$S_GATEWAY/eportal/InterFace.do?method=login" \
		-H "User-Agent: Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/68.0.3440.84 Safari/537.36" \
		-H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
		-H "Referer: http://$S_GATEWAY/eportal/index.jsp?${qs}" \
		--data "$post" 2>&1 || true)

	result=$(printf '%s' "$resp" | jsonfilter -e '@.result' 2>/dev/null)
	[ -n "$result" ] || result=$(printf '%s' "$resp" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	if [ "$result" = "success" ]; then
		log INFO "线路[${LINE:-$ACCOUNT}]（账号[$ACCOUNT]） eportal 登录成功"
		# 门户放行到真正能出网之间有短暂延迟，确认一下（失败不重试，交给下轮保活）
		i=0
		while [ "$i" -lt 3 ]; do
			verify_internet "$dev" && return 0
			i=$((i + 1)); sleep 1
		done
		log WARN "线路[${LINE:-$ACCOUNT}]（账号[$ACCOUNT]） 门户已返回成功但探针尚未通，等待下次保活复查"
		return 0
	fi
	msg=$(printf '%s' "$resp" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	log WARN "线路[${LINE:-$ACCOUNT}]（账号[$ACCOUNT]） eportal 登录失败(${result:-unknown}): ${msg:-$(redact "$resp")}"
	return 1
}

# ------------------------------------------------------------
# portal_info <dev> —— 取该线路上门户回传的实名信息
# 输出 state 文件用的 key=value（无换行），取不到返回 1。
# 只有 eportal 系门户提供；axe/webauth.do 系没有这个接口。
# ------------------------------------------------------------
portal_info() {
	local dev="$1" body
	body=$(curl -s -m 8 --interface "$dev" --noproxy '*' \
		"http://$S_GATEWAY/eportal/InterFace.do?method=getOnlineUserInfo" 2>/dev/null)
	[ -n "$body" ] || return 1
	case "$body" in *'"result":"success"'*) ;; *) return 1 ;; esac

	local _j
	_j() { printf '%s' "$body" | jsonfilter -e "@.$1" 2>/dev/null | tr -d '\n\r' | cut -c1-64; }

	printf 'pname=%s\n'  "$(_j userName)"
	printf 'puser=%s\n'  "$(_j userId)"
	printf 'pgroup=%s\n' "$(_j userGroup)"
	printf 'pfee=%s\n'   "$(_j accountFee)"
	printf 'pip=%s\n'    "$(_j userIp)"
	printf 'pmac=%s\n'   "$(_j userMac)"
}
