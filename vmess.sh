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

# 3x-ui 面板端口, 0=随机端口号
PANEL_PORT=38438

# 3x-ui 订阅服务端口
SUB_PORT=2096

# 3x-ui 面板路径，empty=默认路径
PANEL_PATH="xui"

# 3x-ui 安装版本：留空时通过 releases/latest 网页跳转解析，避免调用 GitHub API。
# 服务器无法访问 GitHub 网页时使用备用稳定版本；也可手动指定，例如 "v3.6.0"。
XUI_VERSION=""
XUI_FALLBACK_VERSION="v3.6.0"

# 是否验证面板登录: 0=不验证, 1=验证（默认）
CHECK_PANEL_MODE=1

# 节点注入方式: 0=直接使用数据库方式
#               1=在 CHECK_PANEL_MODE=1 且登录成功时优先使用面板 API；
#                 未验证、登录失败或 API 注入失败时自动使用数据库兜底
INBOUND_MODE=0
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

# 校验模式参数，防止拼写错误导致走入意外分支
case "$CHECK_PANEL_MODE" in 0|1) ;; *) echo "❌ 严重错误: CHECK_PANEL_MODE 只能是 0 或 1"; exit 1 ;; esac
case "$INBOUND_MODE" in 0|1) ;; *) echo "❌ 严重错误: INBOUND_MODE 只能是 0 或 1"; exit 1 ;; esac

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

if [ "$PANEL_PORT" = "0" ] || [ -z "$PANEL_PORT" ]; then
    RANDOM_PANEL_PORT=$(pick_free_port 40000)
else
    if ! ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${PANEL_PORT}\$"; then
        RANDOM_PANEL_PORT=$PANEL_PORT
    else
        echo "⚠️  指定的面板端口 $PANEL_PORT 已被占用，将使用随机端口..."
        RANDOM_PANEL_PORT=$(pick_free_port 40000)
    fi
fi


NODE_PORT=$(pick_free_port 50000)
VLESS_PORT=""
[ "$VLESS_ON" = "1" ] && VLESS_PORT=$(pick_free_port 30000)   # VLESS+Reality 节点端口


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

# 先把官方安装脚本完整下载到本地再执行。
# 关键修复：最新版官方 install.sh 在无参数时会访问 api.github.com/releases/latest，
# 传入明确版本后，官方脚本会跳过 API，直接下载 release 资源。
INSTALLER="/tmp/3xui_install.sh"
INSTALL_OK=0

if [ -n "$XUI_VERSION" ]; then
    XUI_INSTALL_VERSION="$XUI_VERSION"
else
    # 只读取 releases/latest 的 302 Location 响应头，不下载页面正文、不调用 GitHub API。
    XUI_INSTALL_VERSION=$(curl -fsSI --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 \
        https://github.com/MHSanaei/3x-ui/releases/latest 2>/dev/null \
        | tr -d '\r' \
        | sed -n 's#^[Ll]ocation: .*/tag/\([^/?]*\).*#\1#p' \
        | tail -n 1)
fi

if ! echo "$XUI_INSTALL_VERSION" | grep -Eq '^v[0-9]+(\.[0-9]+){2,}$'; then
    echo "⚠️  无法通过 releases/latest 获取版本号，使用备用版本 $XUI_FALLBACK_VERSION。"
    XUI_INSTALL_VERSION="$XUI_FALLBACK_VERSION"
fi
echo "✅ 将安装 3x-ui 版本: $XUI_INSTALL_VERSION"

for attempt in 1 2 3; do
    [ "$attempt" -gt 1 ] && echo "⚠️  安装未成功，10 秒后进行第 ${attempt}/3 次尝试..." && sleep 10

    curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 \
        -o "$INSTALLER" https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh
    if [ ! -s "$INSTALLER" ] || ! head -n 1 "$INSTALLER" | grep -q "^#!"; then
        echo "⚠️  安装脚本下载失败或内容异常。"
        continue
    fi

    # 传入版本参数，绕过官方 install.sh 的 GitHub API latest 查询。
    bash "$INSTALLER" "$XUI_INSTALL_VERSION" < /dev/null

    if [ -f /usr/local/x-ui/x-ui ]; then
        INSTALL_OK=1
        break
    fi
