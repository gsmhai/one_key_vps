#!/bin/bash

# ==================================================================
# ！！！请在这里修改为你自己想要的面板用户名和密码！！！
PANEL_USER="admin"        # 面板登录用户名 (默认已设为 admin)
PANEL_PASS="admin"        # 面板登录密码 (默认已设为 admin)
# ==================================================================

# 预设随机端口
RANDOM_PANEL_PORT=$((RANDOM % 10000 + 40000))
NODE_PORT=$((RANDOM % 10000 + 50000))

echo "===================================================="
echo "🚀 正在全自动安装 3x-ui 并通过系统菜单重置账号..."
echo "===================================================="

# 1. 基础依赖安装
echo -e "\n[1/6] 正在安装系统依赖..."
dnf update -y > /dev/null 2>&1
dnf install epel-release -y > /dev/null 2>&1
dnf install curl wget sqlite expect firewalld coreutils -y > /dev/null 2>&1

# 2. 执行安装脚本
echo -e "\n[2/6] 正在启动 3x-ui 安装流程..."
export PANEL_USER PANEL_PASS RANDOM_PANEL_PORT
cat << 'EOF' > install_xui.exp
#!/usr/bin/expect -f
set timeout 300
spawn bash -c "bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
expect {
    -re "customize.*y/n" { send "y\r"; exp_continue }
    -nocase -re "panel port:" { send "$env(RANDOM_PANEL_PORT)\r"; exp_continue }
    -nocase -re "account name:" { send "$env(PANEL_USER)\r"; exp_continue }
    -nocase -re "account password:" { send "$env(PANEL_PASS)\r"; exp_continue }
    -re "default 2 for IP" { send "2\r"; exp_continue }
    -re "IPv6 address" { send "\r"; exp_continue }
    -nocase -re "ACME HTTP-01" { send "80\r"; exp_continue }
    eof
}
EOF
chmod +x install_xui.exp
./install_xui.exp

# 3. 【核心修复】全流程捕获重置面板密码
echo -e "\n[3/6] 正在通过 x-ui 内部管理菜单强制重置账号密码..."
cat << 'EOF' > reset_cred.exp
#!/usr/bin/expect -f
set timeout 10
spawn x-ui

# 固定前置流程
expect -re "(selection|选择)" { send "6\r" }
expect -re "(sure|确认)" { send "y\r" }
expect -re "(username|用户名|帐号|账号)" { send "$env(PANEL_USER)\r" }
expect -re "(password|密码)" { send "$env(PANEL_PASS)\r" }

# 处理结尾随机出现的 2FA 和重启提示 (动态循环捕获)
expect {
    -re "(two-factor|双因素|2FA)" { 
        send "y\r"
        exp_continue 
    }
    -nocase -re "(restart the panel|重启面板)" { 
        send "y\r"
        # 发送完 y 后，直接等待最后的回车提示，不再循环
        expect -re "(return|返回|enter|回车)" { send "\r" }
        exit 0
    }
    -re "(return|返回|enter|回车)" { 
        send "\r"
        exit 0 
    }
    timeout { exit 0 }
    eof { exit 0 }
}
EOF
# 强制更新面板端口
# sqlite3 $DB_PATH "UPDATE settings SET value = '$RANDOM_PANEL_PORT' WHERE key = 'panelPort' OR key = 'port' OR key = 'webPort';"

chmod +x reset_cred.exp
./reset_cred.exp
rm -f install_xui.exp reset_cred.exp

# 4. 注入代理节点
echo -e "\n[4/6] 正在注入代理节点..."
systemctl stop x-ui
sleep 2
DB_PATH="/etc/x-ui/x-ui.db"
UUID=$(cat /proc/sys/kernel/random/uuid)
SUB_ID=$(cat /proc/sys/kernel/random/uuid | tr -d '-')

# ==================================================================
# 【默认生效】 VMESS 节点配置注入
SETTINGS="{\"clients\":[{\"id\":\"$UUID\",\"alterId\":0,\"email\":\"vmess_$UUID\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":\"\",\"subId\":\"$SUB_ID\"}],\"disableInsecureEncryption\":false}"
STREAM_SETTINGS="{\"network\":\"tcp\",\"security\":\"none\",\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}"
SNIFFING="{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}"

