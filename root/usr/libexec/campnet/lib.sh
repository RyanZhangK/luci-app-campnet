#!/bin/sh
# ============================================================
# lib.sh —— campnet 公共函数库（POSIX sh / busybox-ash 兼容）
# 被 campnet CLI、keeper、init.d、dial.sh、status.sh、rpcd 等 source。
# 约定：所有脚本先调用 load_settings()，再使用 S_* 全局。
# ============================================================

CAMP_CONF=campnet                       # uci 配置名
CAMP_DIR=/etc/campnet                   # 运行时目录（帐密等）
CAMP_SECRET="$CAMP_DIR/.config"         # 帐密文件（0600，绝不入 Git）
CAMP_SECRET_DEFAULT="$CAMP_DIR/.config.default"  # 打包默认模板
CAMP_CREATED="$CAMP_DIR/.created"       # dial.sh 登记已创建资源
CAMP_STATE_DIR=/var/run/campnet         # 每账号状态
CAMP_LOG_DIR=/var/log/campnet
CAMP_LOG="$CAMP_LOG_DIR/campnet.log"
CAMP_LOCK_DIR=/tmp/campnet-lock
CAMP_PREFIX=campnet
MAX_LOG_LINES=800
TRIM_LOG_LINES=500
COOKIE_PREFIX=/tmp/campnet-cookie
CAMP_TMP_DIR=/tmp/campnet-tmp         # 存放含凭据的临时文件（0700）

# ------------------------------------------------------------
# 基础工具
# ------------------------------------------------------------
# 末尾的 `|| true` 不能省：调用方常写成 `x=$(uciq ...)`，若 uci 读不到
# （配置项不存在、或环境里根本没有 uci），命令替换返回非 0；在调用方开了
# `set -e` 的场景（自测脚本等）会直接把整个函数截断，表现为"静默返回空"。
uciq() { uci -q get "$1" 2>/dev/null || true; }

# 取整数值并带默认（非法/空 → 默认）
uciqn() {
	local v
	v=$(uciq "$1")
	case "$v" in
		''|*[!0-9]*) echo "${2:-0}" ;;
		*) echo "$v" ;;
	esac
}

# 建一个私有临时文件。mkdtemp 语义：目录 0700、文件 0600（mktemp 默认）。
# 用来承载含账号密码的请求体 —— 直接写 /tmp/xxx 会按 umask 落成 0644。
camp_tmpfile() { # [前缀]
	mkdir -p "$CAMP_TMP_DIR" 2>/dev/null && chmod 700 "$CAMP_TMP_DIR" 2>/dev/null
	mktemp "$CAMP_TMP_DIR/${1:-tmp}.XXXXXX" 2>/dev/null
}

# 稳定短哈希（默认 8 位十六进制）。
# 纯 awk 实现，不依赖 cksum/od/xxd —— 精简固件常常一个都没有。
# 必须按**字节**取值：若按字母表索引，'-' '.' '_' 都会算成 0，
# 于是 line-2 / line_2 / line.2 三个不同的 uci 段会得到同一个哈希
# ——那正是要避免的撞名。LC_ALL=C 保证 gawk 也走字节语义。
#
# 模数必须 < 2^31：busybox awk 的 printf "%08x" 对 >= 2^31 的值会**钳到
# 7fffffff**（实测），用 2^32 取模会让一半以上的名字撞成同一个哈希。
hash_str() { # <字符串> [位数=8]
	S="$1" N="${2:-8}" LC_ALL=C awk 'BEGIN {
		for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i
		s = ENVIRON["S"]
		h = 0
		for (i = 1; i <= length(s); i++)
			h = (h * 131 + ord[substr(s, i, 1)]) % 2147483647
		printf "%s", substr(sprintf("%08x", h), 1, ENVIRON["N"] + 0)
	}'
}

# 取整数并钳制下限。ciqn 把 "0" 当成合法值，于是 check_interval=0 会让
# keeper 忙循环（nap 0 立刻返回）、retry_delay=0 会让认证失败后无间隔连打
# 三次（校园网很容易因此风控/锁号）、poll_interval=0 会变成 20 次无间隔轮询。
uciqmin() { # <key> <默认> <最小值>
	local v
	v=$(uciqn "$1" "$2")
	[ "$v" -ge "$3" ] 2>/dev/null || v="$3"
	printf '%s' "$v"
}

