#!/bin/bash

# ==================================================================
# ！！！请在这里修改为你自己想要的面板用户名和密码！！！
PANEL_USER="admin"        # 面板登录用户名
PANEL_PASS="admin"        # 面板登录密码
# ==================================================================

# 必须以 root 运行（安装依赖、写 /etc/x-ui、配置防火墙都需要 root）
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 严重错误: 请以 root 用户运行本脚本！"
    exit 1
fi

# 随机选取一个未被占用的端口（起始值 + 0~9999）
pick_free_port() {
    local base=$1 port i
    for i in $(seq 1 20); do
        port=$((RANDOM % 10000 + base))
        if ! ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${port}\$"; then
            echo "$port"
            return
        fi
    done
    echo "$((base + RANDOM % 10000))"
}

RANDOM_PANEL_PORT=$(pick_free_port 40000)
NODE_PORT=$(pick_free_port 50000)
SUB_PORT=2096   # 3x-ui 订阅服务端口

echo "===================================================="
echo "🚀 正在全自动安装 3x-ui 并智能配置初始环境..."
echo "===================================================="

# 1. 自动识别系统并安装依赖
echo -e "\n[1/7] 正在检测操作系统并安装系统依赖..."
if command -v apt >/dev/null 2>&1; then
    PM="apt"
    apt update -y > /dev/null 2>&1
    # Debian/Ubuntu 的 sqlite 包名为 sqlite3，防火墙使用 ufw
    apt install curl wget sqlite3 ufw coreutils iproute2 -y > /dev/null 2>&1
elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
    dnf install epel-release -y > /dev/null 2>&1
    dnf install curl wget sqlite firewalld coreutils iproute -y > /dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    PM="yum"
    yum install epel-release -y > /dev/null 2>&1
    yum install curl wget sqlite firewalld coreutils iproute -y > /dev/null 2>&1
else
    echo "❌ 严重错误: 不支持的操作系统！请使用 Debian/Ubuntu 或 CentOS/RHEL 体系。"
    exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "❌ 严重错误: sqlite3 安装失败，无法继续。请检查网络和软件源后重试。"
    exit 1
fi

# 2. 提前放行防火墙 (自适应 ufw / firewalld)
echo -e "\n[2/7] 正在提前配置防火墙..."
# 智能获取当前 SSH 端口防止防火墙开启后失联
# 优先用 sshd -T 读取实际生效配置（能覆盖 sshd_config.d/*.conf 的情况）
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
if [ -z "$SSH_PORT" ]; then
    SSH_PORT=$(grep -rhiE "^\s*Port\s+[0-9]+" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | head -n 1)
fi
SSH_PORT=${SSH_PORT:-22}

if [ "$PM" = "apt" ]; then
    ufw allow ${SSH_PORT}/tcp > /dev/null 2>&1
    ufw allow 80/tcp > /dev/null 2>&1
    ufw allow ${RANDOM_PANEL_PORT}/tcp > /dev/null 2>&1
    ufw allow ${NODE_PORT}/tcp > /dev/null 2>&1
    ufw allow ${SUB_PORT}/tcp > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
    ufw reload > /dev/null 2>&1
else
    systemctl enable firewalld --now > /dev/null 2>&1
    firewall-cmd --zone=public --add-service=ssh --permanent > /dev/null 2>&1
    firewall-cmd --zone=public --add-port=${SSH_PORT}/tcp --permanent > /dev/null 2>&1
    firewall-cmd --zone=public --add-port=80/tcp --permanent > /dev/null 2>&1
    firewall-cmd --zone=public --add-port=${RANDOM_PANEL_PORT}/tcp --permanent > /dev/null 2>&1
    firewall-cmd --zone=public --add-port=${NODE_PORT}/tcp --permanent > /dev/null 2>&1
    firewall-cmd --zone=public --add-port=${SUB_PORT}/tcp --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
fi

# 3. 执行安装脚本（官方非交互模式，不再使用 expect）
# 3x-ui 官方 install.sh 支持 XUI_NONINTERACTIVE=1 + 环境变量直接指定
# 账号/密码/端口，不依赖菜单序号和提示语措辞，版本更新不会失效。
echo -e "\n[3/7] 正在启动 3x-ui 安装流程..."
export XUI_NONINTERACTIVE=1
export XUI_USERNAME="$PANEL_USER"
export XUI_PASSWORD="$PANEL_PASS"
export XUI_PANEL_PORT="$RANDOM_PANEL_PORT"
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) < /dev/null

if [ ! -f /usr/local/x-ui/x-ui ]; then
    echo "❌ 严重错误: 3x-ui 安装失败（未找到 /usr/local/x-ui/x-ui），请检查上方输出。"
    exit 1
fi

# 4. 通过官方 CLI 兜底设置账号密码和面板端口
# x-ui setting 是稳定的非交互命令行接口（安装脚本内部也用它），
# 这里再执行一次是为了兼容不支持 XUI_* 环境变量的旧版安装脚本。
echo -e "\n[4/7] 正在设置面板账号密码与端口..."
/usr/local/x-ui/x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" > /dev/null 2>&1
/usr/local/x-ui/x-ui setting -port "$RANDOM_PANEL_PORT" > /dev/null 2>&1

