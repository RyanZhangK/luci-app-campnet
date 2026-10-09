#!/bin/sh
# ============================================================
# dial.sh —— 多账号多播均衡编排（带宽倍增）
# setup   : 每条启用线路建立独立 WAN 接口并注入 mwan3 均衡
#           - type=macvlan 的线路 → netifd 托管 macvlan(campnet_<id>) + DHCP
#           - 全部启用线路 → mwan3 interface/member + policy(campnet_bal)
#           - 兜底 rule(campnet_rule)，自动置于 default_rule* 之前
# teardown: 仅撤销 .created 登记过的本插件资源，绝不碰用户既有配置
# status  : 打印登记与存活情况
# 幂等     : 可反复执行；仅当确有变更才 commit / 重启 mwan3
# ============================================================

# 允许外部预先指定 CAMP_LIB（自测 source 本文件时用），否则用设备路径
: "${CAMP_LIB:=/usr/libexec/campnet/lib.sh}"
[ -f "$CAMP_LIB" ] || CAMP_LIB="$(dirname "$0")/lib.sh"
. "$CAMP_LIB" || { echo "dial: 无法加载 $CAMP_LIB" >&2; exit 1; }

MWAN3_BIN=$(command -v mwan3 2>/dev/null || echo /usr/sbin/mwan3)
DIRTY=0

uci_chk() { # <cfg.section.option> <value> —— 值不同才 set 并置 DIRTY
	local cur
	cur=$(uci -q get "$1")
	[ "$cur" = "$2" ] || { uci -q set "$1=$2"; DIRTY=1; }
}

mark() { # kind arg [arg...] —— 必须记录全部参数：
	# fwlist 需要 “zone 序号 + 接口名” 两个参数，只记前两个会在 teardown 时
	# 丢掉接口名（$3 为空 → 防火墙成员永远删不掉）。
	mkdir -p "$CAMP_DIR" 2>/dev/null
	grep -qF -- "$*" "$CAMP_CREATED" 2>/dev/null || echo "$*" >> "$CAMP_CREATED"
}

# 命名助手（base_of/dev_name_for/devsec_for）与 line_* 等由 lib.sh 统一提供。

# 生成随机 MAC —— 首字节固定 02（本地管理位=1、单播位=0，避免撞真实厂商 OUI）
# 不能用 od/xxd：精简 ImmortalWrt 固件常不带（本测试机就没有 od），
# 原实现退化后只产出 8 位十六进制（非法 MAC），netifd 直接忽略 →
# 接口每次重启都换内核随机 MAC，MAC 固化/防风控完全失效。
_gen_mac() {
	local hex
	hex=$(tr -d '-' < /proc/sys/kernel/random/uuid 2>/dev/null)
	[ "${#hex}" -ge 10 ] || hex=$(printf '%04x%04x%04x' "$$" "${RANDOM:-0}" "$(date +%s)")
	hex=$(printf '%s' "$hex" | cut -c1-10)
	printf '02:%s' "$(printf '%s' "$hex" | sed 's/../&:/g; s/:$//')"
}

# XX:XX:XX:XX:XX:XX 形式校验（历史上存进去的坏值要能被识别并重生成）
_is_valid_mac() {
	local m="$1"
	[ "${#m}" -eq 17 ] || return 1
	case "$m" in
		[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
	esac
	return 1
}

# 取（或生成并固化）某线路 macvlan MAC —— 固化到 uci 防重启漂移
_line_mac() {
	local l="$1" mac
	mac=$(line_opt "$l" macaddr)
	if ! _is_valid_mac "$mac"; then
		[ -n "$mac" ] && log WARN "dial: 线路[$l] 已存 macaddr '$mac' 非法，重新生成"
		mac=$(_gen_mac)
		uci -q set "campnet.$l.macaddr=$mac"
		DIRTY=1
	fi
	echo "$mac"
}

# 上行接口当前的默认路由 metric（主 wan 通常是 0）。
# 新接口若用同一个值，两条默认路由会打架，最坏直接把主路由顶掉、整机断网
# （本项目真的这么断过一次）。所以 route_metric 必须**严格大于**它。
_uplink_metric() {
	local dev m
	dev=$(_resolve_uplink)
	m=$(ip route show default dev "$dev" 2>/dev/null \
		| sed -n 's/.* metric \([0-9][0-9]*\).*/\1/p' | head -1)
	case "$m" in ''|*[!0-9]*) m=0 ;; esac
	printf '%s' "$m"
}