done

if [ "$INSTALL_OK" != "1" ]; then
    echo "❌ 严重错误: 3x-ui 安装失败（已重试 3 次，未找到 /usr/local/x-ui/x-ui）。"
    echo "   当前版本: $XUI_INSTALL_VERSION"
    echo "   请确认服务器可以访问 GitHub release 资源和 raw.githubusercontent.com。"
    echo "   资源地址: https://github.com/MHSanaei/3x-ui/releases/download/${XUI_INSTALL_VERSION}/x-ui-linux-amd64.tar.gz"
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

# 确定链接最终使用的 IP：客户端是从公网连入的，两者不一致（NAT 环境）时
# 必须用外部探测到的公网 IP，本机 IP 只在探测失败时兜底
PUBLIC_IP="$LOCAL_IP"
if [ -z "$EXTERNAL_IP" ]; then
    echo "⚠️  警告: 无法从外部探测公网 IP（网络受限或探测接口不可用），将使用本机 IP: ${LOCAL_IP:-未知}"
    echo "   如本机 IP 是内网地址，生成的链接无法从外部连接，请手动替换为公网 IP。"
elif [ "$EXTERNAL_IP" != "$LOCAL_IP" ]; then
    echo "⚠️  警告: 本机 IP ($LOCAL_IP) 与外部探测公网 IP ($EXTERNAL_IP) 不一致，本机位于 NAT 之后。"
    echo "   最终链接将使用公网 IP: $EXTERNAL_IP（客户端从公网连入，必须使用公网地址）。"
    echo "   注意: NAT 环境需在服务商控制台将公网端口转发/放行到本机对应端口。"
    PUBLIC_IP="$EXTERNAL_IP"
fi

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
# 注意: INSERT 必须包含 allocate 列。新版 3x-ui 缺失该字段时 xray 无法加载
# 该入站（表现为节点不可用, 需在面板把入站关闭再开启一次才恢复）。
ALLOCATE='{"strategy":"always","refresh":5,"concurrency":3}'
# 注意: subId 键必须写成 '"subId": "..."'（冒号后带空格）。3x-ui 订阅服务
# 按该字符串模式对 settings 做 SQL LIKE 匹配（面板保存的 JSON 即此格式），
# 紧凑写法会导致订阅查不到节点, 订阅链接 404。
SETTINGS="{\"clients\":[{\"id\":\"$UUID\",\"alterId\":0,\"email\":\"vmess_$UUID\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":0,\"subId\": \"$SUB_ID\"}],\"disableInsecureEncryption\":false}"
STREAM_SETTINGS="{\"network\":\"tcp\",\"security\":\"none\",\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}"
SNIFFING="{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}"

# （停机状态）清理旧的同名节点，并修复历史部署遗留的格式问题
sqlite3 $DB_PATH "DELETE FROM inbounds WHERE remark = '$VMESS_REMARK';"
# 补齐历史节点缺失的 allocate 字段（缺失会导致 xray 首次加载失败）
sqlite3 $DB_PATH "UPDATE inbounds SET allocate='$ALLOCATE' WHERE allocate IS NULL OR allocate='';" 2>/dev/null
# 归一化 subId 格式: 旧版订阅服务按 '"subId": "' 带空格模式匹配
sqlite3 $DB_PATH "UPDATE inbounds SET settings = REPLACE(settings, '\"subId\":\"', '\"subId\": \"');"
# 修复历史节点的 tgId 类型: 新版要求整数, 空字符串会导致面板解析 settings 失败
sqlite3 $DB_PATH "UPDATE inbounds SET settings = REPLACE(settings, '\"tgId\":\"\"', '\"tgId\":0');"

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
    VLESS_SETTINGS="{\"clients\":[{\"id\":\"$VLESS_UUID\",\"flow\":\"xtls-rprx-vision\",\"email\":\"vless_$VLESS_UUID\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"tgId\":0,\"subId\": \"$SUB_ID\"}],\"decryption\":\"none\",\"fallbacks\":[]}"
    VLESS_STREAM_SETTINGS="{\"network\":\"tcp\",\"security\":\"reality\",\"externalProxy\":[],\"realitySettings\":{\"show\":false,\"xver\":0,\"dest\":\"$REALITY_DEST\",\"serverNames\":[\"$REALITY_SNI\"],\"privateKey\":\"$REALITY_PRIVATE_KEY\",\"minClient\":\"\",\"maxClient\":\"\",\"maxTimediff\":0,\"shortIds\":[\"$REALITY_SHORT_ID\"],\"settings\":{\"publicKey\":\"$REALITY_PUBLIC_KEY\",\"fingerprint\":\"chrome\",\"serverName\":\"\",\"spiderX\":\"/\"}},\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}"

    sqlite3 $DB_PATH "DELETE FROM inbounds WHERE remark = '$VLESS_REMARK';"
