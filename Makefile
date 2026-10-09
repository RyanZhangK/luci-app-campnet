# SPDX-License-Identifier: WTFPL
#
# luci-app-campnet — 校园网自动认证 + 多线路多播均衡（ImmortalWrt/OpenWrt）
#
# 用法：
#   方式一（推荐）：把本目录放到 feeds/luci/applications/luci-app-campnet
#     （或 src-link 到 feeds/luci/applications/），再 ./scripts/feeds update -i
#   make menuconfig 中选中 LuCI -> Applications -> luci-app-campnet
#
#   方式二：直接放入 <immortalwrt>/package/custom/luci-app-campnet，
#     并把文件末尾的 luci.mk include 改成：
#       include $(TOPDIR)/feeds/luci/luci.mk
#   并确保 feeds/luci 已 ./scripts/feeds update -i（提供 luci.mk 与依赖）。

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-campnet
PKG_VERSION:=1.1.0
PKG_RELEASE:=1

PKG_LICENSE:=WTFPL
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=ryanz <ryanz@users.noreply.github.com>

LUCI_TITLE:=Campus network auto-auth, per-line dial & mwan3 balancing
LUCI_DESCRIPTION:=Campus portal auto login (ruijie eportal / axe_bras), one procd keeper per line, macvlan multi-dial and mwan3 load balancing. Shell backend + native LuCI2 JS UI.
# ucode 不需要：后端是 rpcd 的 shell exec 插件，不是 ucode 模块。
# mwan3 只有「多线路均衡」用得到（单线路不需要），但装上才能开箱即用多播。
LUCI_DEPENDS:=+luci-base +curl +ip-full +jsonfilter +mwan3
LUCI_PKGARCH:=all

# 安装后初始化（opkg/apk 安装时执行；首刷镜像由 uci-defaults 兜底）
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/campnet enable 2>/dev/null
	/etc/init.d/campnet start 2>/dev/null
	rm -f /tmp/luci-indexcache.* /tmp/luci-modulecache.* 2>/dev/null
	rm -rf /tmp/luci-modulecache/ 2>/dev/null
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
exit 0
endef

# 卸载后清理：停服务 + 关自启。
# 帐密（/etc/campnet/.config）与 uci 配置**故意保留** —— 卸载重装后还能接着用，
# 误删用户凭据的代价比留一点残留大得多。
define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/campnet disable 2>/dev/null
	/etc/init.d/campnet stop 2>/dev/null
	rm -f /tmp/luci-indexcache.* /tmp/luci-modulecache.* 2>/dev/null
	rm -rf /tmp/luci-modulecache/ 2>/dev/null
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
exit 0
endef

include ../../luci.mk

# call BuildPackage - OpenWrt buildroot signature
