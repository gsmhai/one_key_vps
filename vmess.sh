#!/bin/bash

# ==================================================================
# ！！！请在这里修改为你自己想要的面板用户名和密码！！！
PANEL_USER="admin"        # 面板登录用户名
PANEL_PASS="admin"        # 面板登录密码
# ==================================================================

# 预设随机端口
RANDOM_PANEL_PORT=$((RANDOM % 10000 + 40000))
NODE_PORT=$((RANDOM % 10000 + 50000))

echo "===================================================="
echo "🚀 正在全自动安装 3x-ui 并智能配置初始环境..."
echo "===================================================="

# 1. 自动识别系统并安装依赖
echo -e "\n[1/7] 正在检测操作系统并安装系统依赖..."
if command -v apt >/dev/null 2>&1; then
    PM="apt"
    apt update -y > /dev/null 2>&1
    # Debian/Ubuntu 的 sqlite 包名为 sqlite3，防火墙使用 ufw
    apt install curl wget sqlite3 expect ufw coreutils -y > /dev/null 2>&1
elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
    dnf update -y > /dev/null 2>&1
    dnf install epel-release -y > /dev/null 2>&1
    dnf install curl wget sqlite expect firewalld coreutils -y > /dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    PM="yum"
    yum update -y > /dev/null 2>&1
    yum install epel-release -y > /dev/null 2>&1
    yum install curl wget sqlite expect firewalld coreutils -y > /dev/null 2>&1
else
    echo "❌ 严重错误: 不支持的操作系统！请使用 Debian/Ubuntu 或 CentOS/RHEL 体系。"
    exit 1
fi

