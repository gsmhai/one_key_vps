#!/bin/bash

# ==================================================================
# ！！！请在这里修改为你自己想要的面板用户名和密码！！！
PANEL_USER="admin"        # 面板登录用户名
PANEL_PASS="admin"  # 面板登录密码
# ==================================================================

# 自动生成随机端口，避免冲突和特征探测
PANEL_PORT=$((RANDOM % 10000 + 40000)) # 生成 40000-49999 之间的随机面板端口
NODE_PORT=$((RANDOM % 10000 + 50000))  # 生成 50000-59999 之间的随机节点端口

echo "===================================================="
echo "🚀 正在开始全自动安装 3x-ui 及 VMESS 代理节点..."
echo "👤 预设面板用户名: $PANEL_USER"
echo "🔑 预设面板密码: $PANEL_PASS"
echo "🚪 预设面板端口: $PANEL_PORT"
echo "🔌 预设节点端口: $NODE_PORT"
echo "===================================================="

# 1. 安装必要的工具库
echo -e "\n[1/5] 正在安装系统依赖 (sqlite, expect, firewalld, base64)..."
dnf update -y > /dev/null 2>&1
dnf install epel-release -y > /dev/null 2>&1
dnf install curl wget sqlite expect firewalld coreutils -y > /dev/null 2>&1

# 2. 配置 CentOS 9.4 严格的防火墙
echo -e "\n[2/5] 正在配置防火墙并放行 80、面板和节点端口..."
systemctl enable firewalld --now > /dev/null 2>&1
firewall-cmd --zone=public --add-port=80/tcp --permanent > /dev/null 2>&1
firewall-cmd --zone=public --add-port=$PANEL_PORT/tcp --permanent > /dev/null 2>&1
firewall-cmd --zone=public --add-port=$NODE_PORT/tcp --permanent > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1

# 3. 使用 expect 自动化安装 3x-ui 并申请 IP HTTPS 证书
echo -e "\n[3/5] 正在自动化安装 3x-ui 并申请 IP 证书 (此过程大约需要 1-2 分钟)..."
export PANEL_USER PANEL_PASS PANEL_PORT

cat << 'EOF' > install_xui.exp
#!/usr/bin/expect -f
set timeout -1
spawn bash -c "bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"

expect {
    "*customize*" { send "y\r"; exp_continue }
    "*panel port:*" { send "$env(PANEL_PORT)\r"; exp_continue }
    "*Panel port:*" { send "$env(PANEL_PORT)\r"; exp_continue }
    "*ccount name:*" { send "$env(PANEL_USER)\r"; exp_continue }
    "*ccount password:*" { send "$env(PANEL_PASS)\r"; exp_continue }
    "*(default 2 for IP):*" { send "2\r"; exp_continue }
    "*IPv6 address to include*" { send "\r"; exp_continue }
    eof
}
EOF
chmod +x install_xui.exp
./install_xui.exp
rm -f install_xui.exp

# 4. 在数据库中自动注入代理节点
echo -e "\n[4/5] 正在通过底层数据库直接创建节点与订阅..."
systemctl stop x-ui
sleep 2

# 统一生成 UUID 和 订阅 ID
UUID=$(cat /proc/sys/kernel/random/uuid)
SUB_ID=$(cat /proc/sys/kernel/random/uuid | tr -d '-')

# ==================================================================
# 【默认生效】 VMESS 节点配置注入
# 注意：包含 subId 参数用于生成订阅链接
SETTINGS="{\"clients\":[{\"id\":\"$UUID\",\"alterId\":0,\"email\":\"vmess_$UUID\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":\"\",\"subId\":\"$SUB_ID\"}],\"disableInsecureEncryption\":false}"
STREAM_SETTINGS="{\"network\":\"tcp\",\"security\":\"none\",\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}"
SNIFFING="{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}"

sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (1, 0, 0, 0, 'Auto_VMESS_Node', 1, 0, '', $NODE_PORT, 'vmess', '$SETTINGS', '$STREAM_SETTINGS', 'inbound-$NODE_PORT', '$SNIFFING');"

# ==================================================================
# 【备用方案】 VLESS 节点配置注入 (默认被注释)
# 如果你需要改为 VLESS，请将上方 VMESS 的 sqlite3 语句注释掉，并解除下方代码的注释：
#
# VLESS_SETTINGS="{\"clients\":[{\"id\":\"$UUID\",\"flow\":\"\",\"email\":\"vless_$UUID\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":\"\",\"subId\":\"$SUB_ID\"}],\"decryption\":\"none\",\"fallbacks\":[]}"
# VLESS_STREAM="{\"network\":\"tcp\",\"security\":\"none\",\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}"
# VLESS_SNIFFING="{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}"
#
# sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (1, 0, 0, 0, 'Auto_VLESS_Node', 1, 0, '', $NODE_PORT, 'vless', '$VLESS_SETTINGS', '$VLESS_STREAM', 'inbound-$NODE_PORT', '$VLESS_SNIFFING');"
#
# VLESS_SHARE_LINK="vless://${UUID}@${PUBLIC_IP}:${NODE_PORT}?encryption=none&security=none&type=tcp#Auto_VLESS_Node"
# ==================================================================

systemctl start x-ui
sleep 3

# 5. 获取最终的访问地址、分享链接和订阅链接
echo -e "\n[5/5] 正在生成完整配置清单..."
PUBLIC_IP=$(curl -s ifconfig.me || curl -s ipv4.icanhazip.com)
WEB_BASE_PATH=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webBasePath';")
WEB_BASE_PATH=$(echo $WEB_BASE_PATH | tr -d '"')

FINAL_URL="https://${PUBLIC_IP}:${PANEL_PORT}${WEB_BASE_PATH}"

# 生成 VMESS 专属链接
VMESS_JSON="{\"v\":\"2\",\"ps\":\"Auto_VMESS_Node\",\"add\":\"${PUBLIC_IP}\",\"port\":\"${NODE_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\",\"fp\":\"\"}"
SHARE_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

# 生成 3x-ui 标准订阅链接
SUB_URL="https://${PUBLIC_IP}:${PANEL_PORT}${WEB_BASE_PATH}sub/${SUB_ID}"

echo ""
echo "===================================================="
echo "🎉 恭喜！全自动部署与配置已全部完成！"
echo "===================================================="
echo "🌐 【Web 面板信息】"
echo "▶ 访问地址: $FINAL_URL"
echo "（⚠️ 浏览器提示“不安全”属正常现象，点击'高级' -> '继续前往'即可）"
echo "▶ 登录账号: $PANEL_USER"
echo "▶ 登录密码: $PANEL_PASS"
echo "----------------------------------------------------"
echo "🚀 【单节点导入链接 (直接复制至 v2rayN)】"
echo -e "\033[32m$SHARE_LINK\033[0m"
echo "----------------------------------------------------"
echo "📡 【通用订阅链接 (支持 Clash 等客户端在线更新)】"
echo -e "\033[36m$SUB_URL\033[0m"
echo "===================================================="
