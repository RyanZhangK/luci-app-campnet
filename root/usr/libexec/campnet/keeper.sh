#!/bin/sh
# ============================================================
# keeper.sh —— 每条线路一个保活循环（procd 实例）
# 用法: keeper.sh --line <线路名> [--interval <秒>]
# 逻辑：周期性探测该线路 → 需要认证时自动登录 → 更新状态 → 睡眠。
# 注意：保活的单位是**线路**而不是账号 —— 同一账号可以挂两条线路，
#       各自是独立会话，必须独立探测/登录。
# ============================================================

CAMP_LIB=/usr/libexec/campnet/lib.sh
[ -f "$CAMP_LIB" ] || CAMP_LIB="$(dirname "$0")/lib.sh"
. "$CAMP_LIB" || { echo "keeper: 无法加载 $CAMP_LIB" >&2; exit 1; }
. "$(dirname "$0")/ruijie.sh"
. "$(dirname "$0")/eportal.sh"

LINE=""
INTERVAL=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--line) LINE="$2"; shift 2 ;;
		--account) LINE="$2"; shift 2 ;;   # 兼容旧参数名
		--interval) INTERVAL="$2"; shift 2 ;;
		*) shift ;;
	esac
done

[ -n "$LINE" ] || { echo "keeper: 缺少 --line" >&2; exit 1; }

# 干净退出（procd stop / TERM）
trap 'exit 0' TERM INT HUP

# 分片睡眠：ash 在前台子进程（sleep）运行期间不会执行 trap，整段 sleep 120
# 会让 procd stop 等满 5s 超时再 SIGKILL。切成 1 秒一片，停止/重启就能秒退。
nap() {
	local left="${1:-60}" unit="${2:-1}"
	while [ "$left" -gt 0 ]; do
		sleep "$unit"
		left=$((left - unit))
	done
}

log INFO "keeper[线路=$LINE] 启动"

while :; do
	load_settings
	[ "$S_ENABLED" = "1" ] || { nap "${INTERVAL:-60}"; continue; }
	[ "$(line_enabled "$LINE")" = "1" ] || { nap "${INTERVAL:-60}"; continue; }

	acc=$(line_account "$LINE")
	[ -n "$acc" ] || { nap "${INTERVAL:-60}"; continue; }
	[ "$(acct_enabled "$acc")" = "1" ] || { nap "${INTERVAL:-60}"; continue; }

	dev=$(line_dev "$LINE")
	DEV="$dev"

	st=$(probe_status "$dev")
	ip=$(dev_ip "$dev"); mac=$(dev_mac "$dev")

	case "$st" in
		authenticated)
			# 顺带刷新门户回传的实名信息（姓名/用户组/余额），供总览页展示。
			# 抓不到就沿用上一次的值，绝不覆盖成空。
			# 注意用「按行读取 + set --」组装实参：实名可能含空格，
			# 直接 `$pinfo` 展开会被词切分拆散，state_write 的键值对就错位了。
			pinfo=$(portal_info "$dev")
			[ -n "$pinfo" ] || pinfo=$(printf 'pname=%s\npuser=%s\npgroup=%s\npfee=%s\n' \
				"$(state_read "$LINE" pname)" "$(state_read "$LINE" puser)" \
				"$(state_read "$LINE" pgroup)" "$(state_read "$LINE" pfee)")
			set --
			while IFS= read -r kv; do
				[ -n "$kv" ] || continue
				set -- "$@" "${kv%%=*}" "${kv#*=}"
			done <<EOF
$pinfo
EOF
			state_write "$LINE" status authenticated ip "$ip" mac "$mac" dev "$dev" \
				account "$acc" msg "在线" "$@"
			;;
		no_ip)
			state_write "$LINE" status no_ip ip "" mac "$mac" dev "$dev" account "$acc" msg "接口无 IP（等待 DHCP）"
			log INFO "keeper[$LINE] 接口 $dev 暂无 IP"
			;;
		need_auth|offline)
			state_write "$LINE" status "$st" ip "$ip" mac "$mac" dev "$dev" account "$acc" msg "离线，尝试认证"
			log INFO "keeper[$LINE] 检测到 $st，尝试自动登录…"
			run_login "$LINE"
			;;
	esac

	nap "${INTERVAL:-$S_CHECK_INTERVAL}"
done
