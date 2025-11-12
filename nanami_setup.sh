#!/usr/bin/env bash
# 🌸 Nanami VPS Setup - AI少女登场版
# Author: Nanami & GPT-chan 💕
# Version: 2.0 (with animated intro + kawaii effects)
# 功能：一键更新系统、安装常用工具、设置时区、系统调优、开启BBRX、生成密钥

set -euo pipefail
IFS=$'\n\t'

# --- 🌈 颜色定义 ---
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
PINK="\033[1;35m"
CYAN="\033[0;36m"
WHITE="\033[1;37m"
RESET="\033[0m"

# --- 💫 动态输出 ---
say() {
  local msg="$1"
  echo -e "${PINK}💫 Nanami酱：${RESET}${msg}"
  sleep 0.4
}

spinner() {
  local pid=$!
  local delay=0.12
  local spin=('🌸' '🌷' '🌺' '🌼' '🌹' '💮')
  while ps -p $pid >/dev/null 2>&1; do
    for i in "${spin[@]}"; do
      echo -ne "  ${PINK}$i${RESET} ${YELLOW}处理中...${RESET}\r"
      sleep $delay
    done
  done
  echo -ne "                                \r"
}

# --- 💖 开场动画 ---
intro_animation() {
  clear
  echo -e "\n"
  sleep 0.3
  echo -e "${PINK}         ✨╭────────────╮✨${RESET}"
  sleep 0.1
  echo -e "${PINK}         │ ${WHITE}NANAMI VPS SETUP${PINK} │${RESET}"
  sleep 0.1
  echo -e "${PINK}         ╰────────────╯✨${RESET}"
  sleep 0.2
  echo -e "${CYAN}          ｡･ﾟﾟ･💗･ﾟﾟ･｡${RESET}"
  sleep 0.3
  echo -e "${WHITE}     (❁´◡`❁) ${PINK}嗨嗨～我是 Nanami酱～${RESET}"
  sleep 0.3
  echo -e "${WHITE}   今天我来帮你打理 VPS 哦～ฅ(≧▽≦)ฅ${RESET}"
  sleep 0.3
  echo -e "${CYAN}          开始前…先准备小魔法粉✨${RESET}"
  echo -e "\n"
  sleep 1.2
}

# --- ⚙️ 配置参数 ---
TUNE_URL="https://raw.githubusercontent.com/jerry048/Tune/main/tune.sh"
KEY_URL="https://raw.githubusercontent.com/yuju520/Script/main/key.sh"

ASSUME_YES=false
DO_UPDATE=true
DO_INSTALL=true
DO_TZ=true
DO_TUNE=true
DO_BBRX=true
DO_KEY=true

for arg in "$@"; do
  case "$arg" in
    --skip-bbr|--skip-bbrx) DO_BBRX=false ;;
    --skip-key) DO_KEY=false ;;
    --yes|-y) ASSUME_YES=true ;;
  esac
done

confirm() {
  if $ASSUME_YES; then return 0; fi
  read -rp "$(echo -e "${YELLOW}是否执行 ${1}? [y/N]: ${RESET}")" ans
  [[ $ans == [Yy]* ]]
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}必须以root身份运行哦～(＞﹏＜)${RESET}"
    exit 1
  fi
}

# --- 🍀 各功能模块 ---
update_system() {
  say "开始更新系统包～✨"
  (apt update -y && apt upgrade -y) & spinner
  say "系统更新完成～"
}

install_tools() {
  say "安装常用工具：sudo curl wget nano ✨"
  (apt install -y sudo curl wget nano ca-certificates apt-transport-https gnupg lsb-release) & spinner
  say "常用工具安装完毕！"
}

set_timezone() {
  say "将时区设置为 ${CYAN}Asia/Shanghai${RESET} ⏰"
  (timedatectl set-timezone Asia/Shanghai) & spinner
  say "时区设置完成～当前时间是：${YELLOW}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
}

sys_tune() {
  say "正在为你写入系统优化参数喵～"
  SYSCTL_FILE="/etc/sysctl.d/99-nanami.conf"
  cat > "$SYSCTL_FILE" <<'EOF'
fs.file-max = 2097152
net.core.somaxconn = 65535
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
EOF
  (sysctl --system >/dev/null) & spinner
  say "基础系统参数写入完成～"

  say "要不要试试远程 Tune 脚本进行深度调优呢？🌸"
  if confirm "执行 ${TUNE_URL} (-t)"; then
    (bash <(wget -qO- "$TUNE_URL") -t) & spinner
    say "远程系统调优完成啦～"
  else
    say "跳过远程调优喵～"
  fi
}

enable_bbrx() {
  if ! $DO_BBRX; then return; fi
  say "准备为你开启 BBRX 加速引擎💨"
  if confirm "执行 ${TUNE_URL} (-x)"; then
    (bash <(wget -qO- "$TUNE_URL") -x) & spinner
    say "BBRX 加速模块启动完成！(๑•̀ㅂ•́)و✧"
  else
    say "好吧，那就暂时不启用～"
  fi
}

generate_key() {
  if ! $DO_KEY; then return; fi
  say "现在来生成你的专属密钥～🔑"
  if confirm "执行 ${KEY_URL}"; then
    tmpd="$(mktemp -d)"
    cd "$tmpd"
    (wget -qO key.sh "$KEY_URL" && chmod +x key.sh && ./key.sh) & spinner
    cd - >/dev/null
    rm -rf "$tmpd"
    say "密钥生成完成～请妥善保存！💌"
  else
    say "那就跳过这步吧～"
  fi
}

# --- 🧁 主流程 ---
main() {
  intro_animation
  require_root
  say "检查完毕～身份正确！💪"
  say "Nanami酱现在要开始帮你动工啦～"

  update_system
  install_tools
  set_timezone
  sys_tune
  enable_bbrx
  generate_key

  echo -e "\n${GREEN}✨ 所有步骤都顺利完成啦～ VPS 优化完毕 💫${RESET}"
  echo -e "${YELLOW}记得重启一次系统，让优化生效哦～${RESET}"
  echo -e "${PINK}（Nanami酱眨眼：辛苦啦♡ 服务器现在会变得又快又稳哦～）${RESET}\n"
}

main "$@"