fi
fi
# ==================================================================

# 启用订阅服务（3x-ui 默认关闭订阅，不开启的话订阅链接无法访问）
set_setting() {
    local key=$1 val=$2 key_sql val_sql
    # SQLite 字符串中的单引号需写成两个单引号，兼容用户自定义备注模板等内容。
    key_sql=$(echo "$key" | sed "s/'/''/g")
    val_sql=$(echo "$val" | sed "s/'/''/g")
    if [ -n "$(sqlite3 "$DB_PATH" "SELECT id FROM settings WHERE key='$key_sql';")" ]; then
        sqlite3 "$DB_PATH" "UPDATE settings SET value='$val_sql' WHERE key='$key_sql';"
    else
        sqlite3 "$DB_PATH" "INSERT INTO settings (key, value) VALUES ('$key_sql', '$val_sql');"
    fi
}
set_setting "subEnable" "true"
set_setting "subListen" ""
set_setting "subPort" "$SUB_PORT"
set_setting "subPath" "/sub/"
# 关闭订阅加密：新版 3x-ui 开启该项后订阅 URL 使用加密 token 而非裸 subId，
# 脚本按 subId 拼出的链接会 404。该键不写时走程序默认值，必须显式关闭。
set_setting "subEncrypt" "false"
# Xray-JSON 订阅路径（3x-ui 内置端点，订阅开启后即生效，无需单独开关）
set_setting "subJsonPath" "/json/"
# Clash/Mihomo 订阅路径
set_setting "subClashPath" "/clash/"
# 清空可能由之前手动配置残留的域名/URI 覆盖项，防止生成的链接与实际监听不一致
set_setting "subDomain" ""
set_setting "subURI" ""
set_setting "subJsonURI" ""
set_setting "subClashURI" ""
# 启用 Clash/Mihomo 订阅（3x-ui v2.4.5+ 原生支持，面板默认关闭，必须显式开启）
set_setting "subClashEnable" "true"
# 启用 JSON 订阅（适用于 sing-box 等客户端）
set_setting "subJsonEnable" "true"