# 日志：写文件（行数轮转）+ 诊断输出
# 诊断必须走 **stderr**：本文件里多处形如 `mac=$(_acct_mac "$acc")` 的命令替换，
# 若 log() 写 stdout，被替换函数内部的提示会被一并捕获进变量值，污染返回值
# （实测会把 "[WARN] ... " 拼进 MAC）。stdout 只留给真正的数据。
log() {
	local lvl="$1" msg="$2" ts
	# 每步都要兜住失败：log 绝不能返回非 0，否则在调用方开了 `set -e`
	# 的场景（如自测脚本）会把调用方整个干掉。
	mkdir -p "$CAMP_LOG_DIR" 2>/dev/null || true
	if [ -f "$CAMP_LOG" ] && [ "$(wc -l < "$CAMP_LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_LINES" ]; then
		tail -n "$TRIM_LOG_LINES" "$CAMP_LOG" > "$CAMP_LOG.tmp" 2>/dev/null \
			&& mv "$CAMP_LOG.tmp" "$CAMP_LOG" 2>/dev/null
	fi
	ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
	printf '[%s] [%s] %s\n' "$ts" "$lvl" "$msg" >> "$CAMP_LOG" 2>/dev/null || true
	# 只在交互式终端回显：init.d 把 stderr 收进 syslog，无条件回显会让
	# 每条日志在 syslog 里再出现一遍（双写）。
	[ -t 2 ] && printf '[%s] %s\n' "$lvl" "$msg" >&2
	return 0
}

# 日志脱敏：避免把 帐号/密码/queryString/mac/distoken/wlanuserip 打进日志
redact() {
	printf '%s' "$1" | sed \
		-e 's/passwd=[^& ]*/passwd=***/g' \
		-e 's/password=[^& ]*/password=***/g' \
		-e 's/userId=[^& ]*/userId=***/g' \
		-e 's/username=[^& ]*/username=***/g' \
		-e 's/queryString=[^& ]*/queryString=***/g' \
		-e 's/mac=[^& ]*/mac=***/g' \
		-e 's/wlanuserip=[^& ]*/wlanuserip=***/g' \
		-e 's/distoken=[^& ]*/distoken=***/g' \
		| cut -c1-400
}

# URL 编码（RFC3986 unreserved 集合：A-Za-z0-9-_.~）
#
# 用**单个 awk 进程**按字节编码。旧实现每字符 fork 一次 cut+printf，
# 一个 268 字符的 queryString 编码两次要 **~1.8 秒**（ipq807x 实测）；
# 而 eportal 登录正需要对 queryString 做双重编码 —— 光编码就吃掉了
# curl 超时余量，还会拖垮 ubus 调用。现在单次 ~50ms（36 倍）。
#
# 必须**按字节**遍历：ASCII 凭据无感，但用户名/密码含中文时得按 UTF-8
# 字节逐个编码（'中' → %E4%B8%AD），按码点编码是错的。
# busybox awk 的 length()/substr() 都是字节语义（实测 length("中")==3）。
#
# 用 ENVIRON 传参而不是管道：管道会把值里的换行当记录分隔符，
# 导致换行之后的内容被静默丢弃。
#
# LC_ALL=C 不能省：GNU awk 在多字节 locale 下是**按字符**的（本地开发机
# 就是 gawk），会把 '中' 编成 1 个码点而不是 3 个 UTF-8 字节。
# 加 LC_ALL=C 后 gawk 也切回字节语义，两个平台结果一致。
urlencode() {
	S="$1" LC_ALL=C awk 'BEGIN {
		for (i = 1; i < 256; i++) byte[sprintf("%c", i)] = i
		safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
		s = ENVIRON["S"]
		n = length(s)
		out = ""
		for (i = 1; i <= n; i++) {
			c = substr(s, i, 1)
			if (index(safe, c) > 0) out = out c
			else out = out sprintf("%%%02X", byte[c])
		}
		printf "%s", out
	}'
}