# macvlan 挂在哪个物理设备上：优先取「类型=wan 的那条线路」的接口，
# 退回到 wan 接口。类型=wan 的线路才是真正复用物理上行的那条。
_resolve_uplink() {
	local l
	if [ -n "$S_UPLINK" ] && [ "$S_UPLINK" != "auto" ]; then
		echo "$S_UPLINK"
		return
	fi
	for l in $(camp_line_ids); do
		[ "$(line_type "$l")" = "wan" ] || continue
		iface_to_dev "$(line_iface "$l")"
		return
	done
	iface_to_dev wan
}

fw_zone_index() { # zone name → 序号（找不到返回 1 退出码）
	local i=0 n
	while :; do
		n=$(uci -q get "firewall.@zone[$i].name")
		[ -n "$n" ] || return 1
		[ "$n" = "$1" ] && { echo "$i"; return 0; }
		i=$((i + 1))
	done
	return 1
}

mwan3_available() {
	[ -x "$MWAN3_BIN" ] && [ -f /etc/config/mwan3 ]
}

# 参与均衡的线路："iface|metric|weight" 列表（确定性顺序、按接口去重）
_balance_targets() {
	local l acc devname seen out
	seen=""; out=""
	for l in $(camp_line_ids); do
		[ "$(line_enabled "$l")" = "1" ] || continue
		acc=$(line_account "$l")
		[ -n "$acc" ] && [ "$(acct_enabled "$acc")" = "1" ] || continue
		devname=$(line_iface "$l")
		case " $seen " in
			*" $devname "*)
				log WARN "dial: 线路[$l] 与其它线路共用接口 $devname，已跳过（检查 campnet.$l.ifbase）"
				continue ;;
		esac
		seen="$seen $devname"
		out="$out $devname|$(uciqn "campnet.$l.metric" 10)|$(uciqn "campnet.$l.weight" 10)"
	done
	echo "$out"
}

# 从登记表里移除一条记录
#
# 不能写成 `grep -v ... && mv`：当最后一条记录被删掉、grep 输出为空时，
# grep 返回 1，mv 就不会执行，那条记录会永远留在登记表里。
_unmark() {
	[ -f "$CAMP_CREATED" ] || return 0
	if grep -qF -- "$*" "$CAMP_CREATED" 2>/dev/null; then
		grep -vxF -- "$*" "$CAMP_CREATED" > "$CAMP_CREATED.tmp" 2>/dev/null
		mv "$CAMP_CREATED.tmp" "$CAMP_CREATED" 2>/dev/null
	fi
	return 0
}

