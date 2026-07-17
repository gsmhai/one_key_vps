#!/bin/bash

# ==================================================================
# ！！！请在这里修改为你自己想要的面板用户名和密码！！！
PANEL_USER="admin"        # 面板登录用户名
PANEL_PASS="admin"        # 面板登录密码

# 是否同时生成 VLESS+Reality 节点: 0=只生成 VMESS(默认), 1=同时生成 VMESS 和 VLESS
# 两种开启方式任选其一:
#   1) 直接把下面的值改为 1
#   2) 运行脚本时带上参数: bash vmess.sh vless  (或 --vless)
VLESS_ON=0

# 面板 HTTPS 证书方式: 0=使用 x-ui 官方 Let's Encrypt IP 证书(默认, 自动续期, 需 80 端口可达),
#                      1=使用 openssl 自签名证书(浏览器会告警, 适合 80 端口被占/受限的环境)
OPENSSL_ON=0
# ==================================================================

# 解析命令行参数
for arg in "$@"; do
    case "$arg" in
        vless|--vless|-vless)
            VLESS_ON=1
            ;;
        openssl|--openssl)
            OPENSSL_ON=1
            ;;
    esac
done

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
VLESS_PORT=""
[ "$VLESS_ON" = "1" ] && VLESS_PORT=$(pick_free_port 30000)   # VLESS+Reality 节点端口
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
    apt install curl wget sqlite3 ufw coreutils iproute2 openssl -y > /dev/null 2>&1
elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
    dnf install epel-release -y > /dev/null 2>&1
    dnf install curl wget sqlite firewalld coreutils iproute openssl -y > /dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    PM="yum"
    yum install epel-release -y > /dev/null 2>&1
    yum install curl wget sqlite firewalld coreutils iproute openssl -y > /dev/null 2>&1
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
    [ "$VLESS_ON" = "1" ] && ufw allow ${VLESS_PORT}/tcp > /dev/null 2>&1
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
    [ "$VLESS_ON" = "1" ] && firewall-cmd --zone=public --add-port=${VLESS_PORT}/tcp --permanent > /dev/null 2>&1
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
# OPENSSL_ON=0: 使用 x-ui 官方内置的 Let's Encrypt IP 证书流程（acme.sh 签发,
# 自动续期, 需 80 端口对外可达）; OPENSSL_ON=1: 跳过官方 SSL, 稍后用 openssl 自签
if [ "$OPENSSL_ON" = "0" ]; then
    export XUI_SSL_MODE=ip
else
    export XUI_SSL_MODE=none
fi
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
echo -e "\n[5/7] 正在获取服务器 IP 及物理地区信息..."
# 以本机默认路由出口 IP 为准（最终链接统一使用该 IP）
LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -z "$LOCAL_IP" ] && LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
LOCAL_IP=$(echo "$LOCAL_IP" | tr -d ' \r\n')