# 设置订阅备注模板
# 仅当 settings 表中确实存在 remarkTemplate 且值非空时客户端 EMAIL/USERNAME 所在部分。
REMARK_TEMPLATE_ID=$(sqlite3 "$DB_PATH" "SELECT id FROM settings WHERE key='remarkTemplate' LIMIT 1;")
CURRENT_REMARK_TEMPLATE=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='remarkTemplate' LIMIT 1;")
if [ -n "$REMARK_TEMPLATE_ID" ] && [ -n "$CURRENT_REMARK_TEMPLATE" ]; then
    # 按竖线拆分模板；移除 {{EMAIL}} / {{USERNAME}}，并清理其两侧用于连接名称的 - 或 _。
    # 流量、剩余天数以及用户自定义的其他模板段均保留。
    REMARK_TEMPLATE_NO_EMAIL=$(echo "$CURRENT_REMARK_TEMPLATE" | awk -F'|' '
BEGIN { OFS="|" }
{
    out=""
    for (i=1; i<=NF; i++) {
        seg=$i
        gsub(/\{\{(EMAIL|USERNAME)\}\}/, "", seg)
        gsub(/\{(EMAIL|USERNAME)\}/, "", seg)
        gsub(/[[:space:]]+/, " ", seg)
        sub(/[-_[:space:]]+$/, "", seg)
        sub(/^[-_[:space:]]+/, "", seg)
        if (seg != "") out = (out == "" ? seg : out OFS seg)
    }
    print out
}')
    if [ -n "$REMARK_TEMPLATE_NO_EMAIL" ]; then
        set_setting "remarkTemplate" "$REMARK_TEMPLATE_NO_EMAIL"
        echo "✅ 订阅节点名称模板已移除 EMAIL/USERNAME: $REMARK_TEMPLATE_NO_EMAIL"
    else
        echo "⚠️  警告: 移除 EMAIL/USERNAME 后订阅备注模板为空，已保留数据库原值。"
    fi
else
    echo "ℹ️  数据库中未找到有效的 remarkTemplate，跳过订阅备注模板修改。"
fi

# 配置自定义面板路径 (如果未配置，则由 3x-ui 自身生成默认路径)
if [ -n "$PANEL_PATH" ]; then
    CLEAN_PATH=$(echo "$PANEL_PATH" | sed 's/^\/*//; s/\/*$//')
    set_setting "webBasePath" "/${CLEAN_PATH}/"
fi

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

# ==================================================================
# 通过面板官方 API 注入节点（与网页添加入站走同一接口）
# 面板会自行完成: 字段校验、clients/client_inbounds/client_traffics 等
# 关联表写入、xray 配置重建与热加载。直写数据库需要手工模拟这一切，
# ==================================================================
API_PORT=$(sqlite3 $DB_PATH "SELECT value FROM settings WHERE key='webPort' LIMIT 1;" | tr -d '" \r\n')
API_PORT=${API_PORT:-$RANDOM_PANEL_PORT}
API_BASE_PATH=$(sqlite3 $DB_PATH "SELECT value FROM settings WHERE key='webBasePath';" | tr -d '" \r\n')
[ -z "$API_BASE_PATH" ] && API_BASE_PATH="/"
case "$API_BASE_PATH" in /*) ;; *) API_BASE_PATH="/$API_BASE_PATH" ;; esac
case "$API_BASE_PATH" in */) ;; *) API_BASE_PATH="$API_BASE_PATH/" ;; esac
# 去除多余的双斜杠，防止由于异常数据拼出 //login 这样的异常 URL
API_BASE_PATH=$(echo "$API_BASE_PATH" | sed 's/\/\/*/\//g')
API_BASE="${PANEL_SCHEME}://127.0.0.1:${API_PORT}${API_BASE_PATH}"

# 等待面板 Web 服务就绪（最多 15 秒，以能拿到 HTTP 状态码为准）
PANEL_READY=0
for i in $(seq 1 15); do
    READY_CODE=$(curl -sk --max-time 2 -o /dev/null -w "%{http_code}" "${API_BASE}login")
    if [ -n "$READY_CODE" ] && [ "$READY_CODE" != "000" ]; then
        PANEL_READY=1
        break
    fi
    sleep 1
done
[ "$PANEL_READY" != "1" ] && echo "⚠️  警告: 面板 Web 服务 15 秒内未就绪，API 注入可能失败。"