# ------------------------------------------------------------
# 配置加载（uci campnet.settings）
# ------------------------------------------------------------
load_settings() {
	S_ENABLED=$(uciqn campnet.settings.enabled 1)
	S_AUTH_MODE=$(uciq campnet.settings.auth_mode);          S_AUTH_MODE=${S_AUTH_MODE:-auto}
	S_GATEWAY=$(uciq campnet.settings.gateway);              S_GATEWAY=${S_GATEWAY:-10.0.1.51}
	S_PROBE_URL=$(uciq campnet.settings.probe_url);          S_PROBE_URL=${S_PROBE_URL:-http://connect.rom.miui.com/generate_204}
	S_CHECK_INTERVAL=$(uciqmin campnet.settings.check_interval 60 5)
	S_MAX_RETRY=$(uciqmin campnet.settings.max_retry 3 1)
	S_RETRY_DELAY=$(uciqmin campnet.settings.retry_delay 5 1)
	S_POLL_MAX=$(uciqn campnet.settings.poll_max 20)
	S_POLL_INTERVAL=$(uciqmin campnet.settings.poll_interval 2 1)
	S_UPLINK=$(uciq campnet.settings.uplink);                S_UPLINK=${S_UPLINK:-auto}
	S_DIAL_ON_START=$(uciqn campnet.settings.dial_on_start 1)
	S_WLANACNAME=$(uciq campnet.settings.wlanacname);        S_WLANACNAME=${S_WLANACNAME:-BRAS}
	S_PAGEID=$(uciqn campnet.settings.pageid 5)
	S_TEMPLATETYPE=$(uciqn campnet.settings.templatetype 1)
	S_VLAN=$(uciqn campnet.settings.vlan 0)
	S_AUTH_TYPE=$(uciqn campnet.settings.auth_type 0)
	# 可选：独立认证域名 / 服务器 IP（用于 --resolve 绕过 DNS）
	S_AUTH_HOST=$(uciq campnet.settings.auth_host)
	S_SERVER_IP=$(uciq campnet.settings.server_ip)
	S_CTMO=$(uciqn campnet.settings.curl_connect_timeout 5)
	S_TMO=$(uciqn campnet.settings.curl_timeout 12)
	# 多播均衡兜底：若 settings 中没启用但存在 ≥2 个启用账号，也按 1 处理（见 dial.sh）
	[ "$S_ENABLED" = "1" ] || S_ENABLED=0
}

# ------------------------------------------------------------
# 账号（身份）与线路（会话）
#
# 模型：account 只描述「身份」（凭据 + 是否启用）；line 才是实体，
# 一条 line = 一条独立认证会话 = 一个 procd keeper 实例 = 一份状态文件。
# line 必须绑定一个 account；账号名下的线路数**不设上限** ——
# 校园网侧对同账号并发会话通常有限制，但那应该由门户拒绝并在日志里看得见，
# 而不是由插件在前端拦下来（v1.0.x 的每账号 2 条上限已移除）。
# ------------------------------------------------------------

_uci_sections() { # <类型>
	uci show campnet 2>/dev/null | grep -E "^campnet\.[^=]+=$1$" \
		| sed -E 's/^campnet\.//; s/='"$1"'$//'
}

camp_account_ids() { _uci_sections account; }
camp_line_ids()    { _uci_sections line; }

acct_opt()     { uciq "campnet.$1.$2"; }
acct_exists()  { [ -n "$(uciq "campnet.$1")" ]; }

# 段**不存在**时返回 0（停用），而不是 uciqn 的默认值 1。
# 这个默认值曾是个静默失败：删掉账号后，其名下线路在 run_login / keeper 里
# 仍被当作「账号已启用」而继续认证 —— 带着 .config 里可能残留的凭据。
# 孤儿线路必须显式判为停用，后面由 keeper 自然不再拉起。
acct_enabled() {
	acct_exists "$1" || { echo 0; return 0; }
	uciqn "campnet.$1.enabled" 1
}

line_opt()     { uciq "campnet.$1.$2"; }
line_enabled() { uciqn "campnet.$1.enabled" 1; }
line_account() { line_opt "$1" account; }
# 线路类型：wan=复用已有网络接口；macvlan=自建独立设备
line_type() {
	local t
	t=$(line_opt "$1" type)
	echo "${t:-macvlan}"
}

# 线路生效的 uci network 接口名
line_iface() {
	case "$(line_type "$1")" in
		wan|physical|'') line_opt "$1" iface | { read -r v; echo "${v:-wan}"; } ;;
		*) dev_name_for "$1" ;;
	esac
}

# 线路绑定的内核设备名
line_dev() { iface_to_dev "$(line_iface "$1")"; }

# 某账号名下的线路（含未启用的）
acct_line_ids() {
	local l
	for l in $(camp_line_ids); do
		[ "$(line_account "$l")" = "$1" ] && echo "$l"
	done
}
acct_line_count() { acct_line_count_all "$1"; }
# 该账号名下线路总数（含未启用）。LuCI 的 GridSection 是直接写 uci 的，
# 绕过 CLI 的校验，所以运行期必须自己能查出超额并拒绝。
acct_line_count_all() { acct_line_ids "$1" | grep -c . ; }

# 多播命名助手（与 dial.sh 共用；确定性）
#
# 长度预算被 mwan3 卡死，不能随意放大：
#   * iptables/nft 链名上限 28 字符；mwan3 为每个接口建 `mwan3_iface_in_<iface>`
#     （前缀 15）→ 接口名必须 <=13 字符；
#   * mwan3 策略名上限 15 字符（`mwan3_policy_<name>` 同理受限）。
# 因此接口名 = "campnet_"(8) + 基名 <=13 → 基名只能 5 位。
# 超出不会报错，只会让 mwan3 静默丢弃策略/接口，均衡完全不生效（实测踩过）。
#
# **不能简单截断**：截前 5 位会让 202524104130 与 202524104131 都变成
# campnet_20252 —— 两个账号共用同一条线路，第二个静默失效。
# 所以超过 5 位时改用「前 2 位 + 3 位哈希」（4096 桶，稳定且区分度够）。
# 首次 dial 会把结果固化进 uci campnet.<id>.ifbase，之后 dial/keeper/status
# 都读它，保证三处看到同一个名字。
base_of() {
	local id stored h
	id=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]//g')
	[ -n "$id" ] || id=acc

	stored=$(uciq "campnet.$1.ifbase" 2>/dev/null)
	case "$stored" in
		''|*[!A-Za-z0-9]*) ;;
		*) [ "${#stored}" -le 5 ] && { printf '%s' "$stored"; return; } ;;
	esac

	if [ "${#id}" -le 5 ]; then
		printf '%s' "$id"
		return
	fi

	h=$(printf '%s' "$id" | awk '{
		h = 0
		for (i = 1; i <= length($0); i++)
			h = (h * 131 + index("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ", toupper(substr($0, i, 1)))) % 4096
		printf "%03x", h
	}' 2>/dev/null || true)
	[ -n "$h" ] || h=000
	printf '%s%s' "$(printf '%s' "$id" | cut -c1-2)" "$h"
}
# 内核设备名 / uci network 接口 id（<=13 字节，见上）
dev_name_for() { echo "campnet_$(base_of "$1")"; }
# netifd device 段 id（与接口段区分）
devsec_for() { echo "campd_$(base_of "$1")"; }