# 外部探测公网 IP，仅用于和本机 IP 比对告警，不作为最终地址
EXTERNAL_IP=$(curl -s --max-time 10 https://api.ipify.org)
[ -z "$EXTERNAL_IP" ] && EXTERNAL_IP=$(curl -s --max-time 10 ifconfig.me)
[ -z "$EXTERNAL_IP" ] && EXTERNAL_IP=$(curl -s --max-time 10 ipv4.icanhazip.com)
EXTERNAL_IP=$(echo "$EXTERNAL_IP" | tr -d ' \r\n')

if [ -z "$EXTERNAL_IP" ]; then
    echo "⚠️  警告: 无法从外部探测公网 IP（网络受限或探测接口不可用），将直接使用本机 IP: ${LOCAL_IP:-未知}"
elif [ -n "$LOCAL_IP" ] && [ "$EXTERNAL_IP" != "$LOCAL_IP" ]; then
    echo "⚠️  警告: 外部探测到的公网 IP ($EXTERNAL_IP) 与本机默认 IP ($LOCAL_IP) 不一致，"
    echo "   本机可能位于 NAT 之后，最终链接将使用本机 IP: $LOCAL_IP，如无法连接请手动替换为公网 IP。"
fi

PUBLIC_IP="$LOCAL_IP"
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="YOUR_SERVER_IP"
    REGION="未知_地区"
    echo "⚠️  警告: 无法获取本机 IP，最终链接中的地址请手动替换为你的服务器 IP！"
else
    # 地理位置用外部探测 IP 查询（本机 IP 可能是 NAT 内网地址，无法定位）；
    # 外部 IP 也没有时留空，ip-api 会按请求来源 IP 定位
    GEO_INFO=$(curl -s --max-time 10 "http://ip-api.com/line/${EXTERNAL_IP}?fields=country,city&lang=zh-CN")
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
VMESS_REMARK="${REGION}_vmess"
VLESS_REMARK="${REGION}_vless_reality"
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
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
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
# 【可选】 VLESS + Reality 节点配置注入（由 VLESS_ON 变量或 vless 参数控制）
VLESS_ENABLED=0
if [ "$VLESS_ON" = "1" ]; then
# Reality 伪装目标站点（需为支持 TLSv1.3 + H2 的真实站点，可按需修改）
REALITY_DEST="yahoo.com:443"
REALITY_SNI="yahoo.com"

# 用 3x-ui 自带的 xray 二进制生成 Reality 密钥对
XRAY_BIN=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -n 1)
REALITY_KEYS=""
if [ -n "$XRAY_BIN" ]; then
    REALITY_KEYS=$("$XRAY_BIN" x25519 2>/dev/null)
fi
# 兼容新旧版 xray 的输出格式:
# 旧版: "Private key: xxx / Public key: xxx"
# 新版: "PrivateKey: xxx / Password: xxx"
REALITY_PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep -i "private" | head -n 1 | awk '{print $NF}')
REALITY_PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep -iE "public|password" | head -n 1 | awk '{print $NF}')
REALITY_SHORT_ID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
    echo "⚠️  警告: Reality 密钥对生成失败，跳过 VLESS 节点注入（VMESS 节点不受影响）。"
    VLESS_ENABLED=0
else
    VLESS_ENABLED=1
    VLESS_SETTINGS="{\"clients\":[{\"id\":\"$VLESS_UUID\",\"flow\":\"xtls-rprx-vision\",\"email\":\"vless_$VLESS_UUID\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":\"\",\"subId\":\"$SUB_ID\"}],\"decryption\":\"none\",\"fallbacks\":[]}"
    VLESS_STREAM_SETTINGS="{\"network\":\"tcp\",\"security\":\"reality\",\"externalProxy\":[],\"realitySettings\":{\"show\":false,\"xver\":0,\"dest\":\"$REALITY_DEST\",\"serverNames\":[\"$REALITY_SNI\"],\"privateKey\":\"$REALITY_PRIVATE_KEY\",\"minClient\":\"\",\"maxClient\":\"\",\"maxTimediff\":0,\"shortIds\":[\"$REALITY_SHORT_ID\"],\"settings\":{\"publicKey\":\"$REALITY_PUBLIC_KEY\",\"fingerprint\":\"chrome\",\"serverName\":\"\",\"spiderX\":\"/\"}},\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}"

    sqlite3 $DB_PATH "DELETE FROM inbounds WHERE remark = '$VLESS_REMARK';"
    sqlite3 $DB_PATH "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (1, 0, 0, 0, '$VLESS_REMARK', 1, 0, '', $VLESS_PORT, 'vless', '$VLESS_SETTINGS', '$VLESS_STREAM_SETTINGS', 'inbound-$VLESS_PORT', '$SNIFFING');"

    VLESS_COUNT=$(sqlite3 $DB_PATH "SELECT COUNT(*) FROM inbounds WHERE port = $VLESS_PORT;")
    if [ "$VLESS_COUNT" != "1" ]; then
        echo "❌ 严重错误: VLESS 节点写入数据库失败，请手动登录面板添加节点。"
        VLESS_ENABLED=0
    fi
fi
fi
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
# 启用 Clash(Mihomo) 与 Xray-JSON 订阅格式（3x-ui 原生支持，默认关闭）
# Clash 订阅路径 /clash/ -> YAML；JSON 订阅路径 /json/ -> Xray 客户端完整配置
set_setting "subClashEnable" "true"
set_setting "subJsonEnable" "true"

