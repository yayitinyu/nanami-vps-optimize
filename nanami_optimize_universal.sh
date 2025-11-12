sudo bash -c 'cat > /usr/local/bin/nanami_optimize_auto_bbr.sh <<EOF
#!/bin/bash
echo "🌸 Nanami自动BBR优化启动中～(ฅ•ω•ฅ)"

# 🧩 系统更新
apt-get update -y && apt-get upgrade -y

# 🧩 文件句柄上限
echo "* soft nofile 65535" >> /etc/security/limits.conf
echo "* hard nofile 65535" >> /etc/security/limits.conf
ulimit -n 65535

# 🧩 内核与内存优化参数
cat <<SYSCTL > /etc/sysctl.conf
fs.file-max = 2097152
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
vm.swappiness = 10
vm.vfs_cache_pressure = 50
SYSCTL

# 🧠 自动检测并加载合适的 TCP 拥塞控制算法
if lsmod | grep -q "bbrx"; then
  echo "✅ 检测到 bbrx 模块，使用 bbrx"
  echo "net.ipv4.tcp_congestion_control = bbrx" >> /etc/sysctl.conf
  sysctl -w net.ipv4.tcp_congestion_control=bbrx
elif lsmod | grep -q "bbr"; then
  echo "✅ 检测到 bbr 模块，使用 bbr"
  echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
  sysctl -w net.ipv4.tcp_congestion_control=bbr
else
  echo "⚠️ 未检测到bbr模块，尝试加载中..."
  modprobe tcp_bbr 2>/dev/null
  if lsmod | grep -q "bbr"; then
    echo "✅ 成功加载 bbr 模块"
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -w net.ipv4.tcp_congestion_control=bbr
  else
    echo "❌ 无法加载 bbr，保持 cubic"
    echo "net.ipv4.tcp_congestion_control = cubic" >> /etc/sysctl.conf
  fi
fi

sysctl -p

# 🧩 开机自动检测脚本
cat <<AUTOBBR > /usr/local/bin/check_bbr.sh
#!/bin/bash
ALG=\$(sysctl -n net.ipv4.tcp_congestion_control)
if [ "\$ALG" != "bbr" ] && [ "\$ALG" != "bbrx" ]; then
  modprobe tcp_bbr 2>/dev/null
  sysctl -w net.ipv4.tcp_congestion_control=bbr
  echo "🌸 [Nanami Auto BBR] 自动切换为 bbr (\$(date))" >> /var/log/nanami_bbr.log
fi
AUTOBBR
chmod +x /usr/local/bin/check_bbr.sh

# 添加 systemd 服务，开机自动执行检测
cat <<SERVICE > /etc/systemd/system/nanami-bbr.service
[Unit]
Description=Nanami Auto BBR Checker
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/check_bbr.sh

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable nanami-bbr.service

# 🧩 启用 noatime（减少SSD写入）
root_uuid=\$(findmnt -no UUID /)
if grep -q "\$root_uuid" /etc/fstab; then
  sed -i "s/\$root_uuid.*/\$root_uuid \/ ext4 defaults,noatime 0 1/" /etc/fstab
fi
mount -o remount /

# 🧩 安装监控工具
apt-get install -y htop iftop iotop curl wget vim

# 🧹 定期清理脚本
cat <<CLEAN > /usr/local/bin/clean.sh
#!/bin/bash
apt-get autoremove -y
apt-get clean
rm -rf /var/log/*.log
journalctl --vacuum-time=7d
CLEAN
chmod +x /usr/local/bin/clean.sh
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/clean.sh >/dev/null 2>&1") | crontab -

echo "🌸 优化完成！自动BBR检测已启用～重启后更快更稳哦♡"
EOF'

sudo chmod +x /usr/local/bin/nanami_optimize_auto_bbr.sh
sudo /usr/local/bin/nanami_optimize_auto_bbr.sh