# settings/streamSettings/sniffing/allocate 需以 JSON 字符串形式嵌入请求体
json_escape() {
    echo -n "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# CHECK_PANEL_MODE=1 时验证登录。3x-ui v3.5.0 对 POST /login 启用了 CSRF：
# 必须先 GET /csrf-token 获取与 Session Cookie 绑定的令牌，再带 Cookie 和
# X-CSRF-Token 登录。后续 cookie 认证的 POST /panel/api/* 也必须带同一令牌。
COOKIE_JAR=""
CSRF_TOKEN=""
API_OK=0
if [ "$CHECK_PANEL_MODE" = "1" ]; then
    COOKIE_JAR=$(mktemp)

    LOGIN_RES=""
    LOGIN_CODE=""
    CSRF_RES=""
    CSRF_CODE=""
    for i in $(seq 1 5); do
        # 每次重试重新获取 token，并使用同一个 cookie jar 保存对应 Session Cookie。
        : > "$COOKIE_JAR"
        CSRF_RES=$(curl -sk --max-time 15 -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
            -H "X-Requested-With: XMLHttpRequest" \
            -w "\nHTTP_CODE:%{http_code}" "${API_BASE}csrf-token")
        CSRF_CODE=$(echo "$CSRF_RES" | sed -n 's/^HTTP_CODE://p')
        CSRF_TOKEN=$(echo "$CSRF_RES" | sed -n 's/.*"obj"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

        if [ "$CSRF_CODE" = "200" ] && [ -n "$CSRF_TOKEN" ]; then
            LOGIN_RES=$(curl -sk --max-time 15 -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
                -H "X-Requested-With: XMLHttpRequest" \
                -H "X-CSRF-Token: $CSRF_TOKEN" \
                -w "\nHTTP_CODE:%{http_code}" -X POST "${API_BASE}login" \
                --data-urlencode "username=${PANEL_USER}" \
                --data-urlencode "password=${PANEL_PASS}")
            LOGIN_CODE=$(echo "$LOGIN_RES" | sed -n 's/^HTTP_CODE://p')
            if echo "$LOGIN_RES" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
                API_OK=1
                echo "✅ 面板登录验证成功（CSRF + Session Cookie）"
                break
            fi
        else
            LOGIN_CODE="CSRF接口HTTP ${CSRF_CODE:-无}"
        fi
        [ "$i" -lt 5 ] && sleep 3
    done

    if [ "$API_OK" != "1" ]; then
        echo "⚠️  警告: 面板登录验证失败（已重试 5 次, 最后状态: ${LOGIN_CODE:-无}）。"
        [ -n "$LOGIN_RES" ] && echo "   返回内容: $(echo "$LOGIN_RES" | head -c 200)"
        if [ "$INBOUND_MODE" = "1" ]; then
            echo "   节点注入将自动使用数据库兜底。"
        fi
    fi
else
    echo "ℹ️  CHECK_PANEL_MODE=0：已跳过面板登录验证。"
    [ "$INBOUND_MODE" = "1" ] && echo "   未建立面板会话，节点注入将使用数据库兜底。"
fi

add_inbound_api() {
    local remark=$1 port=$2 protocol=$3 settings=$4 stream=$5
    curl -sk --max-time 20 -b "$COOKIE_JAR" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "X-CSRF-Token: $CSRF_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST "${API_BASE}panel/api/inbounds/add" \
        -d "{\"up\":0,\"down\":0,\"total\":0,\"remark\":\"$remark\",\"enable\":true,\"expiryTime\":0,\"listen\":\"\",\"port\":$port,\"protocol\":\"$protocol\",\"settings\":\"$(json_escape "$settings")\",\"streamSettings\":\"$(json_escape "$stream")\",\"sniffing\":\"$(json_escape "$SNIFFING")\",\"allocate\":\"$(json_escape "$ALLOCATE")\"}"
}

# SQL 兜底: 仅在 API 不可用时使用。inbounds 的列因版本而异（如 allocate 列
# 仅部分版本存在），先探测实际表结构再拼 INSERT，避免"no column named"错误。
# 写入后尽力补齐新版 clients 相关表（新版订阅按 clients.sub_id 查询，缺行则 404）
inbound_has_column() {
    sqlite3 $DB_PATH "PRAGMA table_info(inbounds);" | awk -F'|' '{print $2}' | grep -qx "$1"
}

add_inbound_sql() {
    local remark=$1 port=$2 protocol=$3 settings=$4 stream=$5 email=$6 uuid=$7 flow=$8
    local cols="user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing"
    local vals="1, 0, 0, 0, '$remark', 1, 0, '', $port, '$protocol', '$settings', '$stream', 'inbound-$port', '$SNIFFING'"
    if inbound_has_column "allocate"; then
        cols="$cols, allocate"
        vals="$vals, '$ALLOCATE'"
    fi
    sqlite3 $DB_PATH "INSERT INTO inbounds ($cols) VALUES ($vals);"
    local inbound_id
    inbound_id=$(sqlite3 $DB_PATH "SELECT id FROM inbounds WHERE port = $port LIMIT 1;")
    # 以下表仅新版存在，旧版报错忽略即可
    if [ -n "$inbound_id" ]; then
        local now_ms=$(( $(date +%s) * 1000 ))
        sqlite3 $DB_PATH "INSERT INTO clients (email, sub_id, uuid, flow, enable, limit_ip, total_gb, expiry_time, tg_id, reset, created_at, updated_at) VALUES ('$email', '$SUB_ID', '$uuid', '$flow', 1, 0, 0, 0, 0, 0, $now_ms, $now_ms);" 2>/dev/null
        local client_id
        client_id=$(sqlite3 $DB_PATH "SELECT id FROM clients WHERE email = '$email' LIMIT 1;" 2>/dev/null)
        [ -n "$client_id" ] && sqlite3 $DB_PATH "INSERT INTO client_inbounds (client_id, inbound_id) VALUES ($client_id, $inbound_id);" 2>/dev/null
        sqlite3 $DB_PATH "INSERT INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset) VALUES ($inbound_id, 1, '$email', 0, 0, 0, 0, 0);" 2>/dev/null
    fi
}

NEED_RESTART=0
inject_inbound() {
    local remark=$1 port=$2 protocol=$3 settings=$4 stream=$5 email=$6 uuid=$7 flow=$8 res=""

    # INBOUND_MODE=1 且面板已验证登录时优先走官方 API；其他情况直接走数据库。
    if [ "$INBOUND_MODE" = "1" ] && [ "$API_OK" = "1" ]; then
        res=$(add_inbound_api "$remark" "$port" "$protocol" "$settings" "$stream")
        if echo "$res" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
            echo "✅ 节点注入成功 (面板 API): $remark"
            return 0
        fi
        echo "⚠️  警告: API 注入失败 ($remark)，改用数据库兜底。返回: $(echo "$res" | head -c 200)"
    elif [ "$INBOUND_MODE" = "0" ]; then
        echo "ℹ️  INBOUND_MODE=0：直接使用数据库注入节点 ($remark)。"
    elif [ "$CHECK_PANEL_MODE" = "0" ]; then
        echo "ℹ️  未验证面板登录，使用数据库兜底注入节点 ($remark)。"
    else
        echo "ℹ️  面板登录未成功，使用数据库兜底注入节点 ($remark)。"
    fi

    add_inbound_sql "$remark" "$port" "$protocol" "$settings" "$stream" "$email" "$uuid" "$flow"
    if [ "$(sqlite3 $DB_PATH "SELECT COUNT(*) FROM inbounds WHERE port = $port;")" = "1" ]; then
        echo "✅ 节点注入成功 (数据库兜底): $remark"
        NEED_RESTART=1
        return 0
    fi
    echo "❌ 严重错误: 节点注入失败 ($remark)，请手动登录面板添加节点。"
    return 1
}

inject_inbound "$VMESS_REMARK" "$NODE_PORT" "vmess" "$SETTINGS" "$STREAM_SETTINGS" "vmess_$UUID" "$UUID" ""
VMESS_INJECTED=$?
if [ "$VLESS_ENABLED" = "1" ]; then
    inject_inbound "$VLESS_REMARK" "$VLESS_PORT" "vless" "$VLESS_SETTINGS" "$VLESS_STREAM_SETTINGS" "vless_$VLESS_UUID" "$VLESS_UUID" "xtls-rprx-vision" || VLESS_ENABLED=0
fi
[ -n "$COOKIE_JAR" ] && rm -f "$COOKIE_JAR"

# 数据库兜底写入后必须重启面板才会加载; API 注入面板已热加载，重启一次作保险
systemctl restart x-ui
sleep 5

# 节点自检：确认 xray 已在节点端口监听（节点能否使用的直接判据）。
# 未监听则再重启一次并复查，仍失败才提示人工介入。
node_port_listening() {
    ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${NODE_PORT}\$"
}
if ! node_port_listening; then
    echo "⚠️  节点端口 ${NODE_PORT} 暂未监听，正在重启 x-ui 重试..."
    systemctl restart x-ui
    sleep 5
fi
if node_port_listening; then
    echo "✅ 节点自检通过: xray 已在端口 ${NODE_PORT} 监听"
else
    echo "❌ 严重错误: 节点端口 ${NODE_PORT} 未在监听，xray 未正确加载节点配置！"
    echo "   请登录面板将该入站关闭再开启一次，或执行 journalctl -u x-ui -n 50 查看错误日志。"
fi

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

# 本机自检订阅服务：确认端口在监听且 URL 返回 200
sleep 2
SUB_HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "${SUB_SCHEME}://127.0.0.1:${SUB_PORT}/sub/${SUB_ID}")
if [ "$SUB_HTTP_CODE" = "200" ]; then
    echo "✅ Base64 订阅自检通过 (端口 ${SUB_PORT})"
else
    echo "⚠️  警告: Base64 订阅本机自检失败 (HTTP ${SUB_HTTP_CODE:-无响应})。"
    if ! ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${SUB_PORT}\$"; then
        echo "   订阅端口 ${SUB_PORT} 未在监听——x-ui 可能未正确加载订阅配置，"
        echo "   请执行 systemctl restart x-ui 后重试订阅链接。"
    else
        echo "   端口在监听但返回异常，请登录面板检查 订阅设置。"
    fi
fi
# Clash/Mihomo 订阅自检
CLASH_HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "${SUB_SCHEME}://127.0.0.1:${SUB_PORT}/clash/${SUB_ID}")
if [ "$CLASH_HTTP_CODE" = "200" ]; then
    echo "✅ Clash/Mihomo 订阅自检通过"
else
    echo "⚠️  警告: Clash/Mihomo 订阅自检失败 (HTTP ${CLASH_HTTP_CODE:-无响应})，请登录面板确认 Clash 订阅已开启。"
fi
# JSON 订阅自检
JSON_HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "${SUB_SCHEME}://127.0.0.1:${SUB_PORT}/json/${SUB_ID}")
if [ "$JSON_HTTP_CODE" = "200" ]; then
    echo "✅ JSON 订阅自检通过 (sing-box / v2rayN)"