# ------------------------------------------------------------
# 旧模型一次性迁移
#
# v0.x：account 段里带 create_vlan/iface/macaddr/metric/weight —— 一个账号就是一条线路。
# v1.x：account 只管身份，线路搬到独立的 line 段。这里做 1:1 转换，
#       线路名沿用账号名，因此 macvlan 设备名（campnet_<base>）与
#       uci 里的 ifbase 键（campnet.<id>.ifbase）都不变，认证不受影响。
# ------------------------------------------------------------
camp_migrate_legacy() {
	local acc l old=0 ob

	[ -n "$(camp_line_ids)" ] && return 0     # 已有 line 段 → 迁移过了
	for acc in $(camp_account_ids); do
		[ -n "$(acct_opt "$acc" create_vlan)" ] && old=1
	done
	[ "$old" = "1" ] || return 0

	for acc in $(camp_account_ids); do
		# 线路名必须与账号名不同！uci 的 section id 是全局唯一的，
		# 直接用账号名当线路名会把账号段**整个覆盖掉**（实测踩过）。
		l="line_$acc"
		uci -q set "campnet.$l=line"
		uci -q set "campnet.$l.enabled=$(acct_enabled "$acc")"
		uci -q set "campnet.$l.account=$acc"
		uci -q set "campnet.$l.iface=$(acct_opt "$acc" iface)"
		if [ "$(uciqn "campnet.$acc.create_vlan" 0)" = "1" ]; then
			uci -q set "campnet.$l.type=macvlan"
			uci -q set "campnet.$l.macaddr=$(acct_opt "$acc" macaddr)"
			uci -q set "campnet.$l.metric=$(uciqn "campnet.$acc.metric" 10)"
			uci -q set "campnet.$l.weight=$(uciqn "campnet.$acc.weight" 10)"
			uci -q set "campnet.$l.route_metric=$(uciqn "campnet.$acc.route_metric" 20)"
			# 把旧的短名搬到线路段上，这样 macvlan 设备名（campnet_<base>）
			# 与 mwan3 里已有的接口名都不变，认证与均衡不受影响。
			ob=$(acct_opt "$acc" ifbase)
			[ -n "$ob" ] || ob=$(base_of "$acc")
			[ -n "$ob" ] && uci -q set "campnet.$l.ifbase=$ob"
		else
			uci -q set "campnet.$l.type=wan"
		fi
		# 账号段只剩「身份」：清掉线路属性（enabled 保留）
		for o in create_vlan iface macaddr metric weight route_metric ifbase; do
			uci -q delete "campnet.$acc.$o" 2>/dev/null
		done
		log INFO "campnet: 账号[$acc] 的线路已迁移为 [$l]"
	done
	uci -q commit campnet 2>/dev/null
	log INFO "campnet: 旧配置迁移完成（账号与线路已解耦）"
	return 0
}

# uci network 接口 → 内核设备名（23.05 device / 旧 ifname 兼容）
iface_to_dev() {
	local d
	d=$(uciq "network.$1.device")
	[ -z "$d" ] && d=$(uciq "network.$1.ifname")
	[ -z "$d" ] && d="$1"
	echo "$d"
}

# ------------------------------------------------------------
# 帐密：/etc/campnet/.config（0600）
# 分节：main 账号 → [default]；其余账号 → [account:<id>]
# ------------------------------------------------------------
_secret_section() {  # account → 对应分节名
	case "${1:-main}" in
		''|main) echo "default" ;;
		*) echo "account:$1" ;;
	esac
}

