#!/usr/bin/env bash
#=============================================================================
# Nanami SSH Key Helper
# 生成密钥、写入 authorized_keys，可选禁用密码登录
# 更完整的综合优化请使用：nanami_optimize_universal.sh（菜单 7）
#=============================================================================

set -Euo pipefail

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RESET="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WARN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INFO="$(tput setaf 6)"
else
    C_RESET=""; C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""
fi

ok()   { printf '%b%s%b\n' "$C_OK" "$*" "$C_RESET"; }
warn() { printf '%b%s%b\n' "$C_WARN" "$*" "$C_RESET" >&2; }
err()  { printf '%b%s%b\n' "$C_ERR" "$*" "$C_RESET" >&2; }
info() { printf '%b%s%b\n' "$C_INFO" "$*" "$C_RESET"; }

confirm() {
    local prompt="$1" default="${2:-n}" answer
    if [[ "$default" == "y" ]]; then
        read -r -p "${prompt} [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -r -p "${prompt} [y/N]: " answer
        answer="${answer:-n}"
    fi
    case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

SSH_DIR="${HOME}/.ssh"
KEY_TYPE="ed25519"
KEY_PATH="${SSH_DIR}/id_ed25519"
PUB_PATH="${KEY_PATH}.pub"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "$KEY_PATH" ]]; then
    ok "SSH 密钥已存在：${KEY_PATH}"
elif [[ -f "${SSH_DIR}/id_rsa" ]]; then
    ok "检测到已有 RSA 密钥，复用：${SSH_DIR}/id_rsa"
    KEY_PATH="${SSH_DIR}/id_rsa"
    PUB_PATH="${KEY_PATH}.pub"
else
    info "正在生成 ${KEY_TYPE} 密钥..."
    ssh-keygen -t "$KEY_TYPE" -f "$KEY_PATH" -q -N "" -C "nanami@$(hostname -s 2>/dev/null || echo vps)"
    ok "已生成：${KEY_PATH}"
fi

touch "${SSH_DIR}/authorized_keys"
chmod 600 "${SSH_DIR}/authorized_keys"
chmod 700 "$SSH_DIR"

if [[ -f "$PUB_PATH" ]]; then
    if ! grep -qF "$(cat "$PUB_PATH")" "${SSH_DIR}/authorized_keys" 2>/dev/null; then
        cat "$PUB_PATH" >> "${SSH_DIR}/authorized_keys"
        ok "公钥已写入 authorized_keys"
    else
        info "公钥已在 authorized_keys 中"
    fi
fi

# 启用公钥认证（优先 drop-in，避免整文件 sed 误伤）
if [[ "$(id -u)" -eq 0 ]] && [[ -d /etc/ssh/sshd_config.d ]]; then
    cat > /etc/ssh/sshd_config.d/99-nanami-pubkey.conf <<'EOF'
PubkeyAuthentication yes
EOF
    if command -v sshd >/dev/null 2>&1 && sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
            || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        ok "已启用 PubkeyAuthentication"
    else
        warn "sshd 配置校验失败，请手动检查 /etc/ssh/sshd_config.d/"
    fi
elif [[ "$(id -u)" -eq 0 ]]; then
    if [[ -f /etc/ssh/sshd_config ]]; then
        cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/g' /etc/ssh/sshd_config
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
            || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        ok "已在 sshd_config 中启用公钥认证"
    fi
else
    warn "非 root：跳过 sshd 配置修改。可执行: sudo bash $0"
fi

echo
warn "请立即将以下私钥保存到本地安全位置，勿泄露："
echo "========== PRIVATE KEY =========="
cat "$KEY_PATH"
echo "================================="
echo
info "公钥路径: ${PUB_PATH}"
echo

if [[ "$(id -u)" -eq 0 ]]; then
    if confirm "是否在确认密钥可登录后禁用密码认证？（危险操作，默认否）" "n"; then
        if [[ -d /etc/ssh/sshd_config.d ]]; then
            cat > /etc/ssh/sshd_config.d/99-nanami-keyonly.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
            if sshd -t 2>/dev/null; then
                systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
                    || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
                ok "已禁用密码登录。请保持当前会话并另开窗口验证密钥登录！"
            else
                rm -f /etc/ssh/sshd_config.d/99-nanami-keyonly.conf
                err "sshd -t 失败，未禁用密码登录。"
            fi
        else
            sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/g' /etc/ssh/sshd_config
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
            ok "已尝试禁用密码登录。"
        fi
    else
        info "保留密码登录。"
    fi
fi

ok "完成。"