sqlite3 $DB_PATH "DELETE FROM inbounds WHERE remark = 'Auto_VMESS_Node';"
sqlite3 $DB_PATH "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (1, 0, 0, 0, 'Auto_VMESS_Node', 1, 0, '', $NODE_PORT, 'vmess', '$SETTINGS', '$STREAM_SETTINGS', 'inbound-$NODE_PORT', '$SNIFFING');"

# ==================================================================
# 【备用方案】 VLESS 节点配置注入 
# 如果你需要改为 VLESS，请将上方 VMESS 的三个 sqlite3 语句注释掉，并解除下方代码的注释：
#
# VLESS_SETTINGS="{\"clients\":[{\"id\":\"$UUID\",\"flow\":\"\",\"email\":\"vless_$UUID\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":\"\",\"subId\":\"$SUB_ID\"}],\"decryption\":\"none\",\"fallbacks\":[]}"
# VLESS_STREAM="{\"network\":\"tcp\",\"security\":\"none\",\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}"
# VLESS_SNIFFING="{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}"
#
# sqlite3 $DB_PATH "DELETE FROM inbounds WHERE remark = 'Auto_VLESS_Node';"
# sqlite3 $DB_PATH "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (1, 0, 0, 0, 'Auto_VLESS_Node', 1, 0, '', $NODE_PORT, 'vless', '$VLESS_SETTINGS', '$VLESS_STREAM', 'inbound-$NODE_PORT', '$VLESS_SNIFFING');"
# ==================================================================

systemctl start x-ui
sleep 2

# 5. 读取真实配置
echo -e "\n[5/6] 正在从数据库校验最终配置..."
REAL_PANEL_PORT=$(sqlite3 $DB_PATH "SELECT value FROM settings WHERE key='port' OR key='panelPort' OR key='webPort' LIMIT 1;")
REAL_BASE_PATH=$(sqlite3 $DB_PATH "SELECT value FROM settings WHERE key='webBasePath';" | tr -d '"')
PUBLIC_IP=$(curl -s ifconfig.me || curl -s ipv4.icanhazip.com)

# 6. 防火墙策略
echo -e "\n[6/6] 正在配置系统防火墙放行端口..."
systemctl enable firewalld --now > /dev/null 2>&1
firewall-cmd --zone=public --add-port=80/tcp --permanent > /dev/null 2>&1
firewall-cmd --zone=public --add-port=${REAL_PANEL_PORT}/tcp --permanent > /dev/null 2>&1
firewall-cmd --zone=public --add-port=${NODE_PORT}/tcp --permanent > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1

# 生成分享链接
VMESS_JSON="{\"v\":\"2\",\"ps\":\"Auto_VMESS_Node\",\"add\":\"${PUBLIC_IP}\",\"port\":\"${NODE_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\",\"fp\":\"\"}"
SHARE_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
SUB_URL="https://${PUBLIC_IP}:${REAL_PANEL_PORT}${REAL_BASE_PATH}sub/${SUB_ID}"

# ==================================================================
# 备用 VLESS 链接生成 
# VLESS_SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${NODE_PORT}?encryption=none&security=none&type=tcp#Auto_VLESS_Node"
# ==================================================================

echo ""
echo "===================================================="
echo "🎉 部署完成！账号已通过内部菜单强制重置成功。"
echo "===================================================="
echo "🌐 【Web 面板地址】"
echo "▶ 地址: https://${PUBLIC_IP}:${REAL_PANEL_PORT}${REAL_BASE_PATH}"
echo "▶ 账号: $PANEL_USER"
echo "▶ 密码: $PANEL_PASS"
echo "----------------------------------------------------"
echo "🚀 【单节点链接】"
echo -e "\033[32m$SHARE_LINK\033[0m"
# ==================================================================
# 备用 VLESS 终端输出
# echo "----------------------------------------------------"
# echo "🚀 【备用 VLESS 单节点链接】"
# echo -e "\033[32m$VLESS_SHARE_LINK\033[0m"
# ==================================================================
echo "----------------------------------------------------"
echo "📡 【通用订阅链接】"
echo -e "\033[36m$SUB_URL\033[0m"
echo "===================================================="