# secret_read <account> → 设置全局 USERNAME / PASSWORD；成功返回 0
secret_read() {
	USERNAME=""; PASSWORD=""
	local acc="${1:-main}" want sec out u p
	want=$(_secret_section "$acc")
	[ -f "$CAMP_SECRET" ] || return 1
	out=$(awk -v want="$want" '
		function unq(s) {
			if (length(s) >= 2 && ((substr(s,1,1)=="\"" && substr(s,length(s),1)=="\"") || \
			    (substr(s,1,1)=="\x27" && substr(s,length(s),1)=="\x27")))
				return substr(s,2,length(s)-2)
			return s
		}
		/^[[:space:]]*\[/ {
			sec=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
			if (sec==want) cur=1; else cur=0
			next
		}
		cur==1 && /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=/ {
			k=$0; sub(/^[[:space:]]*/,"",k); sub(/=[^=]*$/,"",k); gsub(/[[:space:]]/,"",k)
			v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/[[:space:]]*$/,"",v)
			if (k=="username") u=unq(v)
			else if (k=="password") p=unq(v)
		}
		END { if (u!="" || p!="") printf "U=%s\nP=%s\n", u, p }
	' "$CAMP_SECRET")
	USERNAME=$(printf '%s\n' "$out" | sed -n 's/^U=//p' | head -1)
	PASSWORD=$(printf '%s\n' "$out" | sed -n 's/^P=//p' | head -1)
	[ -n "$USERNAME" ] && [ -n "$PASSWORD" ]
}

# secret_write <account> <username> <password> —— 原子重写（0600）
# 规则：[default] 存 main；其它存 [account:<id>]。只覆盖目标分节，保留其它分节。
secret_write() {
	local acc="${1:-main}" user="$2" pass="$3" want
	want=$(_secret_section "$acc")
	mkdir -p "$CAMP_DIR" 2>/dev/null || return 1
	# 先收紧 umask 再重定向：早期实现是先按默认 umask(022) 建出
	# 0644 的临时文件、后面才 chmod 600 —— 明文密码在这两步之间可被读走。
	local om; om=$(umask)
	umask 077
	{
		printf '# campnet 帐密 —— 请通过 LuCI/CLI 修改，勿直接编辑\n'
		printf '# [default] = 主账号(main)；[account:<id>] = 附加账号\n'
		if [ "$want" = "default" ]; then
			printf '\n[default]\nusername=%s\npassword=%s\n' "$user" "$pass"
			# 保留其它 [account:*] 分节。
			# 必须写成 if/fi —— 若写作 `[ -f x ] && awk ...`，在文件尚不存在
			# （首次配置）时该复合命令返回 1，整个 `{...} > file` 组随之返回 1，
			# 触发下面的 `|| return 1`，导致「首次保存 main 帐密必然失败」。
			if [ -f "$CAMP_SECRET" ]; then
				awk '
					BEGIN { skip=0; started=0 }
					/^[[:space:]]*\[/ {
						sec=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
						if (sec=="default") { skip=1; next }
						skip=0
						if (started) print ""; started=1
					}
					skip==0 && !/^[[:space:]]*#/ && !/^[[:space:]]*$/ { print }
				' "$CAMP_SECRET"
			fi
		else
			# 保留旧文件（跳过目标分节与注释；[default] 一并保留）
			if [ -f "$CAMP_SECRET" ]; then
				awk -v want="$want" '
					BEGIN { skip=0; started=0 }
					/^[[:space:]]*\[/ {
						sec=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
						if (sec==want) { skip=1; next }
						skip=0
						if (started) print ""; started=1
					}
					skip==0 && !/^[[:space:]]*#/ && !/^[[:space:]]*$/ { print }
				' "$CAMP_SECRET"
			else
				printf '\n[default]\nusername=\npassword=\n'
			fi
			printf '\n[%s]\nusername=%s\npassword=%s\n' "$want" "$user" "$pass"
		fi
	} > "$CAMP_SECRET.tmp" 2>/dev/null || { umask "$om"; return 1; }
	umask "$om"
	chmod 600 "$CAMP_SECRET.tmp"
	mv "$CAMP_SECRET.tmp" "$CAMP_SECRET" || return 1
	chmod 600 "$CAMP_SECRET"
	return 0
}

# secret_delete <account> —— 删除该账号的凭据分节（删号时必须调用，
# 否则明文密码会永远留在 /etc/campnet/.config 里）
secret_delete() {
	local acc="${1:-main}" want
	want=$(_secret_section "$acc")
	[ -f "$CAMP_SECRET" ] || return 0
	awk -v want="$want" '
		/^[[:space:]]*\[/ {
			sec=$0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec)
			if (sec==want) { skip=1; next }
			skip=0
			if (started) print ""; started=1
		}
		skip==0 && !/^[[:space:]]*#/ && !/^[[:space:]]*$/ { print }
	' "$CAMP_SECRET" > "$CAMP_SECRET.tmp" 2>/dev/null || return 1
	chmod 600 "$CAMP_SECRET.tmp" 2>/dev/null
	mv "$CAMP_SECRET.tmp" "$CAMP_SECRET" 2>/dev/null || return 1
	chmod 600 "$CAMP_SECRET" 2>/dev/null
	return 0
}

# 种子化：无则用打包模板/内置默认生成
secret_seed() {
	mkdir -p "$CAMP_DIR" 2>/dev/null
	[ -f "$CAMP_SECRET" ] && { chmod 600 "$CAMP_SECRET" 2>/dev/null; return 0; }
	local om; om=$(umask); umask 077
	if [ -f "$CAMP_SECRET_DEFAULT" ]; then
		cp "$CAMP_SECRET_DEFAULT" "$CAMP_SECRET" 2>/dev/null || { umask "$om"; return 1; }
	else
		# 内置兜底同样不带真实凭据：种子出来的是空模板，
		# secret_read 会因 username/password 为空而判定「未配置」。
		cat > "$CAMP_SECRET" <<-EOF
			[default]
			username=
			password=
		EOF
	fi
	umask "$om"
	chmod 600 "$CAMP_SECRET" 2>/dev/null
	return 0
}

# ------------------------------------------------------------
# 网络探测（dev = 内核设备名）
# ------------------------------------------------------------
dev_has_ip() { ip -4 addr show dev "$1" 2>/dev/null | grep -q ' inet '; }

dev_ip() {
	ip -4 addr show dev "$1" 2>/dev/null | awk '/ inet /{ sub(/\/.*/, "", $2); print $2; exit }'
}

dev_mac() {
	cat "/sys/class/net/$1/address" 2>/dev/null | tr 'a-f' 'A-F'
}

dev_default_gw() {
	ip -4 route show dev "$1" 2>/dev/null | awk '$1=="default" { print $3; exit }'
}

# probe_online <dev>：0=在线(204)；1=需要认证(被劫持/门户)；2=离线/网关不可达
probe_online() {
	local dev="$1" code gcode
	code=$(curl -s -o /dev/null -w '%{http_code}' --interface "$dev" \
		--connect-timeout "${S_CTMO:-3}" --max-time "${S_TMO:-5}" --noproxy '*' \
		"$S_PROBE_URL" 2>/dev/null)
	case "$code" in
		204) return 0 ;;
		200|301|302|303|307|308) return 1 ;;
	esac
	# 探针未果 → 看门户网关是否可达（区分 需认证 / 真离线）
	gcode=$(curl -s -o /dev/null -w '%{http_code}' --interface "$dev" \
		--connect-timeout 3 --max-time 5 --noproxy '*' "http://$S_GATEWAY/" 2>/dev/null)
	case "$gcode" in
		200|301|302|303|307|308) return 1 ;;
	esac
	return 2
}