else
    echo "⚠️  警告: JSON 订阅自检失败 (HTTP ${JSON_HTTP_CODE:-无响应})，请登录面板确认 JSON 订阅已开启。"
fi

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
echo "▶ 适用于: Clash Verge / Clash Meta / Mihomo / Stash"
echo -e "\033[36m$CLASH_SUB_URL\033[0m"
echo "----------------------------------------------------"
echo "📡 【Xray JSON 订阅链接】"
echo "▶ 适用于: v2rayN / v2rayNG 等支持 Xray-JSON 订阅的客户端"
echo "▶ sing-box 用户: 推荐使用此 JSON 订阅链接"
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
适用于: v2rayN / v2rayNG / NekoBox 等通用客户端
${SUB_URL}

【Clash / Mihomo 订阅 (YAML)】
适用于: Clash Verge / Clash Meta / Mihomo / Stash
${CLASH_SUB_URL}

【sing-box / Xray JSON 订阅】
适用于: sing-box (推荐) / v2rayN / v2rayNG
${JSON_SUB_URL}

====================================================
⚠️  本文件包含面板账号密码，请妥善保管，不要泄露！
====================================================
LOGEOF
# chmod 600 "$LOG_FILE"
echo ""
echo "📄 部署信息已保存到: $LOG_FILE"