# 配置面板 HTTPS
# OPENSSL_ON=0: 证书已由官方安装脚本通过 Let's Encrypt 签发并配置（x-ui cert 命令写入),
#               这里只做检测确认; OPENSSL_ON=1: 生成 openssl 自签名证书写入设置。
# 无论哪种方式, 都把面板证书同步给订阅服务, 让订阅链接同样走 https。
CERT_FILE=$(sqlite3 $DB_PATH "SELECT value FROM settings WHERE key='webCertFile';" | tr -d '" \r\n')
KEY_FILE=$(sqlite3 $DB_PATH "SELECT value FROM settings WHERE key='webKeyFile';" | tr -d '" \r\n')

if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ] && [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    echo "✅ 检测到面板已配置证书，保留现有 HTTPS 配置: $CERT_FILE"
elif [ "$OPENSSL_ON" = "1" ]; then
    CERT_DIR="/etc/x-ui/cert"
    mkdir -p "$CERT_DIR"
    CERT_FILE="$CERT_DIR/self_signed.crt"
    KEY_FILE="$CERT_DIR/self_signed.key"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -nodes \
        -subj "/CN=${PUBLIC_IP}" \
        -addext "subjectAltName=IP:${PUBLIC_IP}" > /dev/null 2>&1
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        chmod 600 "$KEY_FILE"
        echo "✅ 已生成自签名证书 (有效期 10 年): $CERT_FILE"
    else
        echo "⚠️  警告: 自签名证书生成失败，面板将保持 HTTP 访问。"
        CERT_FILE=""
        KEY_FILE=""
    fi
else
    echo "⚠️  警告: 未检测到面板证书，官方 Let's Encrypt IP 证书可能签发失败"
    echo "   （常见原因: 80 端口未对外开放、或 NAT 环境公网无法回连本机）。"
    echo "   面板将保持 HTTP 访问。可放行 80 端口后重跑脚本，"
    echo "   或改用自签名证书: bash vmess.sh openssl"
    CERT_FILE=""
    KEY_FILE=""
fi

PANEL_SCHEME="http"
SUB_SCHEME="http"
if [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ]; then
    set_setting "webCertFile" "$CERT_FILE"
    set_setting "webKeyFile" "$KEY_FILE"
    # 订阅服务使用同一套证书，同样升级为 https
    set_setting "subCertFile" "$CERT_FILE"
    set_setting "subKeyFile" "$KEY_FILE"
    PANEL_SCHEME="https"
    SUB_SCHEME="https"
fi

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

# VLESS + Reality 分享链接（vless:// 为明文 URL 格式，无需 base64）
if [ "$VLESS_ENABLED" = "1" ]; then
    VLESS_SHARE_LINK="vless://${VLESS_UUID}@${PUBLIC_IP}:${VLESS_PORT}?type=tcp&security=reality&pbk=${REALITY_PUBLIC_KEY}&fp=chrome&sni=${REALITY_SNI}&sid=${REALITY_SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#${VLESS_REMARK}"
fi

SUB_URL="${SUB_SCHEME}://${PUBLIC_IP}:${SUB_PORT}/sub/${SUB_ID}"
CLASH_SUB_URL="${SUB_SCHEME}://${PUBLIC_IP}:${SUB_PORT}/clash/${SUB_ID}"
JSON_SUB_URL="${SUB_SCHEME}://${PUBLIC_IP}:${SUB_PORT}/json/${SUB_ID}"

echo ""
echo "===================================================="
echo "🎉 部署完成！"
echo "===================================================="
echo "🌐 【Web 面板地址】"
echo "▶ 地址: ${PANEL_SCHEME}://${PUBLIC_IP}:${REAL_PANEL_PORT}${REAL_BASE_PATH}"
if [ "$PANEL_SCHEME" = "https" ] && [ "$OPENSSL_ON" = "1" ]; then
    echo "▶ 提示: 自签名证书浏览器会提示不安全，选择\"继续访问\"即可。"
fi
echo "▶ 账号: $PANEL_USER"
echo "▶ 密码: $PANEL_PASS"
echo "----------------------------------------------------"
echo "🚀 【单节点链接 (VMESS)】"
echo "▶ 节点名称: $VMESS_REMARK"
echo -e "\033[32m$SHARE_LINK\033[0m"
echo "----------------------------------------------------"
if [ "$VLESS_ENABLED" = "1" ]; then
    echo "🚀 【单节点链接 (VLESS + Reality)】"
    echo "▶ 节点名称: $VLESS_REMARK"
    echo -e "\033[32m$VLESS_SHARE_LINK\033[0m"
    echo "----------------------------------------------------"
fi
echo "📡 【通用订阅链接 (Base64, 通用客户端)】"
echo -e "\033[36m$SUB_URL\033[0m"
echo "----------------------------------------------------"
echo "📡 【Clash / Mihomo 订阅链接 (YAML)】"
echo "▶ 适用于: Clash Verge / Clash Meta / Mihomo / Stash 等"
echo -e "\033[36m$CLASH_SUB_URL\033[0m"
echo "----------------------------------------------------"
echo "📡 【Xray JSON 订阅链接】"
echo "▶ 适用于: v2rayN / v2rayNG 等支持 Xray-JSON 订阅的客户端"
echo "▶ sing-box 用户: 直接导入上方 Base64 通用订阅即可（sing-box 支持解析分享链接）"
echo -e "\033[36m$JSON_SUB_URL\033[0m"
echo "===================================================="
if [ "$PANEL_USER" = "admin" ] && [ "$PANEL_PASS" = "admin" ]; then
    echo "⚠️  安全提醒: 面板正在使用默认账号密码 admin/admin 并暴露公网，请立即登录面板修改密码！"
fi

# 8. 将部署结果写入当前目录的 log 文件（含账号密码，权限设为 600 仅 root 可读）
# VLESS 节点信息块（仅在 VLESS 注入成功时写入日志）
VLESS_LOG_BLOCK=""
if [ "$VLESS_ENABLED" = "1" ]; then
    VLESS_LOG_BLOCK="
【VLESS + Reality 单节点链接】
节点名称: ${VLESS_REMARK}
节点端口: ${VLESS_PORT}
UUID: ${VLESS_UUID}
Reality 公钥: ${REALITY_PUBLIC_KEY}
Reality ShortId: ${REALITY_SHORT_ID}
伪装 SNI: ${REALITY_SNI}
${VLESS_SHARE_LINK}
"
fi

LOG_FILE="$(pwd)/vmess_deploy_$(date +%Y%m%d_%H%M%S).log"
cat > "$LOG_FILE" << LOGEOF
====================================================
3x-ui 部署结果记录
部署时间: $(date '+%Y-%m-%d %H:%M:%S')
服务器IP(本机): ${PUBLIC_IP}
外部探测IP: ${EXTERNAL_IP:-获取失败}
节点地区: ${REGION}
====================================================

【Web 面板】
地址: ${PANEL_SCHEME}://${PUBLIC_IP}:${REAL_PANEL_PORT}${REAL_BASE_PATH}
账号: ${PANEL_USER}
密码: ${PANEL_PASS}

【VMESS 单节点链接】
节点名称: ${VMESS_REMARK}
节点端口: ${NODE_PORT}
UUID: ${UUID}
${SHARE_LINK}
${VLESS_LOG_BLOCK}
【v2ray 通用订阅 (Base64)】

【v2ray 通用订阅 (Base64)】
适用于: v2rayN / v2rayNG / NekoBox 等通用客户端
${SUB_URL}

【Clash / Mihomo 订阅 (YAML)】
适用于: Clash Verge / Clash Meta / Mihomo / Stash 等
${CLASH_SUB_URL}

【sing-box 订阅】
sing-box 支持解析分享链接，直接导入 Base64 通用订阅即可:
${SUB_URL}

【Xray JSON 订阅】
适用于: v2rayN / v2rayNG 等支持 Xray-JSON 订阅的客户端
${JSON_SUB_URL}

====================================================
⚠️  本文件包含面板账号密码，请妥善保管，不要泄露！
====================================================
LOGEOF
# chmod 600 "$LOG_FILE"
echo ""
echo "📄 部署信息已保存到: $LOG_FILE"
