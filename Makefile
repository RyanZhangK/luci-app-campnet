# SPDX-License-Identifier: WTFPL
#
# luci-app-campnet — 校园网自动认证 + 多账号多播均衡（ImmortalWrt/OpenWrt）
#
# 用法：
#   方式一（推荐）：把本目录放到 feeds/luci/applications/luci-app-campnet
#     （或 src-link 到 feeds/luci/applications/），再 ./scripts/feeds update -i
#   make menuconfig 中选中 LuCI -> Applications -> luci-app-campnet
#
#   方式二：直接放入 <immortalwrt>/package/custom/luci-app-campnet，
#     并把下面的 "include ../../luci.mk" 改为：
#       include $(TOPDIR)/feeds/luci/luci.mk
#   并确保 feeds/luci 已 ./scripts/feeds update -i（提供 luci.mk 与依赖）。

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-campnet
PKG_VERSION:=0.2.0
PKG_RELEASE:=1

PKG_LICENSE:=WTFPL
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=ryanz <ryanz@users.noreply.github.com>

LUCI_TITLE:=Campus network auto-auth & multi-WAN bond (CampNet)
LUCI_DESCRIPTION:=Campus portal auto login (default gateway 10.0.1.51), per-account macvlan dial-up and mwan3 load balancing for bandwidth aggregation. Shell backend + native LuCI2 JS UI.
LUCI_DEPENDS:=+luci-base +curl +ip-full +jsonfilter +mwan3 +ucode
LUCI_PKGARCH:=all

# 安装后初始化（opkg install 时执行；首刷镜像由 uci-defaults 兜底）
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/campnet enable 2>/dev/null
	/etc/init.d/campnet start 2>/dev/null
	rm -f /tmp/luci-indexcache.* /tmp/luci-modulecache.* /tmp/luci-indexcache/
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
exit 0
endef

include ../../luci.mk

# call BuildPackage - OpenWrt buildroot signature
