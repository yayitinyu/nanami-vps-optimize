# 🌸 Nanami VPS Optimize Script

一键优化 Ubuntu / Debian VPS 性能的轻量脚本～  
由 [yayitinyu](https://github.com/yayitinyu) 开发 🩷  
支持 BBR / BBRx、KVM、SSD/NVMe、自动清理、内存与网络调优。

---

## ✨ 功能特色

- 💨 自动开启 BBR/BBRx 拥塞控制
- ⚙️ 优化 TCP Fast Open / 网络缓冲区
- 💾 启用 SSD noatime 减少写入
- 🧠 智能 SWAP 调优，减轻内存压力
- 🧹 每日自动清理系统缓存与日志
- 🧍‍♀️ 完美适配 Ubuntu / Debian KVM VPS

---

## 🚀 使用方法

```bash
wget https://raw.githubusercontent.com/yayitinyu/nanami-vps-optimize/main/nanami_optimize_universal.sh -O nanami_optimize_universal.sh
sudo bash nanami_optimize_universal.sh
````

运行完建议重启一次：

```bash
sudo reboot
```

如果要使用 `SSH 密钥生成` ：

```
wget -O key.sh https://raw.githubusercontent.com/yayitinyu/nanami-vps-optimize/refs/heads/main/key.sh && chmod +x key.sh && clear && ./key.sh
```

---

## 💬 说明

* 默认配置轻量安全，可在 `/etc/sysctl.conf` 中微调
* 适合内存 ≥ 1GB 的 VPS，低内存机型建议把 `swappiness` 改为 30
* 如果使用 OpenVZ/LXC 架构，部分优化项（如 BBRx）可能无效

---

## 🩵 许可

MIT License © [yayitinyu](https://github.com/yayitinyu)
