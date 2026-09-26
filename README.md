# Nanami VPS Optimize

面向 **Ubuntu / Debian VPS 与独立服务器** 的综合优化脚本：官方 BBR、TCP/网络调优、资源限制、SWAP、磁盘与日常维护，交互式菜单一键或分项执行。

> 版本 **2.0** 起：**仅使用内核官方 BBR**（`tcp_bbr`），已移除不可靠/难维护的 **BBRx**；配置写入 drop-in，不再整文件覆盖 `/etc/sysctl.conf`。

网络与 BBR 调优思路参考了优秀开源实践：

- [Eric86777/vps-tcp-tune](https://github.com/Eric86777/vps-tcp-tune)（带宽/地区 BDP 缓冲、`fq`、initcwnd、MSS clamp 等）
- [jerry048/Tune](https://github.com/jerry048/Tune)（按内存分层 sysctl、limits、网卡/boot 辅助、更安全的 drop-in 写法）

---

## 功能一览

| 菜单 | 功能 | 说明 |
|------|------|------|
| **0** | **一键全量优化** | 依次执行 1–6（不含 SSH 密钥） |
| 1 | 官方 BBR + TCP/网络调优 | 核心：`bbr` + `fq`、BDP 缓冲、sysctl、网卡与开机恢复 |
| 2 | 系统资源限制 | `nofile` / systemd `DefaultLimitNOFILE` |
| 3 | 内存与 SWAP | 按内存智能推荐 `/swapfile` |
| 4 | 磁盘优化 | 根分区 `noatime`，减少无效写入 |
| 5 | 常用工具 | `htop` / `iftop` / `iotop` / `curl` 等 |
| 6 | 定时清理 | 每日 03:00 清理 apt 缓存与旧日志 |
| 7 | SSH 密钥登录 | 生成 ed25519、写 `authorized_keys`（可选关密码） |
| 8 | 查看状态 | 拥塞控制、缓冲、路由、SWAP 等 |
| 9 | 卸载还原 | 移除本脚本写入的配置与服务 |
| 10 | GitHub Hosts | 可选：立即更新并配置每日自动更新 |
| 11 | APT 换源 | 可选：选择镜像、查看列表、恢复备份 |

**一键全量故意不包含 SSH 改密/关密码**，避免误锁登录；需要时请单独选 **7** 或运行 `key.sh`。
**GitHub Hosts 也不属于一键全量**，只有选择菜单 **10** 或使用专用参数时才会启用。
**APT 换源也不属于一键全量**，只有选择菜单 **11** 或使用专用参数时才会启动。

定时清理优先复用正在运行且开机启用的 cron。若缺少 `crontab` 命令或 cron 服务不可用，且系统运行 systemd，则改用 `nanami-clean.timer`，仍在服务器本地时间每日 03:00 执行。`--uninstall` 会移除本脚本创建的 cron 条目或 timer；两种调度器都不可用时会明确报错。若缺少 `crontab` 命令但检测到旧版 root crontab 条目，脚本会停止切换并提示修复，避免重复清理。

---

## 快速开始

```bash
# 下载并运行（交互菜单）
wget -O nanami_optimize_universal.sh \
  https://raw.githubusercontent.com/yayitinyu/nanami-vps-optimize/main/nanami_optimize_universal.sh
sudo bash nanami_optimize_universal.sh
```

或：

```bash
curl -fsSL -o nanami_optimize_universal.sh \
  https://raw.githubusercontent.com/yayitinyu/nanami-vps-optimize/main/nanami_optimize_universal.sh
sudo bash nanami_optimize_universal.sh
```

### 非交互 / 命令行

```bash
# 一键全量（默认带宽 1000Mbps、亚太地区）
sudo bash nanami_optimize_universal.sh --all -y

# 仅 BBR + 网络，指定带宽与跨洋地区
sudo bash nanami_optimize_universal.sh --bbr --bandwidth 500 --region overseas -y

# GitHub Hosts：启用每日更新、手动更新、停用
sudo bash nanami_optimize_universal.sh --github-hosts
sudo bash nanami_optimize_universal.sh --github-hosts-update
sudo bash nanami_optimize_universal.sh --github-hosts-disable -y

# APT 换源（交互选择）、查看镜像、恢复最近一次备份
sudo bash nanami_optimize_universal.sh --apt-sources
sudo bash nanami_optimize_universal.sh --apt-sources-list
sudo bash nanami_optimize_universal.sh --apt-sources-restore

# 查看状态 / 卸载
sudo bash nanami_optimize_universal.sh --status
sudo bash nanami_optimize_universal.sh --uninstall
```

| 参数 | 含义 |
|------|------|
| `--all` | 一键 1–6 |
| `--bbr` | 仅网络/BBR |
| `--limits` / `--swap` / `--disk` / `--tools` / `--clean` / `--ssh-key` | 分项 |
| `--status` / `--uninstall` | 状态 / 卸载 |
| `--github-hosts` / `--github-hosts-update` / `--github-hosts-disable -y` | 启用每日更新 / 立即更新 / 停用并移除本脚本条目 |
| `--github-hosts-status` | 仅查看 GitHub Hosts 状态 |
| `--apt-sources` / `--apt-sources-list` / `--apt-sources-restore` | APT 换源菜单 / 镜像列表 / 恢复最近一次源备份 |
| `-y` / `--yes` | 确认默认 yes |
| `--bandwidth <Mbps>` | 带宽（配合 `--all` / `--bbr`） |
| `--region asia\|overseas` | 亚太 / 美欧（影响缓冲大小） |

---

## GitHub Hosts（可选）

选择菜单 **10 → 1** 或运行 `--github-hosts` 后，脚本从 [maxiaof/github-hosts](https://github.com/maxiaof/github-hosts) 的 [hosts 文件](https://raw.githubusercontent.com/maxiaof/github-hosts/master/hosts) 获取条目，立即更新一次，并在 `/etc/cron.d/nanami-github-hosts` 设置**每日 04:25（服务器本地时间）**自动更新。需要 `curl`、`cron` 和 `flock`；启用时会安装缺少的依赖并启动 cron 服务。

脚本只维护 `/etc/hosts` 中 `# Nanami GitHub Hosts BEGIN` 与 `# Nanami GitHub Hosts END` 之间的内容；其他条目保留。下载失败或格式校验失败时不会改动 `/etc/hosts`；首次下载失败时定时任务仍会保留，之后按计划重试。首次更新前和每次改动前的备份保存在 `/etc/nanami-optimize/`。若 `/etc/hosts` 前面已有同域名的自定义映射，它们可能优先生效，请自行检查。

`--github-hosts-update` 只更新一次，不开启定时任务。菜单 **10 → 3** 或 `--github-hosts-disable -y` 会移除定时任务和本脚本管理的区块；`--uninstall` 也会移除它们。自动更新记录在 `/var/log/nanami-optimize/github-hosts.log`。

推送到 `main` 或提交 Pull Request 时，CI 会检查 Bash 语法，运行 Hosts、APT 入口、物理机调优与卸载恢复隔离测试，并在 Debian 和 Ubuntu 容器中运行定时清理 smoke test。

---

## APT 换源（可选）

菜单 **11** 或 `--apt-sources` 会启动固定在 `a094549` 版本的 [change-apt-src.sh](https://github.com/yayitinyu/apt)。脚本下载后先校验 SHA-256，再运行；需要 `curl` 或 `wget`。该工具会识别 Debian/Ubuntu 版本与架构，支持官方源、国内/地区镜像、自定义 URL，以及 DEB822 格式。更换前需要手动确认，原配置保存在 `/var/backups/apt-src/`；`apt-get update` 失败时会尝试自动恢复。

`--apt-sources-list` 只列出可用源；`--apt-sources-restore` 会在确认后恢复最近一次备份。换源只处理系统 APT 源，其他第三方源（例如 Docker）不会作为镜像目标。`--uninstall` 不恢复 APT 源，请使用独立的恢复入口。

---

## 推荐流程

1. 快照或可登录的救援控制台（改网络/SSH 前保险）。
2. 运行脚本，选 **0 一键全量**，或先 **1** 做 BBR/网络。
3. 带宽选真实上行（不清楚时用 **500M–1G** 档通常较稳）；跨洋业务选 **美国/欧洲** 地区以加大缓冲。
4. 需要密钥登录时再选 **7** 或：

```bash
wget -O key.sh https://raw.githubusercontent.com/yayitinyu/nanami-vps-optimize/main/key.sh
chmod +x key.sh && sudo ./key.sh
```

5. 若提示 systemd 句柄限制等未完全生效，执行一次：

```bash
sudo reboot
```

---

## BBR 与网络调优说明

### 官方 BBR only

- 使用内核模块 **`tcp_bbr`** 与 `net.ipv4.tcp_congestion_control=bbr`
- 默认队列 **`fq`**（`net.core.default_qdisc=fq`），与 BBR 搭配更合适
- 开机通过 `/etc/modules-load.d/nanami-bbr.conf` 加载模块
- **不**安装第三方内核、**不**启用 BBRx

> 需要 **Linux 4.9+** 且内核编译了 BBR（常见 Ubuntu/Debian 云镜像 5.x/6.x 均具备）。若 `sysctl` 显示无 `bbr`，请升级内核，而非寻找 BBRx。

### 调优要点（摘要）

| 项 | 做法 |
|----|------|
| TCP 缓冲 | 按 **带宽 × 地区 RTT（BDP）** 估算 `rmem`/`wmem`，并按内存封顶防 OOM |
| 吞吐行为 | `tcp_slow_start_after_idle=0`、`tcp_mtu_probing=1`、`tcp_fastopen=3` |
| 延迟相关 | `tcp_notsent_lowat`、合理 `fin_timeout` / keepalive |
| 队列 | 仅在默认出口网卡尚未使用 `fq` 时设置，开机服务 `nanami-boot-apply` 恢复 |
| 起步窗口 | 默认路由 `initcwnd/initrwnd=32`（偏稳妥） |
| 分片 | iptables `TCPMSS --clamp-mss-to-pmtu` |
| 网卡 | `txqueuelen`；物理机仅在 ring 低于目标且硬件支持时增大；虚拟机可关 TSO/GSO/GRO |
| 安全基线 | 关闭 accept/send redirects；按 IPv4 转发状态选择 strict 或 loose `rp_filter` |

配置主文件：

```text
/etc/sysctl.d/99-nanami-optimize.conf
/etc/security/limits.d/99-nanami.conf
/etc/systemd/system.conf.d/99-nanami.conf
/usr/local/sbin/nanami-boot-apply
/etc/systemd/system/nanami-boot-apply.service
```

---

## 适用环境

| 环境 | 支持情况 |
|------|----------|
| Ubuntu / Debian + KVM/ Xen 等完整虚拟化 | **推荐** |
| 物理机 | 支持；检测已有队列与网卡 ring 配置，避免重复重设 |
| LXC / OpenVZ / 多数容器 | **受限**（内核参数多由宿主机控制） |
| RHEL 系等 | 未作为一等公民；部分 apt 逻辑不适用 |

建议内存 **≥ 512MB**；更小内存会自动压低 TCP 缓冲与 dirty 写回阈值。

运行 Docker 或其他转发服务时，网络配置会将 `rp_filter` 设为 loose 模式；未启用 IPv4 转发时使用 strict 模式。新版不再强制设置 `vm.overcommit_memory` 或固定较低的 `tcp_max_tw_buckets`。旧版已应用的运行时值需在重启后才会回到系统默认值，或由管理员按自身工作负载调整。

---

## 与旧版差异

| 旧版 (1.x) | 新版 (2.0) |
|------------|------------|
| BBRx / BBR 混用探测 | **仅官方 BBR** |
| 整文件覆盖 `/etc/sysctl.conf` | **`sysctl.d` drop-in**，并注释冲突项 |
| 无菜单，一条龙脚本 | **交互菜单 + CLI 分项** |
| 固定缓冲参数 | **带宽 + 地区 BDP + 内存分层** |
| 清理脚本 `rm /var/log/*.log` | 更安全的 journal / 轮转日志清理 |
| SSH 直接关密码 | 默认只开公钥；关密码需二次确认 |

---

## 故障排查

```bash
# 是否已是 bbr + fq
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
sysctl net.ipv4.tcp_available_congestion_control

# 缓冲是否生效
sysctl net.core.rmem_max net.core.wmem_max

# 开机网络恢复服务
systemctl status nanami-boot-apply.service
journalctl -u nanami-boot-apply.service -n 50

# 脚本运行日志
sudo less /var/log/nanami-optimize/run.log
```

卸载本脚本配置：

```bash
sudo bash nanami_optimize_universal.sh --uninstall
```

此命令会要求确认；无人值守执行时需显式加 `-y`。

新版安装会在 `/etc/nanami-optimize/` 记录本脚本创建的 `/swapfile`、追加的 fstab SWAP 条目、根分区 fstab 原行与修改后行，以及即时 remount 前的 atime 模式。卸载时先核对记录：仅停用并删除身份仍匹配的 `/swapfile`，只撤销本脚本添加的 fstab 行和 `noatime`，并尽力恢复原运行时 atime 模式。独立的 VM sysctl 文件也只在内容未被改动时移除。重复执行卸载不会再次修改这些配置。

已有的 `/swapfile`、fstab SWAP/noatime 条目和 VM sysctl 文件不会被覆盖。若安装后有人修改了受管理文件或同一 fstab 行，卸载会保留它们及恢复记录、返回错误，待检查后可重试。停用 SWAP 或即时 remount 失败时也会保留相应记录。旧版安装没有归属记录，无法可靠区分脚本和用户的改动，需人工核对；`*.nanami.bak` 仅供参考，不会整文件覆盖当前 fstab。已创建的 `/swapfile` 再次运行时不会自动调整大小，以免丢失可恢复状态。

---

## 安全提示

- 在生产机执行前做快照；改 SSH 时保持现有会话，另开窗口验证。
- 私钥输出后请离线妥善保存，勿贴到公开渠道。
- 本脚本不收集数据、不安装后门；请尽量从本仓库官方 raw 地址获取。

---

## 许可

MIT License © [yayitinyu](https://github.com/yayitinyu)