# ------------------------------------------------------------
# 回收「已不在目标集里」的资源
#
# 触发场景：把某条线路 enabled=0、删掉线路、或线路数从 ≥2 降到 1。
# 只动 .created 登记过的、本插件创建的东西，不碰用户自己的配置。
#
# 不做的后果（实测踩过）：campnet_rule 仍指向 campnet_bal，而 campnet_bal
# 的成员指向一个已经删掉的接口 —— mwan3 策略引用不存在的接口会造成
# 流量黑洞，而不是自动回落到默认策略。
# ------------------------------------------------------------
_prune_resources() {
	local keep l s z net devname allids f

	# 保留集：仍然启用且已绑定账号的 macvlan 线路的设备名
	keep=""
	for l in $(camp_line_ids); do
		[ "$(line_enabled "$l")" = "1" ] || continue
		[ "$(line_type "$l")" != "wan" ] || continue
		[ -n "$(line_account "$l")" ] || continue
		keep="$keep $(dev_name_for "$l")"
	done

	# network 接口段
	for s in $(awk '$1=="netiface"{print $2}' "$CAMP_CREATED" 2>/dev/null); do
		case " $keep " in *" $s "*) continue ;; esac
		log INFO "dial: 回收已停用线路的接口 $s"
		ifdown "$s" >/dev/null 2>&1 || true
		uci -q delete "network.$s" 2>/dev/null
		_unmark netiface "$s"
		DIRTY=1
	done

	# netifd device 段（先删内核设备再删段）
	for s in $(awk '$1=="netdev"{print $2}' "$CAMP_CREATED" 2>/dev/null); do
		devname=$(uci -q get "network.$s.name")
		case " $keep " in *" $devname "*) continue ;; esac
		[ -n "$devname" ] && [ -d "/sys/class/net/$devname" ] \
			&& ip link del dev "$devname" 2>/dev/null
		uci -q delete "network.$s" 2>/dev/null
		_unmark netdev "$s"
		DIRTY=1
	done

	# 防火墙 wan 区域成员（不能放管道里：子 shell 里 _unmark 影响不到外层）
	for s in $(awk '$1=="fwlist"{print $2"|"$3}' "$CAMP_CREATED" 2>/dev/null); do
		z=${s%%|*}; net=${s#*|}
		[ -n "$z" ] && [ -n "$net" ] || continue
		case " $keep " in *" $net "*) continue ;; esac
		uci -q del_list "firewall.@zone[$z].network=$net" 2>/dev/null
		_unmark fwlist "$z" "$net"
		DIRTY=1
	done

	# mwan3 接口 / 成员
	for s in $(awk '$1=="mwan3iface"{print $2}' "$CAMP_CREATED" 2>/dev/null); do
		case " $keep " in *" $s "*) continue ;; esac
		uci -q delete "mwan3.$s" 2>/dev/null
		_unmark mwan3iface "$s"
		DIRTY=1
	done
	for s in $(awk '$1=="mwan3member"{print $2}' "$CAMP_CREATED" 2>/dev/null); do
		case " $keep " in *" ${s%_campnet} "*) continue ;; esac
		uci -q delete "mwan3.$s" 2>/dev/null
		_unmark mwan3member "$s"
		DIRTY=1
	done

	# 状态文件与 cookie：线路段被删掉之后这两样会永久残留 ——
	# state 留着陈旧状态（总览页会继续显示一条不存在的线路的旧 IP），
	# cookie 留着上一张 0600 的会话票据，仍然是一份凭据。
	# CLI 的 `line del` 会顺手清理，但界面上的删除走的是 uci（提交时落盘），
	# 所以这里按「uci 里还存在的线路」统一回收，两条路径行为一致。
	# 判据用 camp_line_ids 而不是 keep：wan 型线路没有设备，同样要清。
	#
	# 保险：只在 uci **确实可读**时才动手。`uci show campnet` 整体失败时
	# camp_line_ids 也是空的，那就成了"所有线路都被删了"的误判，
	# 会一次性清掉全部状态与 cookie。settings 段存在即说明配置读得到。
	if [ -n "$(uciq campnet.settings)" ]; then
		allids=" $(camp_line_ids | tr '\n' ' ') "
		for f in "$CAMP_STATE_DIR"/*.state; do
			[ -e "$f" ] || continue
			z=$(basename "$f" .state)
			case "$allids" in *" $z "*) continue ;; esac
			log INFO "dial: 回收已删除线路的状态文件 $z.state"
			rm -f "$f"
		done
		for f in "$COOKIE_PREFIX".*.jar; do
			[ -e "$f" ] || continue
			z=${f#"$COOKIE_PREFIX".}
			z=${z%.jar}
			case "$allids" in *" $z "*) continue ;; esac
			log INFO "dial: 回收已删除线路的 cookie（$z）"
			rm -f "$f"
		done
	fi
	return 0
}

# ------------------------------------------------------------
# pass1：macvlan + DHCP + 防火墙
# ------------------------------------------------------------
dial_net_setup() {
	local uplink l acc z devname devsec mac curmac base used_names rmet acct_seen cnt
	local up_metric
	uplink=$(_resolve_uplink)
	if [ -z "$uplink" ] || [ ! -d "/sys/class/net/$uplink" ]; then
		log WARN "dial: 上行链路 '$uplink' 不存在，跳过"
		return 0
	fi
	up_metric=$(_uplink_metric)
	log INFO "dial: 上行链路 = $uplink (metric=$up_metric)"

	used_names=""
	for l in $(camp_line_ids); do
		[ "$(line_enabled "$l")" = "1" ] || continue
		# 复用物理接口的线路不建设备（line_iface 把 wan/physical 都当复用，
		# 这里必须用同一判据，否则 type=physical 会建出一半矛盾的状态）
		case "$(line_type "$l")" in wan|physical) continue ;; esac
		acc=$(line_account "$l")
		[ -n "$acc" ] && [ "$(acct_enabled "$acc")" = "1" ] || {
			log WARN "dial: 线路[$l] 未绑定有效账号，跳过"
			continue
		}

		# 固化短名：dial/keeper/status 三处必须看到同一个名字
		base=$(base_of "$l")
		if [ "$(uciq "campnet.$l.ifbase")" != "$base" ]; then
			uci -q set "campnet.$l.ifbase=$base"
			DIRTY=1
		fi
		# 短名撞车（哈希碰撞）宁可报错也不能静默共用一条线路
		case " $used_names " in
			*" $base "*)
				log ERROR "dial: 线路[$l] 的短名 '$base' 与其它线路冲突，已跳过；请改名或手填 campnet.$l.ifbase"
				continue ;;
		esac
		used_names="$used_names $base"

		devname=$(dev_name_for "$l")
		devsec=$(devsec_for "$l")
		mac=$(_line_mac "$l")
		log INFO "dial: 线路[$l]（账号[$acc]）→ macvlan $devname (link=$uplink mac=$mac)"

		# 1) netifd 托管 device 段（type macvlan，重启自动重建）
		[ "$(uci -q get network.$devsec 2>/dev/null)" = "device" ] || {
			uci -q set "network.$devsec=device"; DIRTY=1
		}
		uci_chk "network.$devsec.name" "$devname"
		uci_chk "network.$devsec.type" "macvlan"
		uci_chk "network.$devsec.ifname" "$uplink"
		uci_chk "network.$devsec.mode" "bridge"
		uci_chk "network.$devsec.macaddr" "$mac"
		mark netdev "$devsec"

		# 2) DHCP 接口（id 与内核设备同名，netifd 自动关联 device 段）
		[ "$(uci -q get network.$devname 2>/dev/null)" = "interface" ] || {
			uci -q set "network.$devname=interface"; DIRTY=1
		}
		uci_chk "network.$devname.proto" "dhcp"
		uci_chk "network.$devname.device" "$devname"
		# 关键：显式抬高路由 metric。主 wan 的默认路由 metric 为 0，若本接口也
		# 用 0，netifd 装上来的第二条默认路由会顶掉 wan —— 实测会让整机断网。
		# mwan3 走 fwmark 独立路由表，不依赖这里的 metric，抬高无副作用。
		# 钳制到严格大于上行接口的 metric，避免抢默认路由
		rmet=$(uciqn "campnet.$l.route_metric" 20)
		[ "$rmet" -gt "$up_metric" ] || rmet=$((up_metric + 10))
		uci_chk "network.$devname.metric" "$rmet"
		mark netiface "$devname"

		# 3) 防火墙 wan 区域成员
		z=$(fw_zone_index wan)
		if [ -n "$z" ]; then
			case " $(uci -q get firewall.@zone[$z].network 2>/dev/null) " in
				*" $devname "*) ;;
				*) uci -q add_list "firewall.@zone[$z].network=$devname"; mark fwlist "$z" "$devname"; DIRTY=1 ;;
			esac
		else
			log WARN "dial: 找不到 firewall zone 'wan'，请手动把 $devname 加入 wan 区域"
		fi
	done

	[ "$DIRTY" -eq 1 ] || return 0
	# 固化新生成的 MAC 等 campnet 选项（commit 会触发服务 reload，幂等安全）
	[ -n "$(uci -q changes campnet 2>/dev/null)" ] && uci -q commit campnet 2>/dev/null
	uci -q commit network
	uci -q commit firewall
	# 立即建立并拉起 DHCP（先把 MAC 落实，再 ifup，避免 DHCP 拿到旧 MAC 的租约）
	for l in $(camp_line_ids); do
		[ "$(line_enabled "$l")" = "1" ] || continue
		case "$(line_type "$l")" in wan|physical) continue ;; esac
		devname=$(dev_name_for "$l")
		mac=$(line_opt "$l" macaddr)
		# 设备若已存在（上一轮 dial 建的），netifd 不会就地改 MAC，这里直接落一次
		if [ -n "$mac" ] && [ -d "/sys/class/net/$devname" ]; then
			curmac=$(dev_mac "$devname")
			if [ "$curmac" != "$(printf '%s' "$mac" | tr 'a-f' 'A-F')" ]; then
				ip link set dev "$devname" address "$mac" 2>/dev/null \
					|| log WARN "dial: 无法设置 $devname 的 MAC=$mac"
			fi
		fi
		ifup "$devname" >/dev/null 2>&1 || true
	done
	[ -x /etc/init.d/firewall ] && /etc/init.d/firewall reload >/dev/null 2>&1 || true
	return 0
}

# ------------------------------------------------------------
# pass2：mwan3 均衡（≥2 条线路才注入）
# ------------------------------------------------------------
dial_mwan3_setup() {
	local targets n t iface metric weight member desired cur metric_mismatch member_metric oldm
	targets=$(_balance_targets)
	n=$(echo $targets | wc -w)
	[ "$n" -ge 2 ] || {
		# 不足两条线路时必须把本插件的 mwan3 配置撤干净。
		# 否则 policy 会指向已删除的接口 —— mwan3 遇到这种引用是流量黑洞，
		# 而不是自动回落到默认策略。
		local kind had=0
		for kind in mwan3rule mwan3policy mwan3member mwan3iface; do
			for s in $(awk -v k="$kind" '$1==k{print $2}' "$CAMP_CREATED" 2>/dev/null); do
				uci -q get "mwan3.$s" >/dev/null 2>&1 && { uci -q delete "mwan3.$s"; had=1; }
				_unmark "$kind" "$s"
			done
		done
		if [ "$had" = "1" ]; then
			uci -q commit mwan3 2>/dev/null
			mwan3_available && "$MWAN3_BIN" restart >/dev/null 2>&1
			log INFO "dial: 可用线路 $n 条（<2），已撤除 mwan3 均衡配置"
		else
			log INFO "dial: 可用线路 $n 条（<2），无需 mwan3 均衡"
		fi
		return 0
	}
	mwan3_available || { log WARN "dial: mwan3 不可用，跳过均衡注入（opkg install mwan3）"; return 0; }

	# interface / member
	#
	# 成员名固定为 <接口>_campnet，**不把 metric/weight 编进段名**：这两个值
	# 用户随时会改，编进名字后每改一次就多出一个没人引用的孤儿成员段。
	# 改就地更新即可。
	#
	# 另外要清楚 mwan3 的策略语义（/lib/mwan3/mwan3.sh mwan3_set_policy）：
	# 它**只保留 metric 最小的那批成员**，metric 更大的直接 return。
	# 所以 N 条线要**均衡**，metric 必须相同；metric 不同 = 只做故障切换。
	member_metric=""
	for t in $targets; do
		iface=${t%%|*}; rest=${t#*|}; metric=${rest%%|*}; weight=${rest##*|}
		member="${iface}_campnet"
		if [ -z "$member_metric" ]; then member_metric="$metric"
		elif [ "$metric" != "$member_metric" ]; then metric_mismatch=1; fi
		if ! uci -q get "mwan3.$iface" >/dev/null 2>&1; then
			uci -q set "mwan3.$iface=interface"
			uci -q set "mwan3.$iface.enabled=1"
			uci -q set "mwan3.$iface.family=ipv4"
			uci -q set "mwan3.$iface.reliability=2"
			for ip in $S_TRACK_IPS; do
				uci -q add_list "mwan3.$iface.track_ip=$ip"
			done
			mark mwan3iface "$iface"
			DIRTY=1
		fi
		if ! uci -q get "mwan3.$member" >/dev/null 2>&1; then
			uci -q set "mwan3.$member=member"
			uci -q set "mwan3.$member.interface=$iface"
			mark mwan3member "$member"
			DIRTY=1
		fi
		uci_chk "mwan3.$member.metric" "$metric"
		uci_chk "mwan3.$member.weight" "$weight"
	done

	# policy
	if ! uci -q get "mwan3.campnet_bal" >/dev/null 2>&1; then
		uci -q set "mwan3.campnet_bal=policy"
		mark mwan3policy campnet_bal
		DIRTY=1
	fi
	# 重建 use_member（仅当实际不同）
	desired=""
	for t in $targets; do
		iface=${t%%|*}
		desired="$desired ${iface}_campnet"
	done
	desired=${desired# }
	cur=$(uci -q get "mwan3.campnet_bal.use_member")
	if [ "$cur" != "$desired" ]; then
		uci -q delete "mwan3.campnet_bal.use_member" 2>/dev/null
		for m in $desired; do
			uci -q add_list "mwan3.campnet_bal.use_member=$m"
		done
		DIRTY=1
	fi

	# 清理由本插件登记、但已不在目标集里的成员段
	# （覆盖早期命名 <iface>_camp_m<metric>_w<weight> 遗留的孤儿）
	for oldm in $(awk '$1=="mwan3member"{print $2}' "$CAMP_CREATED" 2>/dev/null); do
		case " $desired " in *" $oldm "*) continue ;; esac
		if uci -q get "mwan3.$oldm" >/dev/null 2>&1; then
			uci -q delete "mwan3.$oldm"
			DIRTY=1
		fi
		grep -vxF "mwan3member $oldm" "$CAMP_CREATED" > "$CAMP_CREATED.tmp" 2>/dev/null \
			&& mv "$CAMP_CREATED.tmp" "$CAMP_CREATED"
	done

	if [ "$metric_mismatch" = "1" ]; then
		log WARN "dial: 各账号 mwan3 metric 不一致（$(echo $targets | tr ' ' ',')）——" \
			"mwan3 只会选用 metric 最小的那批线路，结果是故障切换而非带宽叠加；" \
			"需要均衡请把所有参与账号的 metric 设为同一个值"
	fi

	# rule（兜底 0.0.0.0/0 → campnet_bal；用 uci 创建，保证 commit 一致）
	if ! uci -q get "mwan3.campnet_rule" >/dev/null 2>&1; then
		uci -q set "mwan3.campnet_rule=rule"
		uci -q set "mwan3.campnet_rule.dest_ip=0.0.0.0/0"
		uci -q set "mwan3.campnet_rule.family=ipv4"
		uci -q set "mwan3.campnet_rule.use_policy=campnet_bal"
		mark mwan3rule campnet_rule
		DIRTY=1
	fi

	# 提交配置（若有变更）
	[ "$DIRTY" -eq 1 ] && uci -q commit mwan3

	# 规则位置校正：无论本次是否有其它变更，保证 campnet_rule 在 default_rule 之前
	MOVED=0
	[ -f /etc/config/mwan3 ] && grep -q "^config rule .campnet_rule" /etc/config/mwan3 \
		&& _relocate_rule

	if [ "$DIRTY" -eq 1 ] || [ "$MOVED" -eq 1 ]; then
		if "$MWAN3_BIN" restart >/dev/null 2>&1; then
			log INFO "dial: mwan3 已重载，均衡生效"
		else
			log WARN "dial: mwan3 restart 失败，请手动检查"
		fi
	fi
	return 0
}

# 把 campnet_rule 段移动到第一个 default_rule* 之前（保证兜底规则先命中；
# mwan3 规则按配置顺序判定，落于 default 之后会被其吞掉）
# 用法: _relocate_rule [配置文件]（默认 /etc/config/mwan3；可传夹具路径以便自测）
_relocate_rule() {
	local cfg="${1:-/etc/config/mwan3}" tmp c_line d_line
	[ -f "$cfg" ] || return 0
	grep -q "^config rule .campnet_rule" "$cfg" || return 0
	c_line=$(grep -n "^config rule .campnet_rule" "$cfg" | head -1 | cut -d: -f1)
	d_line=$(grep -n "^config rule .default_rule" "$cfg" | head -1 | cut -d: -f1)
	[ -n "$c_line" ] && [ -n "$d_line" ] || return 0
	# 已经在 default 之前 → 真正的无操作：不写文件、不动 MOVED、不重启 mwan3。
	# 这一步必须在 awk 之前做：光靠 awk 内部判断「要不要动」，很容
	# 写出「不动时也把文件重写一遍甚至清零」的版本（本函数的旧实现就是）。
	[ "$c_line" -lt "$d_line" ] && return 0

	# 必须用独立临时名：并发 dial 时共享 mwan3.tmp 会互相截断
	tmp="$cfg.campnet.$$"
	awk '
		{ lines[NR] = $0 }
		END {
			start = 0; def = 0
			for (i = 1; i <= NR; i++) {
				if (!start && lines[i] ~ /^config rule .campnet_rule./) start = i
				if (!def    && lines[i] ~ /^config rule .default_rule/) def = i
			}
			# 走到这里说明 shell 侧已判定「需要移动」（start > def），
			# 正常情况下必定输出完整内容。仍保留原样输出分支作为兜底：
			# awk 里的 `exit 0` 不打印任何东西，若让它落到这里而调用方照样
			# mv，就会把整份 /etc/config/mwan3 清零。
			if (!start || !def || start < def) {
				for (i = 1; i <= NR; i++) print lines[i]
				exit 0
			}
			bend = NR
			for (i = start + 1; i <= NR; i++)
				if (lines[i] ~ /^config /) { bend = i - 1; break }
			for (i = 1; i <= NR; i++) {
				if (i >= start && i <= bend) continue
				if (i == def) { for (j = start; j <= bend; j++) print lines[j] }
				print lines[i]
			}
		}
	' "$cfg" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	# 兜底保险：绝不把空文件（或比原文更短的文件）覆盖到配置上。
	# 一旦覆盖，用户 mwan3 配置就永久没了。
	if [ ! -s "$tmp" ] || [ "$(wc -c < "$tmp")" -lt "$(wc -c < "$cfg")" ]; then
		log ERROR "dial: 重排 campnet_rule 后输出异常，放弃写入（保持原配置）"
		rm -f "$tmp"
		return 1
	fi
	mv "$tmp" "$cfg" 2>/dev/null || { rm -f "$tmp"; return 1; }
	MOVED=1
	log INFO "dial: campnet_rule 已置于 default_rule 之前"
	return 0
}

# ------------------------------------------------------------
dial_setup() {
	load_settings
	camp_migrate_legacy          # v0.x 的「账号即线路」配置先升到新模型
	[ "$S_ENABLED" = "1" ] || { log WARN "dial: 插件停用(enabled=0)，跳过"; return 0; }
	command -v ip >/dev/null 2>&1 || { log ERROR "dial: 缺少 ip 命令"; return 1; }

	# 串行化编排。三处会触发 dial setup，天然可能重叠：
	#   1) init.d start_service 后台拉起的 dial；
	#   2) uci commit campnet → procd_add_reload_trigger → reload → start → 又一轮；
	#   3) LuCI/CLI 手动 dial。
	# 并发 dial 会重复 restart mwan3、重复 /etc/init.d/firewall reload，
	# 实测足以把整机路由/防火墙打坏（LAN 直接失联）。锁必须在外层。
	lock_get dial || { log WARN "dial: 已有编排在运行，跳过本次"; return 0; }
	trap 'lock_release dial' EXIT INT TERM HUP

	dial_net_setup
	DIRTY=0   # pass1 变更已提交；pass2 只反映 mwan3 变更
	_prune_resources          # 回收已停用/已删除线路留下的资源
	dial_mwan3_setup

	lock_release dial
	trap - EXIT INT TERM HUP
	return 0
}

# teardown 时清理 mwan3 的本插件段。
# 不能只认 .created 登记表：命名方案演进过（策略 campnet_balanced → campnet_bal、
# 成员 <iface>_camp_m<metric>_w<weight> → <iface>_campnet），旧名字会永远留在表外。
# 这里以命名前缀/后缀兜底，保证任何版本的残留都能清掉。
_teardown_mwan3() {
	local sec
	for sec in $(uci show mwan3 2>/dev/null | sed -n 's/^mwan3\.\([^.]*\)=.*/\1/p'); do
		case "$sec" in
			campnet_*)                 uci -q delete "mwan3.$sec" ;;   # 策略/规则/接口
			*_campnet)                 uci -q delete "mwan3.$sec" ;;   # 成员（当前命名）
			*_camp_m[0-9]*_w[0-9]*)    uci -q delete "mwan3.$sec" ;;   # 成员（旧命名）
		esac
	done
}