# 5. 获取本机 IP 及地理位置信息
echo -e "\n[5/7] 正在获取服务器公网 IP 及物理地区信息..."
PUBLIC_IP=$(curl -s --max-time 10 https://api.ipify.org)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s --max-time 10 ifconfig.me)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s --max-time 10 ipv4.icanhazip.com)
PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d ' \r\n')

if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="YOUR_SERVER_IP"
    REGION="未知_地区"
    echo "⚠️  警告: 无法获取公网 IP，最终链接中的地址请手动替换为你的服务器 IP！"
else
    # 一次请求同时取国家和城市，减少 API 调用次数
    GEO_INFO=$(curl -s --max-time 10 "http://ip-api.com/line/${PUBLIC_IP}?fields=country,city&lang=zh-CN")
    GEO_COUNTRY=$(echo "$GEO_INFO" | sed -n '1p')
    GEO_CITY=$(echo "$GEO_INFO" | sed -n '2p')

    if [ -z "$GEO_COUNTRY" ] || [ "$GEO_COUNTRY" = "fail" ]; then
        REGION="未知_地区"
    else
        REGION="${GEO_COUNTRY}_${GEO_CITY}"
    fi
fi
# 清洗节点名：去掉空白和单引号，防止特殊地名破坏 SQL 语句和分享链接
REGION=$(echo "$REGION" | tr -d " '\r\n\"")
REGION=${REGION%_}
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
sqlite3 $DB_PATH "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (1, 0, 0, 0, '$VMESS_REMARK', 1, 0, '', $NODE_PORT, 'vmess', '$SETTINGS', '$STREAM_SETTINGS', 'inbound-$NODE_PORT', '$SNIFFING');"

INBOUND_COUNT=$(sqlite3 $DB_PATH "SELECT COUNT(*) FROM inbounds WHERE port = $NODE_PORT;")
if [ "$INBOUND_COUNT" != "1" ]; then
    echo "❌ 严重错误: 节点写入数据库失败，请手动登录面板添加节点。"
fi

# ==================================================================
# 【备用方案】 VLESS 节点配置注入 (默认被注释)
# 如果你需要改为 VLESS，请将上方 VMESS 的三个 sqlite3 语句注释掉，并解除下方代码的注释：
# ... (保留原注释代码)
# ==================================================================

# 启用订阅服务（3x-ui 默认关闭订阅，不开启的话订阅链接无法访问）
set_setting() {
    local key=$1 val=$2
    if [ -n "$(sqlite3 $DB_PATH "SELECT id FROM settings WHERE key='$key';")" ]; then
        sqlite3 $DB_PATH "UPDATE settings SET value='$val' WHERE key='$key';"
    else
        sqlite3 $DB_PATH "INSERT INTO settings (key, value) VALUES ('$key', '$val');"
    fi
}
set_setting "subEnable" "true"
set_setting "subPort" "$SUB_PORT"
set_setting "subPath" "/sub/"

systemctl start x-ui
sleep 2

# 7. 读取真实配置及二次确认
echo -e "\n[7/7] 正在校验最终配置与环境..."
REAL_PANEL_PORT=$(sqlite3 $DB_PATH "SELECT value FROM settings WHERE key='webPort' LIMIT 1;" | tr -d '" \r\n')
# 全新安装时 settings 表可能没有 webPort 记录，回退到脚本设置的端口
REAL_PANEL_PORT=${REAL_PANEL_PORT:-$RANDOM_PANEL_PORT}

REAL_BASE_PATH=$(sqlite3 $DB_PATH "SELECT value FROM settings WHERE key='webBasePath';" | tr -d '" \r\n')
# 规范化 basePath：确保以 / 开头、以 / 结尾，空值退化为 /
[ -z "$REAL_BASE_PATH" ] && REAL_BASE_PATH="/"
case "$REAL_BASE_PATH" in /*) ;; *) REAL_BASE_PATH="/$REAL_BASE_PATH" ;; esac
case "$REAL_BASE_PATH" in */) ;; *) REAL_BASE_PATH="$REAL_BASE_PATH/" ;; esac

# 防火墙端口二次放行 (兼容 ufw 和 firewalld)
if [ "$PM" = "apt" ]; then
    ufw allow ${REAL_PANEL_PORT}/tcp > /dev/null 2>&1
    ufw reload > /dev/null 2>&1
else
    firewall-cmd --zone=public --add-port=${REAL_PANEL_PORT}/tcp --permanent > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
fi

# 生成链接（base64 统一去除换行：无 -w 参数的实现默认 76 列换行会导致链接失效）
VMESS_JSON="{\"v\":\"2\",\"ps\":\"${VMESS_REMARK}\",\"add\":\"${PUBLIC_IP}\",\"port\":\"${NODE_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\",\"sni\":\"\",\"alpn\":\"\",\"fp\":\"\"}"
SHARE_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 | tr -d '\n')"

SUB_URL="http://${PUBLIC_IP}:${SUB_PORT}/sub/${SUB_ID}"

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
if [ "$PANEL_USER" = "admin" ] && [ "$PANEL_PASS" = "admin" ]; then
    echo "⚠️  安全提醒: 面板正在使用默认账号密码 admin/admin 且以 HTTP 明文暴露公网，"
    echo "   请立即登录面板修改密码，并建议配置 TLS 证书！"
fi