# probe_status <dev> → stdout: no_ip|authenticated|need_auth|offline
# 注意：必须先用普通命令取回码再判断。写成 `if probe_online; then ...; fi`
# 后在 fi 之后取 $? 恒为 0（POSIX: if 无 else 分支且条件为假时返回 0），
# 会把 need_auth 误判成 offline。
probe_status() {
	local dev="$1" rc
	dev_has_ip "$dev" || { echo no_ip; return; }
	probe_online "$dev"
	rc=$?
	[ "$rc" -eq 0 ] && { echo authenticated; return; }
	[ "$rc" -eq 1 ] && { echo need_auth; return; }
	echo offline
}

# 在线硬校验（认证后使用）：204 或 ping 通 223.5.5.5
verify_internet() {
	local dev="$1"
	if probe_online "$dev"; then return 0; fi
	ping -c 1 -W 2 -I "$dev" ${S_TRACK_IP1:-223.5.5.5} >/dev/null 2>&1 && return 0
	return 1
}

# ------------------------------------------------------------
# 锁（mkdir 原子 + 过期回收）
# ------------------------------------------------------------
lock_get() {
	local name="$1" lk i ts
	mkdir -p "$CAMP_LOCK_DIR" 2>/dev/null || return 1
	lk="$CAMP_LOCK_DIR/$name"
	i=0
	while ! mkdir "$lk" 2>/dev/null; do
		if [ -d "$lk" ]; then
			ts=$(stat -c %Y "$lk" 2>/dev/null || echo 0)
			[ "$(( $(date +%s) - ts ))" -gt 300 ] && rmdir "$lk" 2>/dev/null
		fi
		i=$((i + 1))
		# 单次认证最坏可达 max_retry × (curl 30s + 拨号轮询)，量级是分钟级。
		# 原来 100×0.2s=20s 的上限太短，并发 keeper 会拿到 return 3 后静默跳过。
		[ "$i" -gt 900 ] && return 1
		sleep 0.2
	done
	return 0
}

lock_release() {
	rmdir "$CAMP_LOCK_DIR/$1" 2>/dev/null
	return 0
}

# ------------------------------------------------------------
# 状态缓存（每账号 /var/run/campnet/<account>.state，供 UI/status）
# ------------------------------------------------------------
state_write() {
	local acc="$1" f t
	shift
	mkdir -p "$CAMP_STATE_DIR" 2>/dev/null || return 1
	f="$CAMP_STATE_DIR/$acc.state"
	t=$(mktemp "$f.XXXXXX" 2>/dev/null) || return 1
	printf 'ts=%s\n' "$(date +%s)" > "$t"
	while [ "$#" -ge 2 ]; do
		printf '%s=%s\n' "$1" "$2"
		shift 2
	done >> "$t"
	mv "$t" "$f"
	return 0
}

state_read() {
	[ -f "$CAMP_STATE_DIR/$1.state" ] \
		&& sed -n "s/^$2=//p" "$CAMP_STATE_DIR/$1.state" 2>/dev/null | head -1
}

sanitize_msg() { printf '%s' "$1" | tr '\n\r' '  ' | cut -c1-200; }