dial_teardown() {
	local s z net
	# 先按登记表清，再按命名兜底（两者覆盖范围不同，都要做）
	if [ -f "$CAMP_CREATED" ]; then
		for s in $(awk '$1=="mwan3rule"||$1=="mwan3policy"||$1=="mwan3member"||$1=="mwan3iface"{print $2}' "$CAMP_CREATED"); do
			uci -q get "mwan3.$s" >/dev/null 2>&1 && uci -q delete "mwan3.$s"
		done
	fi
	_teardown_mwan3

	# 没有登记表也没关系：network/firewall 的清理同样按命名兜底
	if [ ! -f "$CAMP_CREATED" ]; then
		log INFO "dial: 无登记记录，按命名清理遗留资源"
		for s in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.]*\)=.*/\1/p'); do
			case "$s" in campnet_*|campd_*) uci -q delete "network.$s" ;; esac
		done
		# 防火墙成员同样要按命名清，否则 firewall 起不来（引用不存在的接口）
		local zi=0 zn
		while :; do
			zn=$(uci -q get "firewall.@zone[$zi].name")
			[ -n "$zn" ] || break
			for net in $(uci -q get "firewall.@zone[$zi].network"); do
				case "$net" in campnet_*) uci -q del_list "firewall.@zone[$zi].network=$net" ;; esac
			done
			zi=$((zi + 1))
		done
		uci -q commit firewall 2>/dev/null
		uci -q commit network 2>/dev/null
		mwan3_available && "$MWAN3_BIN" restart >/dev/null 2>&1
		log INFO "dial: 已按命名撤销本插件资源"
		return 0
	fi
	# 防火墙
	awk '$1=="fwlist"{print $2, $3}' "$CAMP_CREATED" | while read -r z net; do
		[ -n "$z" ] && [ -n "$net" ] && uci -q del_list "firewall.@zone[$z].network=$net" 2>/dev/null
	done
	# network 接口（devname）
	for s in $(awk '$1=="netiface"{print $2}' "$CAMP_CREATED"); do
		ifdown "$s" >/dev/null 2>&1 || true
		uci -q get "network.$s" >/dev/null 2>&1 && uci -q delete "network.$s"
	done
	# netifd device 段（devsec，内核设备名在 option name）
	for s in $(awk '$1=="netdev"{print $2}' "$CAMP_CREATED"); do
		kname=$(uci -q get "network.$s.name")
		uci -q get "network.$s" >/dev/null 2>&1 && uci -q delete "network.$s"
		if [ -n "$kname" ] && [ -d "/sys/class/net/$kname" ]; then
			ip link del dev "$kname" 2>/dev/null || true
		fi
	done
	uci -q commit network 2>/dev/null
	uci -q commit firewall 2>/dev/null
	uci -q commit mwan3 2>/dev/null
	rm -f "$CAMP_CREATED"
	mwan3_available && "$MWAN3_BIN" restart >/dev/null 2>&1 || true
	log INFO "dial: 已撤销本插件创建的全部多播资源"
	return 0
}

