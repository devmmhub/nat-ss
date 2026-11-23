#!/bin/sh

# ==========================================================
# Alpine Linux (OpenRC) VLESS + Reality 一键部署脚本 (NAT 专用版)
# ==========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 1. 检查 Root 权限
if [ "$(id -u)" -ne 0 ]; then
    printf "${RED}错误：请使用 root 用户运行此脚本。${NC}\n"
    exit 1
fi

# 端口校验函数
is_valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -ge 1 ] && [ "$1" -le 65535 ] ;;
    esac
}

printf "${CYAN}==================================================${NC}\n"
printf "${CYAN}   Alpine Linux VLESS + Reality (NAT 机专用脚本)  ${NC}\n"
printf "${CYAN}==================================================${NC}\n\n"

# 2. 安装基础依赖
printf "${YELLOW}[1/5] 正在更新 apk 并安装基础依赖...${NC}\n"
apk update >/dev/null 2>&1
apk add --no-cache curl unzip openssl ca-certificates >/dev/null 2>&1 || {
    printf "${RED}依赖安装失败，请检查网络连接或软件源。${NC}\n"
    exit 1
}

# 3. 识别架构并下载最新版 Xray-core
printf "${YELLOW}[2/5] 正在检测系统架构并下载最新版 Xray-core...${NC}\n"
MACHINE_ARCH=$(uname -m)
case "$MACHINE_ARCH" in
    x86_64|amd64)   XRAY_ARCH="64" ;;
    aarch64|arm64)  XRAY_ARCH="arm64-v8a" ;;
    armv7l)         XRAY_ARCH="arm32-v7a" ;;
    *)
        printf "${RED}不支持的架构: %s${NC}\n" "$MACHINE_ARCH"
        exit 1
        ;;
esac

# 通过重定向获取最新版本号（避开 GitHub API 共享 IP 限流）
LATEST_URL=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/XTLS/Xray-core/releases/latest)
XRAY_VER=$(echo "$LATEST_URL" | awk -F'/' '{print $NF}')

if [ -z "$XRAY_VER" ] || [ "$XRAY_VER" = "latest" ]; then
    printf "${RED}获取 Xray 最新版本失败，请检查本机能否访问 GitHub。${NC}\n"
    exit 1
fi

printf "检测到架构: ${GREEN}%s${NC}，最新版本: ${GREEN}%s${NC}\n" "$MACHINE_ARCH" "$XRAY_VER"

TMP_DIR="/tmp/xray_install"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR" /usr/local/bin /usr/local/share/xray /etc/xray

DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${XRAY_ARCH}.zip"
curl -fL --progress-bar "$DOWNLOAD_URL" -o "${TMP_DIR}/xray.zip" || {
    printf "${RED}下载 Xray-core 失败。${NC}\n"
    rm -rf "$TMP_DIR"
    exit 1
}

unzip -oq "${TMP_DIR}/xray.zip" -d "$TMP_DIR"
mv -f "${TMP_DIR}/xray" /usr/local/bin/xray
chmod +x /usr/local/bin/xray
[ -f "${TMP_DIR}/geoip.dat" ] && mv -f "${TMP_DIR}/geoip.dat" /usr/local/share/xray/
[ -f "${TMP_DIR}/geosite.dat" ] && mv -f "${TMP_DIR}/geosite.dat" /usr/local/share/xray/
rm -rf "$TMP_DIR"

# 4. 交互式收集 NAT 映射与节点配置
printf "\n${YELLOW}[3/5] 请配置 NAT 映射与节点参数${NC}\n"

# 4.1 公网入口 IP 或域名
DETECTED_IP=$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
if [ -n "$DETECTED_IP" ]; then
    printf "检测到本机出口 IPv4 为: ${GREEN}%s${NC}\n" "$DETECTED_IP"
    printf "提示：如果 NAT 机的【入站连接 IP / DDNS 域名】与出口 IP 不同，请手动输入。\n"
    printf "请输入客户端连接的公网 IP 或域名 [直接回车使用 %s]: " "$DETECTED_IP"
    read -r INPUT_HOST
    PUBLIC_HOST="${INPUT_HOST:-$DETECTED_IP}"
else
    while [ -z "$PUBLIC_HOST" ]; do
        printf "未能自动获取公网 IP，请手动输入 NAT 入站公网 IP 或域名: "
        read -r PUBLIC_HOST
    done
fi

# 4.2 NAT 端口映射方式
printf "\n请选择你的 NAT 端口映射方式:\n"
printf "  ${GREEN}1)${NC} 内外网端口一致（例如：外网 20001 -> 内网 20001）\n"
printf "  ${GREEN}2)${NC} 内外网端口不一致（例如：外网 20001 -> 内网 10001）\n"
printf "请选择 [默认 1]: "
read -r NAT_MODE
NAT_MODE="${NAT_MODE:-1}"

if [ "$NAT_MODE" = "2" ]; then
    while true; do
        printf "请输入【VPS 内网监听端口】（10000-65535，与 NAT 规则目标端口一致）: "
        read -r INTERNAL_PORT
        if is_valid_port "$INTERNAL_PORT"; then
            [ "$INTERNAL_PORT" -lt 10000 ] && printf "${YELLOW}注意：该端口小于 10000，请确认是否符合商家端口规定。${NC}\n"
            break
        fi
        printf "${RED}端口无效，请输入 1-65535 之间的数字。${NC}\n"
    done

    while true; do
        printf "请输入【公网外部映射端口】（供客户端连接使用）: "
        read -r EXTERNAL_PORT
        if is_valid_port "$EXTERNAL_PORT"; then
            [ "$EXTERNAL_PORT" -lt 10000 ] && printf "${YELLOW}注意：该端口小于 10000，请确认是否符合商家端口规定。${NC}\n"
            break
        fi
        printf "${RED}端口无效，请输入 1-65535 之间的数字。${NC}\n"
    done