# ------------------------------------------------------------
# 认证入口 run_login（由 keeper/CLI 调用；需已 source ruijie.sh/eportal.sh）
# 参数是**线路**（不是账号）：一条线路 = 一次独立认证会话。
# 路线 → 账号（取凭据）由 line_account() 解析。
# 返回：0=成功在线 1=失败 2=接口未就绪 3=锁占用
# ------------------------------------------------------------
run_login() {
	local line="$1" force="$2" acc iface dev tried ok
	load_settings
	[ "$S_ENABLED" = "1" ] || { log WARN "插件已停用(enabled=0)，跳过线路[$line]"; return 0; }
	[ "$(line_enabled "$line")" = "1" ] || { log INFO "线路[$line] 未启用，跳过"; return 0; }

	acc=$(line_account "$line")
	if [ -z "$acc" ]; then
		state_write "$line" status error msg "线路未绑定账号"
		log ERROR "线路[$line] 未绑定账号，请在设置页指定"
		return 1
	fi
	[ "$(acct_enabled "$acc")" = "1" ] || { log INFO "线路[$line] 的账号[$acc] 已停用，跳过"; return 0; }

	iface=$(line_iface "$line")
	dev=$(iface_to_dev "$iface")
	ACCOUNT="$acc"; LINE="$line"; DEV="$dev"

	# 已在线且非强制 → 直接成功
	[ "$force" = "--force" ] || {
		if probe_status "$dev" | grep -q authenticated; then
			state_write "$line" status authenticated ip "$(dev_ip "$dev")" mac "$(dev_mac "$dev")" \
				dev "$dev" account "$acc" msg "已在线"
			return 0
		fi
	}

	secret_read "$acc" || {
		state_write "$line" status error ip "$(dev_ip "$dev")" dev "$dev" account "$acc" \
			msg "账号[$acc] 缺少帐密"
		log ERROR "线路[$line]（账号[$acc]）缺少帐密，请先在设置页配置"
		return 1
	}

	if ! dev_has_ip "$dev"; then
		state_write "$line" status no_ip dev "$dev" account "$acc" msg "接口 $iface($dev) 暂无 IPv4"
		log WARN "线路[$line] 接口 $dev 无 IP，等待 DHCP"
		return 2
	fi

	lock_get "login-$line" || {
		log WARN "线路[$line] 已有认证在进行，跳过"
		return 3
	}

	state_write "$line" status authing ip "$(dev_ip "$dev")" mac "$(dev_mac "$dev")" \
		dev "$dev" account "$acc" msg "认证中…"
	tried=0; ok=0
	while [ "$tried" -lt "$S_MAX_RETRY" ]; do
		tried=$((tried + 1))
		[ "$tried" -gt 1 ] && log INFO "线路[$line] 第 $tried 次尝试"
		case "$S_AUTH_MODE" in
			eportal) auth_eportal && ok=1 ;;
			auto)
				# auto：先按页面特征探测门户类型，再回退尝试
				if detect_portal_type "$dev" | grep -q eportal; then
					{ auth_eportal || auth_ruijie; } && ok=1
				else
					{ auth_ruijie || auth_eportal; } && ok=1
				fi
				;;
			*) auth_ruijie && ok=1 ;;
		esac
		[ "$ok" -eq 1 ] && break
		[ "$tried" -lt "$S_MAX_RETRY" ] && sleep "$S_RETRY_DELAY"
	done

	lock_release "login-$line"

	if [ "$ok" -eq 1 ]; then
		state_write "$line" status authenticated ip "$(dev_ip "$dev")" mac "$(dev_mac "$dev")" \
			dev "$dev" account "$acc" msg "登录成功（第 ${tried} 次）"
		log INFO "线路[$line]（账号[$acc]）认证成功 (接口 $iface/$dev)"
		return 0
	fi
	state_write "$line" status error ip "$(dev_ip "$dev")" mac "$(dev_mac "$dev")" \
		dev "$dev" account "$acc" msg "认证失败（重试 ${S_MAX_RETRY} 次）"
	log ERROR "线路[$line]（账号[$acc]）认证失败（接口 $dev）"
	return 1
}

# ------------------------------------------------------------
# 门户劫持抓取
# ------------------------------------------------------------
# 未认证时，门户（NAS）会把对外部的**明文 HTTP** 请求替换成一段跳转脚本
# （形如 top.self.location.href='http://<gw>/eportal/index.jsp?<queryString>'），
# 或被 302 到门户页。这个被劫持的响应才是 queryString / 门户类型的唯一可靠来源。
#
# 反例（实测肇庆学院 Ruijie eportal）：直接 GET http://<gw>/ 只会 302 到
# /eportal/redirectortosuccess.jsp，正文为空——**拿不到任何 queryString**，
# 所以不能只探网关根。
#
# 输出：被劫持后的完整响应（含响应头，便于匹配 Location）。无劫持时输出原始正文。
CAMP_HIJACK_URL="http://connect.rom.miui.com/generate_204"