dial_status() {
	echo "== campnet 多播资源登记 =="
	[ -f "$CAMP_CREATED" ] && cat "$CAMP_CREATED" || echo "（无登记记录）"
	echo
	echo "== 线路 =="
	local l acc iface dev ip
	for l in $(camp_line_ids); do
		acc=$(line_account "$l")
		iface=$(line_iface "$l")
		dev=$(iface_to_dev "$iface")
		ip=$(dev_ip "$dev")
		printf '线路[%s] enabled=%s 账号=%s 类型=%s 接口=%s 设备=%s ip=%s\n' \
			"$l" "$(line_enabled "$l")" "${acc:--}" "$(line_type "$l")" \
			"$iface" "$dev" "${ip:--}"
	done
	return 0
}

# CAMP_DIAL_LIB_ONLY=1 时只加载函数、不执行动作 —— 供 tests/static-checks.sh
# source 进来做 _relocate_rule 的夹具测试（这个函数的回归代价是把用户配置清零）。
if [ "${CAMP_DIAL_LIB_ONLY:-0}" != "1" ]; then
	case "${1:-status}" in
		setup) dial_setup ;;
		teardown) dial_teardown ;;
		status) dial_status ;;
		*) echo "用法: $0 {setup|teardown|status}" >&2; exit 1 ;;
	esac
fi