# 2. 提前放行防火墙 (自适应 ufw / firewalld)
echo -e "\n[2/7] 正在提前配置防火墙..."
if [ "$PM" = "apt" ]; then
    # 智能获取当前 SSH 端口防止 UFW 开启后失联
    SSH_PORT=$(grep -i -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    SSH_PORT=${SSH_PORT:-22}
    
    ufw allow ${SSH_PORT}/tcp > /dev/null 2>&1
    ufw allow 80/tcp > /dev/null 2>&1
    ufw allow ${RANDOM_PANEL_PORT}/tcp > /dev/null 2>&1
    ufw allow ${NODE_PORT}/tcp > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
    ufw reload > /dev/null 2>&1
else
    systemctl enable firewalld --now > /dev/null 2>&1
    firewall-cmd --zone=public --add-port=80/tcp --permanent > /dev/null 2>&1
    firewall-cmd --zone=public --add-port=${RANDOM_PANEL_PORT}/tcp --permanent > /dev/null 2>&1
    firewall-cmd --zone=public --add-port=${NODE_PORT}/tcp --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
fi

# 3. 执行安装脚本
echo -e "\n[3/7] 正在启动 3x-ui 安装流程..."
export PANEL_USER PANEL_PASS RANDOM_PANEL_PORT
cat << 'EOF' > install_xui.exp
#!/usr/bin/expect -f
set timeout 300
spawn bash -c "bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
expect {
    -re {Choose \[1\]:} { send "1\r"; exp_continue }
    -nocase -re {customize.*y/n} { send "y\r"; exp_continue }
    -nocase -re {panel port:} { send "$env(RANDOM_PANEL_PORT)\r"; exp_continue }
    -nocase -re {account name:} { send "$env(PANEL_USER)\r"; exp_continue }
    -nocase -re {account password:} { send "$env(PANEL_PASS)\r"; exp_continue }
    -nocase -re {Choose an option.*:} { send "4\r"; exp_continue }
    -nocase -re {Bind the panel to 127\.0\.0\.1} { send "n\r"; exp_continue }
    eof
}
EOF
chmod +x install_xui.exp
./install_xui.exp

# 4. 精准捕获并重置面板密码
echo -e "\n[4/7] 正在强制重置/检查账号密码..."
cat << 'EOF' > reset_cred.exp
#!/usr/bin/expect -f
set timeout 15
spawn x-ui

expect {
    -re {(selection|选择).*:} { send "7\r" }
    timeout { exit 0 }
}
expect -re {(sure|确认)} { send "y\r" }
expect -re {(username|用户名|帐号|账号)} { send "$env(PANEL_USER)\r" }
expect -re {(password|密码)} { send "$env(PANEL_PASS)\r" }

expect {
    -re {(two-factor|双因素|2FA)} { send "y\r"; exp_continue }
    -nocase -re {(restart the panel|重启面板)} { 
        send "y\r"
        expect -re {(return|返回|enter|回车)} { send "\r" }
        exit 0
    }
    -re {(return|返回|enter|回车)} { send "\r"; exit 0 }
    timeout { exit 0 }
    eof { exit 0 }
}
EOF
chmod +x reset_cred.exp
./reset_cred.exp
rm -f install_xui.exp reset_cred.exp

# 5. 获取本机 IP 及地理位置信息
echo -e "\n[5/7] 正在获取服务器公网 IP 及物理地区信息..."
PUBLIC_IP=$(curl -s ifconfig.me || curl -s ipv4.icanhazip.com)

if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="192.168.0.1"
    REGION="未知_地区"
else
    GEO_COUNTRY=$(curl -s "http://ip-api.com/line/$PUBLIC_IP?fields=country&lang=zh-CN")
    GEO_CITY=$(curl -s "http://ip-api.com/line/$PUBLIC_IP?fields=city&lang=zh-CN")

    if [ -z "$GEO_COUNTRY" ] || [ "$GEO_COUNTRY" == "fail" ]; then
        REGION="未知_地区"
    else
        REGION="${GEO_COUNTRY}_${GEO_CITY}"
        REGION=$(echo "$REGION" | tr -d ' \r\n')
    fi
fi
VMESS_REMARK="${REGION}"
VLESS_REMARK="${REGION}"
echo "✅ 成功识别地区信息: $REGION"

# 6. 注入初始代理节点
echo -e "\n[6/7] 正在注入初始代理节点..."
systemctl start x-ui
sleep 3
systemctl stop x-ui
sleep 2

DB_PATH="/etc/x-ui/x-ui.db"
if [ ! -f "$DB_PATH" ]; then
    echo "❌ 严重错误: 未找到数据库文件，面板安装失败！"
    exit 1
fi

UUID=$(cat /proc/sys/kernel/random/uuid)
SUB_ID=$(cat /proc/sys/kernel/random/uuid | tr -d '-')

# ==================================================================
# 【默认生效】 VMESS 节点配置注入
SETTINGS="{\"clients\":[{\"id\":\"$UUID\",\"alterId\":0,\"email\":\"vmess_$UUID\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":\"\",\"subId\":\"$SUB_ID\"}],\"disableInsecureEncryption\":false}"
STREAM_SETTINGS="{\"network\":\"tcp\",\"security\":\"none\",\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}"
SNIFFING="{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}"

sqlite3 $DB_PATH "DELETE FROM inbounds WHERE remark = '$VMESS_REMARK';"
# 修复了此处之前遗留的 $REMARK_NAME Bug，变更为 $VMESS_REMARK
sqlite3 $DB_PATH "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (1, 0, 0, 0, '$VMESS_REMARK', 1, 0, '', $NODE_PORT, 'vmess', '$SETTINGS', '$STREAM_SETTINGS', 'inbound-$NODE_PORT', '$SNIFFING');"

# ==================================================================
# 【备用方案】 VLESS 节点配置注入 (默认被注释)
# 如果你需要改为 VLESS，请将上方 VMESS 的三个 sqlite3 语句注释掉，并解除下方代码的注释：
# ... (保留原注释代码)
# ==================================================================
systemctl start x-ui
sleep 2

# 7. 读取真实配置及二次确认
echo -e "\n[7/7] 正在校验最终配置与环境..."
REAL_PANEL_PORT=$(sqlite3 $DB_PATH "SELECT value FROM settings WHERE key IN ('webPort', 'panelPort', 'port') LIMIT 1;")
REAL_BASE_PATH=$(sqlite3 $DB_PATH "SELECT value FROM settings WHERE key='webBasePath';" | tr -d '"')

# 防火墙端口二次放行 (兼容 ufw 和 firewalld)
if [ "$PM" = "apt" ]; then
    ufw allow ${REAL_PANEL_PORT}/tcp > /dev/null 2>&1
    ufw reload > /dev/null 2>&1
else
    firewall-cmd --zone=public --add-port=${REAL_PANEL_PORT}/tcp --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
fi

# 生成链接
VMESS_JSON="{\"v\":\"2\",\"ps\":\"${VMESS_REMARK}\",\"add\":\"${PUBLIC_IP}\",\"port\":\"${NODE_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\",\"fp\":\"\"}"
if base64 --help 2>&1 | grep -q "\-w"; then
    SHARE_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
else
    SHARE_LINK="vmess://$(echo -n "$VMESS_JSON" | base64)"
fi

SUB_URL="http://${PUBLIC_IP}:${REAL_PANEL_PORT}${REAL_BASE_PATH}sub/${SUB_ID}"

echo ""
echo "===================================================="
echo "🎉 部署完成！"
echo "===================================================="
echo "🌐 【Web 面板地址】"
echo "▶ 地址: http://${PUBLIC_IP}:${REAL_PANEL_PORT}${REAL_BASE_PATH}"
echo "▶ 账号: $PANEL_USER"
echo "▶ 密码: $PANEL_PASS"
echo "----------------------------------------------------"
echo "🚀 【单节点链接 (VMESS)】"
echo "▶ 节点名称: $VMESS_REMARK"
echo -e "\033[32m$SHARE_LINK\033[0m"
echo "----------------------------------------------------"
echo "📡 【通用订阅链接】"
echo -e "\033[36m$SUB_URL\033[0m"
echo "===================================================="