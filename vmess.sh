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

# 2. 配置 CentOS 9.4 严格的防火墙 (内部验证：确保端口永久放行)
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
    "*Account name:*" { send "$env(PANEL_USER)\r"; exp_continue }
    "*Account password:*" { send "$env(PANEL_PASS)\r"; exp_continue }
    "*Panel port:*" { send "$env(PANEL_PORT)\r"; exp_continue }
    "*(default 2 for IP):*" { send "2\r"; exp_continue }
    eof
}
EOF
chmod +x install_xui.exp
./install_xui.exp
rm -f install_xui.exp

# 4. 在数据库中自动注入 VMESS 代理节点
echo -e "\n[4/5] 正在通过底层数据库直接创建 VMESS 节点..."
# 必须先停用面板服务，防止数据库写入冲突
systemctl stop x-ui
sleep 2

UUID=$(cat /proc/sys/kernel/random/uuid)

# 内部验证：严格匹配 3x-ui 中 VMESS 的 JSON 结构配置 (包含 alterId:0)
SETTINGS="{\"clients\":[{\"id\":\"$UUID\",\"alterId\":0,\"email\":\"vmess_$UUID\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":\"\",\"subId\":\"\"}],\"disableInsecureEncryption\":false}"
STREAM_SETTINGS="{\"network\":\"tcp\",\"security\":\"none\",\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}"
SNIFFING="{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}"

sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (1, 0, 0, 0, 'Auto_VMESS_Node', 1, 0, '', $NODE_PORT, 'vmess', '$SETTINGS', '$STREAM_SETTINGS', 'inbound-$NODE_PORT', '$SNIFFING');"

systemctl start x-ui
sleep 3

# 5. 获取最终的访问地址并生成 VMESS 分享链接
echo -e "\n[5/5] 正在提取面板安全路径并生成 VMESS 链接..."
PUBLIC_IP=$(curl -s ifconfig.me || curl -s ipv4.icanhazip.com)
WEB_BASE_PATH=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webBasePath';")
WEB_BASE_PATH=$(echo $WEB_BASE_PATH | tr -d '"')

FINAL_URL="https://${PUBLIC_IP}:${PANEL_PORT}${WEB_BASE_PATH}"

# 内部验证：VMESS 协议要求将节点信息转换为 JSON 并进行 Base64 编码 (使用 -w 0 避免换行截断)
VMESS_JSON="{\"v\":\"2\",\"ps\":\"Auto_VMESS_Node\",\"add\":\"${PUBLIC_IP}\",\"port\":\"${NODE_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\",\"fp\":\"\"}"
SHARE_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

echo ""
echo "===================================================="
echo "🎉 恭喜！全自动安装与配置已全部完成！"
echo "===================================================="
echo "🌐 【Web 面板信息】"
echo "▶ 访问地址: $FINAL_URL"
echo "（⚠️ 浏览器提示“不安全”属正常现象，点击'高级' -> '继续前往'即可）"
echo "▶ 登录账号: $PANEL_USER"
echo "▶ 登录密码: $PANEL_PASS"
echo "----------------------------------------------------"
echo "🚀 【自动创建的代理节点信息】"
echo "▶ 节点协议: VMESS (TCP)"
echo "▶ 节点端口: $NODE_PORT"
echo "▶ 专属 UUID: $UUID"
echo ""
echo "👇 【一键导入链接 (直接复制下方整段代码到 v2rayN / Clash 转换器中)】👇"
echo -e "\033[32m$SHARE_LINK\033[0m"
echo "===================================================="