harvest_portal_response() {
	local dev="$1" url body
	url="$S_PROBE_URL"
	case "$url" in
		http://*) ;;
		*) url="$CAMP_HIJACK_URL" ;;   # 探针若是 https 则不会被劫持，改用明文探针
	esac
	body=$(curl -si -m 8 --interface "$dev" --noproxy '*' "$url" 2>/dev/null)
	case "$body" in
		*eportal/index.jsp*|*webauth.do*|*InterFace.do*) printf '%s' "$body"; return 0 ;;
	esac
	# 探针可能已被放行（如校内地址）：再试一个公认的校外明文探针
	[ "$url" = "$CAMP_HIJACK_URL" ] || body=$(curl -si -m 8 --interface "$dev" \
		--noproxy '*' "$CAMP_HIJACK_URL" 2>/dev/null)
	printf '%s' "$body"
}

# 页面特征探测（auto 模式）：输出 eportal|ruijie
#
# 顺序要紧：先认 ruijie 的独有特征（webauth.do/distoken），再认 eportal。
# 反过来会被 eportal 的通用字样误伤。
# 另外判据不能只盯着 eportal/index.jsp —— 接口**已在线**时门户不再劫持，
# 只剩网关根那条 302（本网是 /eportal/redirectortosuccess.jsp）。以前这里
# 匹配不到就默认 ruijie，于是对 eportal 门户发了一串 axe 的 webauth.do 请求：
# 无效认证请求在校园网里可能直接触发账号锁定。
detect_portal_type() {
	local dev="$1" body
	# 1) 权威判据：被劫持的跳转脚本
	body=$(harvest_portal_response "$dev")
	case "$body" in
		*webauth.do*|*distoken=*) echo ruijie;  return ;;
		*eportal*|*InterFace.do*) echo eportal; return ;;
	esac
	# 2) 兜底：网关根的响应头/正文（含 302 Location）
	body=$(curl -si -m 8 --interface "$dev" --noproxy '*' "http://$S_GATEWAY/" 2>/dev/null)
	case "$body" in
		*webauth.do*|*distoken=*) echo ruijie;  return ;;
		*eportal*|*InterFace.do*) echo eportal; return ;;
	esac
	echo ruijie
}

# ------------------------------------------------------------
# 版本与更新检查
# ------------------------------------------------------------
CAMP_VERSION_FILE=/usr/libexec/campnet/VERSION
CAMP_REPO=RyanZhangK/luci-app-campnet
CAMP_UPDATE_CACHE=/var/run/campnet/update.json

camp_version() {
	local v
	v=$(cat "$CAMP_VERSION_FILE" 2>/dev/null | tr -d ' \n\r')
	printf '%s' "${v:-unknown}"
}

# camp_check_update [--refresh] —— 输出 settings/version 页要的 JSON
# 结果缓存 1 小时：GitHub API 有速率限制，不能每次开页面都打。
# 取不到最新版本（无网/被墙/仓库无 tag）时不报错，返回 latest="" 由 UI 降级展示。
camp_check_update() {
	local force="$1" age cur latest cmp

	cur=$(camp_version)
	if [ "$force" != "--refresh" ] && [ -f "$CAMP_UPDATE_CACHE" ]; then
		age=$(( $(date +%s) - $(stat -c %Y "$CAMP_UPDATE_CACHE" 2>/dev/null || echo 0) ))
		if [ "$age" -ge 0 ] && [ "$age" -lt 3600 ]; then
			cat "$CAMP_UPDATE_CACHE"
			return 0
		fi
	fi

	remote=$(curl -s -m 8 --noproxy '*' -H 'User-Agent: luci-app-campnet' \
		"https://api.github.com/repos/$CAMP_REPO/tags" 2>/dev/null \
		| grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
		| sed 's/.*:[[:space:]]*"\(.*\)"$/\1/' \
		| sed 's/^[vV]//' \
		| sort -t. -k1,1n -k2,2n -k3,3n 2>/dev/null | tail -1)

	# 三态要分清，否则界面无法区分「已是最新」和「根本取不到远端」：
	#   checked=0            → 没拿到（无网 / 被墙 / 仓库没有 tag）
	#   checked=1, latest="" → 拿到了，且已是最新
	#   checked=1, latest=X  → 有更新
	if [ -n "$remote" ]; then
		checked=1
		if [ "$remote" = "$cur" ]; then latest=""; else latest="$remote"; fi
	else
		checked=0
		latest=""
	fi

	mkdir -p "$(dirname "$CAMP_UPDATE_CACHE")" 2>/dev/null
	gen_update_json() {
		if [ -f /usr/share/libubox/jshn.sh ]; then
			. /usr/share/libubox/jshn.sh
			json_init
			json_add_string version "$cur"
			json_add_string latest "$latest"
			json_add_string url "https://github.com/$CAMP_REPO"
			json_add_boolean checked "$checked"
			json_dump
		else
			printf '{"version":"%s","latest":"%s","url":"https://github.com/%s","checked":%s}\n' \
				"$cur" "$latest" "$CAMP_REPO" "$checked"
		fi
	}
	gen_update_json | tee "$CAMP_UPDATE_CACHE" 2>/dev/null || gen_update_json
}
