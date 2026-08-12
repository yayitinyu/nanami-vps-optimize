# Nanami VPS Optimize

面向 **Ubuntu / Debian** 的 VPS **综合优化脚本**：官方 BBR、TCP/网络调优、资源限制、SWAP、磁盘与日常维护，交互式菜单一键或分项执行。

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

**一键全量故意不包含 SSH 改密/关密码**，避免误锁登录；需要时请单独选 **7** 或运行 `key.sh`。

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
| `-y` / `--yes` | 确认默认 yes |
| `--bandwidth <Mbps>` | 带宽（配合 `--all` / `--bbr`） |
| `--region asia\|overseas` | 亚太 / 美欧（影响缓冲大小） |

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
| 队列 | `tc qdisc … fq`，开机服务 `nanami-boot-apply` 恢复 |
| 起步窗口 | 默认路由 `initcwnd/initrwnd=32`（偏稳妥） |
| 分片 | iptables `TCPMSS --clamp-mss-to-pmtu` |
| 网卡 | `txqueuelen`；物理机尝试 ring；虚拟机可关 TSO/GSO/GRO |
| 安全基线 | 关闭 accept/send redirects、开启 rp_filter 等（非路由场景） |

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
| 物理机 | 支持（网卡 ring 调优更有意义） |
| LXC / OpenVZ / 多数容器 | **受限**（内核参数多由宿主机控制） |
| RHEL 系等 | 未作为一等公民；部分 apt 逻辑不适用 |

建议内存 **≥ 512MB**；更小内存会自动压低 TCP 缓冲与 dirty 写回阈值。

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

注意：`/swapfile` 与 fstab 中的 `noatime` 不会在卸载时强制回滚，需按需手动处理。备份文件常见后缀：`*.nanami.bak`。

---

## 安全提示

- 在生产机执行前做快照；改 SSH 时保持现有会话，另开窗口验证。
- 私钥输出后请离线妥善保存，勿贴到公开渠道。
- 本脚本不收集数据、不安装后门；请尽量从本仓库官方 raw 地址获取。

---

## 许可

MIT License © [yayitinyu](https://github.com/yayitinyu)
