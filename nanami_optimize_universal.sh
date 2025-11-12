sudo bash -c 'cat > /usr/local/bin/nanami_optimize_universal.sh <<EOF
#!/bin/bash
echo "🌸 Nanami通用版优化开始啦～(〃>ω<〃)"

# 🧩 系统更新
apt-get update -y && apt-get upgrade -y

# 🧩 文件句柄上限
echo "* soft nofile 65535" >> /etc/security/limits.conf
echo "* hard nofile 65535" >> /etc/security/limits.conf
ulimit -n 65535

# 🧩 内核优化参数（适配所有 Ubuntu/Debian）
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

# 自动检测BBR / BBRx
if lsmod | grep -q "bbrx"; then
  echo "net.ipv4.tcp_congestion_control = bbrx" >> /etc/sysctl.conf
  echo "✅ 检测到 bbrx，已启用高级拥塞控制"
elif lsmod | grep -q "bbr"; then
  echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
  echo "✅ 检测到 bbr，已启用标准拥塞控制"
else
  echo "net.ipv4.tcp_congestion_control = cubic" >> /etc/sysctl.conf
  echo "⚠️ 未检测到bbr/bbrx，使用cubic默认算法"
fi

sysctl -p

# 🧩 关闭无用服务（跳过不存在的）
for svc in snapd apport bluetooth; do
  systemctl disable \$svc 2>/dev/null || true
done

# 🧩 启用 noatime 减少SSD写入
root_uuid=\$(findmnt -no UUID /)
if grep -q "\$root_uuid" /etc/fstab; then
  sed -i "s/\$root_uuid.*/\$root_uuid \/ ext4 defaults,noatime 0 1/" /etc/fstab
fi
mount -o remount /

# 🧩 安装常用监控工具
apt-get install -y htop iftop iotop curl wget vim

# 🧩 清理脚本 & 定时任务
cat <<CLEAN > /usr/local/bin/clean.sh
#!/bin/bash
apt-get autoremove -y
apt-get clean
rm -rf /var/log/*.log
journalctl --vacuum-time=7d
CLEAN

chmod +x /usr/local/bin/clean.sh
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/clean.sh >/dev/null 2>&1") | crontab -

echo "✨ 优化完成！建议重启生效哦～"
EOF'

sudo chmod +x /usr/local/bin/nanami_optimize_universal.sh
sudo /usr/local/bin/nanami_optimize_universal.sh