else
    while true; do
        printf "请输入 NAT 映射端口（建议 10000-65535，内外网相同）: "
        read -r INTERNAL_PORT
        if is_valid_port "$INTERNAL_PORT"; then
            [ "$INTERNAL_PORT" -lt 10000 ] && printf "${YELLOW}注意：该端口小于 10000，请确认是否符合商家端口规定。${NC}\n"
            EXTERNAL_PORT="$INTERNAL_PORT"
            break
        fi
        printf "${RED}端口无效，请输入 1-65535 之间的数字。${NC}\n"
    done
fi

# 4.3 伪装目标域名 (SNI)
printf "\n请输入 Reality 伪装目标域名 (SNI) [默认 www.apple.com]: "
read -r INPUT_SNI
SNI="${INPUT_SNI:-www.apple.com}"

# 4.4 流控模式选择
printf "\n请选择 VLESS 流控模式 (Flow):\n"
printf "  ${GREEN}1)${NC} xtls-rprx-vision（默认推荐，适合 Karing / Stash / Sing-box / v2rayN）\n"
printf "  ${GREEN}2)${NC} 留空/无流控（部分不支持 Vision 链式代理的客户端可尝试此项）\n"
printf "请选择 [默认 1]: "
read -r FLOW_CHOICE
if [ "$FLOW_CHOICE" = "2" ]; then
    FLOW=""
else
    FLOW="xtls-rprx-vision"
fi

# 4.5 节点备注名称
printf "\n请输入节点备注名称（建议英文/数字，不含空格）[默认 Turkey-NAT-Reality]: "
read -r INPUT_REMARK
REMARK=$(echo "${INPUT_REMARK:-Turkey-NAT-Reality}" | tr ' ' '_')

# 5. 生成密钥与配置文件
printf "\n${YELLOW}[4/5] 正在生成 Reality 密钥与配置文件...${NC}\n"
UUID=$(/usr/local/bin/xray uuid)
KEYS=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | awk -F':' '/Private/ {print $2}' | tr -d ' \r\n')
PUBLIC_KEY=$(echo "$KEYS" | awk -F':' '/Public|Password/ {print $2}' | tr -d ' \r\n')
SHORT_ID=$(openssl rand -hex 8)

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    printf "${RED}密钥生成解析失败，原始输出如下：${NC}\n%s\n" "$KEYS"
    exit 1
fi

cat << EOF > /etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${INTERNAL_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "${FLOW}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

# 校验配置语法
/usr/local/bin/xray run -test -config /etc/xray/config.json >/dev/null 2>&1 || {
    printf "${RED}配置文件语法校验失败，请检查 /etc/xray/config.json。${NC}\n"
    exit 1
}

# 6. 创建并启动 OpenRC 服务
printf "${YELLOW}[5/5] 正在配置 Alpine OpenRC 服务并启动...${NC}\n"
cat << 'EOF' > /etc/init.d/xray
#!/sbin/openrc-run

name="xray"
description="Xray VLESS-Reality Service"
command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.err"

export XRAY_LOCATION_ASSET="/usr/local/share/xray"

depend() {
    need net
    after firewall
}
EOF

chmod +x /etc/init.d/xray
rc-update add xray default >/dev/null 2>&1
rc-service xray restart

# 7. 拼接客户端分享链接（处理 IPv6 方括号与可选 flow 参数）
case "$PUBLIC_HOST" in
    *:*) LINK_HOST="[${PUBLIC_HOST}]" ;;
    *)   LINK_HOST="${PUBLIC_HOST}" ;;
esac

if [ -n "$FLOW" ]; then
    FLOW_PARAM="&flow=${FLOW}"
else
    FLOW_PARAM=""
fi

VLESS_LINK="vless://${UUID}@${LINK_HOST}:${EXTERNAL_PORT}?encryption=none${FLOW_PARAM}&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${REMARK}"

# 保存节点信息到文件方便日后查看
cat << EOF > /etc/xray/node_info.txt
================ VLESS + Reality 节点信息 ================
公网入站地址 (Address) : ${PUBLIC_HOST}
公网映射端口 (Ext Port): ${EXTERNAL_PORT}
内网监听端口 (Int Port): ${INTERNAL_PORT}
用户 ID (UUID)         : ${UUID}
流控模式 (Flow)        : ${FLOW:-无}
伪装域名 (SNI)         : ${SNI}
公钥 (PublicKey/pbk)   : ${PUBLIC_KEY}
短 ID (ShortId/sid)    : ${SHORT_ID}
指纹 (Fingerprint)     : chrome

分享链接 (直接导入客户端):
${VLESS_LINK}
==========================================================
EOF

printf "\n${GREEN}部署完成！${NC}\n\n"
cat /etc/xray/node_info.txt
printf "\n常用管理命令：\n"
printf "  查看状态: ${CYAN}rc-service xray status${NC}\n"
printf "  重启服务: ${CYAN}rc-service xray restart${NC}\n"
printf "  查看日志: ${CYAN}cat /var/log/xray.err${NC}\n"
printf "  复查节点: ${CYAN}cat /etc/xray/node_info.txt${NC}\n"