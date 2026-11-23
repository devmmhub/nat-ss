#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== NAT 极轻量机 Shadowsocks-Rust 一键部署脚本 ===${NC}"

# 1. Root 权限与系统架构检查
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误: 请使用 root 权限运行 (sudo -i)${NC}"
    exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  SS_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64) SS_ARCH="aarch64-unknown-linux-musl" ;;
    *) echo -e "${RED}不支持的 CPU 架构: $ARCH${NC}"; exit 1 ;;
esac

# 2. 自动补齐最小化依赖 (适配 Debian / Ubuntu)
NEED_PKGS=""
for pkg in curl tar xz openssl; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        [ "$pkg" = "xz" ] && NEED_PKGS="$NEED_PKGS xz-utils" || NEED_PKGS="$NEED_PKGS $pkg"
    fi
done

if [ -n "$NEED_PKGS" ] || [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
    echo -e "${YELLOW}正在安装缺失的基础组件:${NEED_PKGS} ca-certificates ...${NC}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $NEED_PKGS ca-certificates
fi

# 3. 交互式询问 NAT 内外网映射参数 (使用 /dev/tty 兼容管道执行)
echo -e "\n${YELLOW}--- NAT 内外网端口映射配置 ---${NC}"

DEFAULT_PUB_IP=$(curl -s4 --connect-timeout 3 -m 5 https://api.ipify.org 2>/dev/null || curl -s4 --connect-timeout 3 -m 5 https://ifconfig.me 2>/dev/null || true)

read -p "1. 请输入客户端连接的【公网 IP】[默认: ${DEFAULT_PUB_IP:-无，请手动输入}]: " PUB_IP < /dev/tty
PUB_IP=${PUB_IP:-$DEFAULT_PUB_IP}
while [ -z "$PUB_IP" ]; do
    read -p "公网 IP 不能为空，请手动输入: " PUB_IP < /dev/tty
done

read -p "2. 请输入服务商分配的【公网映射端口】(外网端口): " PUB_PORT < /dev/tty
while [[ ! "$PUB_PORT" =~ ^[0-9]+$ ]] || [ "$PUB_PORT" -lt 1 ] || [ "$PUB_PORT" -gt 65535 ]; do
    read -p "端口无效，请输入 1-65535 之间的公网端口: " PUB_PORT < /dev/tty
done

read -p "3. 请输入本机监听的【内网端口】[默认与公网端口一致: ${PUB_PORT}]: " LOCAL_PORT < /dev/tty
LOCAL_PORT=${LOCAL_PORT:-$PUB_PORT}
while [[ ! "$LOCAL_PORT" =~ ^[0-9]+$ ]] || [ "$LOCAL_PORT" -lt 1 ] || [ "$LOCAL_PORT" -gt 65535 ]; do
    read -p "端口无效，请输入 1-65535 之间的内网端口: " LOCAL_PORT < /dev/tty
done

echo -e "\n请选择加密方式:"
echo "  1) 2022-blake3-aes-128-gcm (推荐，SS-2022 现代加密，性能极高)"
echo "  2) aes-256-gcm (传统兼容协议)"
read -p "请输入选项 [1/2, 默认 1]: " METHOD_CHOICE < /dev/tty

if [ "$METHOD_CHOICE" = "2" ]; then
    METHOD="aes-256-gcm"
    PASSWORD=$(openssl rand -base64 16)
else
    METHOD="2022-blake3-aes-128-gcm"
    PASSWORD=$(openssl rand -base64 16)
fi

read -p "4. 请输入节点备注名称 [默认: NAT-SS]: " NODE_NAME < /dev/tty
NODE_NAME=${NODE_NAME:-"NAT-SS"}

# 4. 自动获取最新版本并下载静态二进制包
echo -e "\n${YELLOW}正在获取 shadowsocks-rust 版本并下载...${NC}"
SS_VERSION=$(curl -sL --connect-timeout 5 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest 2>/dev/null | grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
SS_VERSION=${SS_VERSION:-"v1.21.2"}

DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SS_VERSION}/shadowsocks-${SS_VERSION}.${SS_ARCH}.tar.xz"
TMP_DIR=$(mktemp -d)

if ! curl -fL --progress-bar "$DOWNLOAD_URL" -o "${TMP_DIR}/ss.tar.xz"; then
    echo -e "${RED}下载失败，请检查机器是否能连通 GitHub: ${DOWNLOAD_URL}${NC}"
    rm -rf "$TMP_DIR"
    exit 1
fi

tar -xf "${TMP_DIR}/ss.tar.xz" -C "$TMP_DIR"
install -m 755 "${TMP_DIR}/ssserver" /usr/local/bin/ssserver
rm -rf "$TMP_DIR"

# 5. 生成服务端配置文件
mkdir -p /etc/shadowsocks-rust
cat > /etc/shadowsocks-rust/config.json <<EOF
{
    "server": "0.0.0.0",
    "server_port": ${LOCAL_PORT},
    "password": "${PASSWORD}",
    "method": "${METHOD}",
    "mode": "tcp_and_udp",
    "fast_open": false,
    "no_delay": true
}
EOF

# 6. 配置 Systemd 守护进程 (限制内存上限 48M 防止小内存机 OOM)
cat > /etc/systemd/system/ssserver.service <<EOF
[Unit]
Description=Shadowsocks-Rust Server (NAT Lightweight)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=always
RestartSec=3
LimitNOFILE=65535
MemoryMax=48M

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ssserver

# 7. 输出客户端导入链接 (SIP002 格式)
USER_INFO_B64=$(printf "%s:%s" "${METHOD}" "${PASSWORD}" | base64 -w 0)
SS_URI="ss://${USER_INFO_B64}@${PUB_IP}:${PUB_PORT}#${NODE_NAME}"

echo -e "\n${GREEN}==================================================${NC}"
echo -e "${GREEN}部署完成！当前版本: ${SS_VERSION}${NC}"
echo -e "--------------------------------------------------"
echo -e "公网地址 (Server) : ${YELLOW}${PUB_IP}${NC}"
echo -e "公网端口 (Port)   : ${YELLOW}${PUB_PORT}${NC}"
echo -e "内网监听端口      : ${LOCAL_PORT} (绑定 0.0.0.0)"
echo -e "加密方式 (Method) : ${YELLOW}${METHOD}${NC}"
echo -e "连接密码 (Pass)   : ${YELLOW}${PASSWORD}${NC}"
echo -e "--------------------------------------------------"
echo -e "客户端导入链接 (直接复制导入):"
echo -e "${GREEN}${SS_URI}${NC}"
echo -e "${GREEN}==================================================${NC}"