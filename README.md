# luci-app-campnet

[![License: WTFPL](https://img.shields.io/badge/License-WTFPL-brightgreen.svg)](LICENSE)

面向 ImmortalWrt / OpenWrt（LuCI2 JS）的**校园网 Portal 自动认证**插件：
断线自动重连、多线路多播均衡（带宽叠加）、原生 LuCI 三页交互界面。

> 认证算法在**肇庆学院锐捷 eportal**（网关 `10.0.1.51`）上完成真机实测；
> `ruijie`（axe_bras / webauth.do）与 `eportal` 两种门户均内置，可自动探测。

---

## 功能

| 模块 | 说明 |
|---|---|
| 自动认证 | `auto` 模式按被劫持页面特征自动识别门户类型（eportal / axe_bras）；认证成功后自动保活 |
| 断线自动重连 | 每条线路一个 procd keeper 周期探测。**从检测到掉线到重新上线约 2 秒**；而检测本身最长要等一个 `保活周期`（默认 60s），所以掉线到恢复的实际时长 ≈ 保活周期 |
| 多线路均衡 | 每条线路一条独立会话，`mwan3` 负载均衡；多线程下载/测速可叠加带宽 |
| 账号与线路分离 | **账号**是身份（学号/密码），**线路**是会话；一条线路绑定一个账号，一个账号最多 2 条线路 |
| 状态总览 | 总状态横幅 + 线路表 + 门户回传的实名信息（姓名/学号/用户组/余额） |
| 帐密安全 | 存 `/etc/campnet/.config`（0600），**不进 uci、不进 Git** |
| 版本检查 | 设置页显示版本并可一键比对 GitHub 最新 tag |
| 日志 | `/var/log/campnet/campnet.log`，行数轮转；写入前对密码/queryString/mac 等脱敏 |

> **带宽叠加的前提**：mwan3 是 per-flow 均衡，只有**多线程/多连接**场景才叠加；
> 单线程下载不会变快。另外要叠加，各线路的 `mwan3 metric` 必须填同一个值
> （mwan3 只采用 metric 最小的那批成员，不同值等于只做故障切换）。

---

## 安装

### 方式一：LuCI feed（推荐）

```bash
ln -s "$PWD" <immortalwrt>/feeds/luci/applications/luci-app-campnet
./scripts/feeds update -i && ./scripts/feeds install -a
make menuconfig      # LuCI → Applications → luci-app-campnet（*）
make package/luci-app-campnet/compile
```

### 方式二：放进源码树

把本目录放到 `<immortalwrt>/package/custom/luci-app-campnet`，并把 Makefile 里的
`include ../../luci.mk` 改成 `include $(TOPDIR)/feeds/luci/luci.mk`。

依赖：`luci-base curl ip-full jsonfilter mwan3`（仅多线路均衡需要 mwan3）。

装好后访问 **LuCI → 服务 → 校园网认证 CampNet**。

---

## 快速上手

1. **插件设置 → 账号**：填账号名（例如 `main`）→ Add。
2. **插件设置 → 帐密**：在对应账号那一行填学号与密码 → 保存。
3. **插件设置 → 线路**：默认已有一条 `wan` 线路（复用物理 WAN），把「归属账号」选成刚建的账号。
4. **状态总览**：点「立即登录全部」。之后 keeper 每 `保活周期` 秒自动保活。

要**叠加带宽**时：再加一条线路，`类型` 选 `macvlan`（独立设备 + 独立 MAC），
归属同一个账号，并把两条线路的 `mwan3 metric` 填成同一个值（默认都是 10）。

---

## 界面

### 状态总览
首屏横幅直接回答"现在通不通网"，下面是线路表（线路 / 归属账号 / 设备 / 状态 / IP / 最近结果 / 登录）。
再往下是账号的**门户实名信息**（姓名、学号、用户组、余额 —— 由校园网门户回传，需要线路在线）。
页尾「危险操作」里的撤销线路带二次确认。

### 插件设置
- **账号**：表格，一行一个账号，显示线路数与帐密状态。
- **线路**：表格，一行一条线路；类型/MAC/metric/权重等细节在 Edit 弹窗里。
- **帐密**：每个账号一行，直接填、直接存（不再是先选账号的下拉框）。
- **基本 / 高级**：常用项在「基本」；锐捷表单字段与超时等 12 个参数收在「高级」里，
  勾选「展开高级参数」才显示。
- **版本**：显示当前版本，可检查更新。

### 插件日志
行数选择、级别过滤（INFO / WARN / ERROR）、自动刷新。

---

## 命令行

```sh
campnet status [-j]                      # 状态（-j 输出 JSON）
campnet auth [all|<线路>] [--force]       # 立即登录
campnet portal [线路]                     # 查看门户回传的实名信息
campnet line {list|add|del}              # 线路管理
campnet account {list|add|del}           # 账号管理
campnet secret set <学号> <密码> [账号]    # 写帐密
campnet secret show [账号]                # 查看是否已配置（脱敏）
campnet test [线路]                       # 连通性自检
campnet dial {setup|teardown|status}     # 线路编排（建/删 macvlan 与 mwan3）
campnet log [行数]
campnet version | checkupdate            # 版本 / 检查更新
/etc/init.d/campnet {start|stop|restart|enable|disable}
```

---

## 配置参考（uci `campnet`）

### `settings`
`enabled`、`auth_mode`(auto|ruijie|eportal)、`gateway`(默认 10.0.1.51)、`probe_url`、
`check_interval`(60s)、`max_retry`/`retry_delay`、`dial_on_start`、`uplink`(auto)、
`show_advanced`；高级项：`wlanacname`、`pageid`、`templatetype`、`vlan`、`auth_type`、
`auth_host`/`server_ip`、`poll_max`/`poll_interval`、curl 超时。

### `account`（身份）
| 选项 | 说明 |
|---|---|
| `enabled` | 是否启用该账号 |

### `line`（会话）
| 选项 | 说明 |
|---|---|
| `enabled` | 是否启用该线路 |
| `account` | **必填**，归属账号 |
| `type` | `wan`=复用已有网络接口；`macvlan`=自建独立设备 |
| `iface` | `type=wan` 时使用哪个网络接口 |
| `macaddr` | `type=macvlan` 的设备 MAC，留空自动生成并固化 |
| `metric` / `weight` | mwan3 成员指标与权重（**要均衡则各线路 metric 必须相同**） |
| `route_metric` | 默认路由 metric，须大于主 wan 的 0（默认 20） |
| `ifbase` | 可选，手工指定通道短名（影响设备名 `campnet_<ifbase>`） |

- **账号数没有上限**，≥2 条线路才会注入 mwan3 均衡。
- 通道名由线路名派生且总长 ≤13 字节（mwan3 链名上限）；超长时自动取「前 2 位 + 3 位哈希」，
  撞车会明确报错而不是静默共用。
- **账号名与线路名共用一个命名空间**（uci section id 全局唯一），不能重名。

### 帐密
`/etc/campnet/.config`（0600）：`[default]` = `main` 账号；`[account:<id>]` = 其它账号。
仓库自带的 `.config.default` 是**空占位**，不含任何真实凭据。

---

## 常见问题

**认证一直失败？**
先看「插件日志」。若是 `auto` 探测出的门户类型不对，到「设置 → 基本」手动指定
`eportal` 或 `ruijie`；再不行就抓一次门户页面的表单，把字段填进「高级」。

**加了第二条线路，但速度没变？**
① 单线程下载本来就不会叠加；② 检查两条线路的 `mwan3 metric` 是否相同；
③ 学校可能限制同一账号的并发会话数（本插件默认每账号最多 2 条线路）。

**线路的 IP 会变？**
校园网 DHCP 租约较短时 IP 可能变化，会话随之失效，keeper 会在下一个周期自动重登。
想更快恢复就把「保活周期」调小。

**从旧版本升级后配置会不会丢？**
不会。首次启动会自动把 v0.x 的「账号即线路」配置迁移成新模型，
macvlan 设备名与已有的 mwan3 配置都保持不变。

---

## 说明

- 界面文案是**中文源文**（`_('中文')` 直接内联），没有单独维护 `.po` 翻译目录 ——
  面向中文用户场景够用；若要出多语言版本需要改为英文源文 + 翻译。
- 仓库只含插件本体。开发期的设计笔记、静态检查脚本与本地配置样例
  不进版本库（见 `.gitignore`）。

## 安全

- 帐密只存 `/etc/campnet/.config`（0600），**不写入 uci、不提交进仓库**；
  仓库里的 `.config.default` 是空占位模板。
- 日志对所有请求体脱敏（`passwd`/`password`/`userId`/`queryString`/`mac`/`wlanuserip`/`distoken` → `***`）。
- cookie 文件按**线路**隔离在 `/tmp`。

## License

[WTFPL 2.0](LICENSE) —— DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE.
