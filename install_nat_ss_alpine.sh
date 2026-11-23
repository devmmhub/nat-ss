#!/bin/sh
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

printf "${GREEN}=== Alpine NAT 极轻量机 Shadowsocks-Rust 一键部署脚本 ===${NC}\n"

# 1. Root 权限与架构检查
if [ "$(id -u)" != "0" ]; then
    printf "${RED}错误: 请使用 root 权限运行${NC}\n"
    exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  SS_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64) SS_ARCH="aarch64-unknown-linux-musl" ;;
    *) printf "${RED}不支持的 CPU 架构: %s${NC}\n" "$ARCH"; exit 1 ;;
esac

# 2. 使用 apk 安装最小化依赖 (--no-cache 不留缓存，省硬盘)
printf "${YELLOW}正在检查并安装基础依赖 (curl, tar, xz, openssl, ca-certificates)...${NC}\n"
apk add --no-cache curl tar xz openssl ca-certificates >/dev/null

# 3. 交互式询问 NAT 映射参数
printf "\n${YELLOW}--- NAT 内外网端口映射配置 ---${NC}\n"

DEFAULT_PUB_IP=$(curl -s4 --connect-timeout 3 -m 5 https://api.ipify.org 2>/dev/null || curl -s4 --connect-timeout 3 -m 5 https://ifconfig.me 2>/dev/null || true)

read -p "1. 请输入客户端连接的【公网 IP】[默认: ${DEFAULT_PUB_IP:-无，请手动输入}]: " PUB_IP < /dev/tty
PUB_IP=${PUB_IP:-$DEFAULT_PUB_IP}
while [ -z "$PUB_IP" ]; do
    read -p "公网 IP 不能为空，请手动输入: " PUB_IP < /dev/tty
done

while true; do
    read -p "2. 请输入服务商分配的【公网映射端口】(外网端口): " PUB_PORT < /dev/tty
    case "$PUB_PORT" in
        ''|*[!0-9]*) printf "端口无效，请输入 1-65535 之间的数字\n" ;;
        *) [ "$PUB_PORT" -ge 1 ] && [ "$PUB_PORT" -le 65535 ] && break || printf "端口无效，请输入 1-65535 之间的数字\n" ;;
    esac
done

while true; do
    read -p "3. 请输入本机监听的【内网端口】[默认与公网端口一致: ${PUB_PORT}]: " LOCAL_PORT < /dev/tty
    LOCAL_PORT=${LOCAL_PORT:-$PUB_PORT}
    case "$LOCAL_PORT" in
        ''|*[!0-9]*) printf "端口无效，请输入 1-65535 之间的数字\n" ;;
        *) [ "$LOCAL_PORT" -ge 1 ] && [ "$LOCAL_PORT" -le 65535 ] && break || printf "端口无效，请输入 1-65535 之间的数字\n" ;;
    esac
done

printf "\n请选择加密方式:\n"
printf "  1) 2022-blake3-aes-128-gcm (推荐，SS-2022 现代加密)\n"
printf "  2) aes-256-gcm (传统兼容协议)\n"
read -p "请输入选项 [1/2, 默认 1]: " METHOD_CHOICE < /dev/tty

if [ "$METHOD_CHOICE" = "2" ]; then
    METHOD="aes-256-gcm"
    PASSWORD=$(openssl rand -base64 16)
else
    METHOD="2022-blake3-aes-128-gcm"
    PASSWORD=$(openssl rand -base64 16)
fi

read -p "4. 请输入节点备注名称 [默认: NAT-SS-Alpine]: " NODE_NAME < /dev/tty
NODE_NAME=${NODE_NAME:-"NAT-SS-Alpine"}

# 4. 下载 shadowsocks-rust 静态二进制包
printf "\n${YELLOW}正在获取 shadowsocks-rust 版本并下载...${NC}\n"
SS_VERSION=$(curl -sL --connect-timeout 5 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest 2>/dev/null | grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
SS_VERSION=${SS_VERSION:-"v1.21.2"}

DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SS_VERSION}/shadowsocks-${SS_VERSION}.${SS_ARCH}.tar.xz"
TMP_DIR=$(mktemp -d)

if ! curl -fL --progress-bar "$DOWNLOAD_URL" -o "${TMP_DIR}/ss.tar.xz"; then
    printf "${RED}下载失败，请检查网络连通性: %s${NC}\n" "$DOWNLOAD_URL"
    rm -rf "$TMP_DIR"
    exit 1
fi

tar -xf "${TMP_DIR}/ss.tar.xz" -C "$TMP_DIR"
install -m 755 "${TMP_DIR}/ssserver" /usr/local/bin/ssserver
rm -rf "$TMP_DIR"

# 5. 生成配置文件
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

# 6. 配置 OpenRC 守护进程并设置开机自启
cat > /etc/init.d/ssserver <<'EOF'
#!/sbin/openrc-run

name="ssserver"
description="Shadowsocks-Rust Server (Alpine NAT)"
command="/usr/local/bin/ssserver"
command_args="-c /etc/shadowsocks-rust/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF

chmod +x /etc/init.d/ssserver
rc-update add ssserver default >/dev/null
rc-service ssserver restart

# 7. 生成 SIP002 链接 (兼容 BusyBox base64 去掉换行)
USER_INFO_B64=$(printf "%s:%s" "${METHOD}" "${PASSWORD}" | base64 | tr -d '\n')
SS_URI="ss://${USER_INFO_B64}@${PUB_IP}:${PUB_PORT}#${NODE_NAME}"

printf "\n${GREEN}==================================================${NC}\n"
printf "${GREEN}Alpine 部署完成！当前版本: %s${NC}\n" "$SS_VERSION"
printf "--------------------------------------------------\n"
printf "公网地址 (Server) : ${YELLOW}%s${NC}\n" "$PUB_IP"
printf "公网端口 (Port)   : ${YELLOW}%s${NC}\n" "$PUB_PORT"
printf "内网监听端口      : %s (绑定 0.0.0.0)\n" "$LOCAL_PORT"
printf "加密方式 (Method) : ${YELLOW}%s${NC}\n" "$METHOD"
printf "连接密码 (Pass)   : ${YELLOW}%s${NC}\n" "$PASSWORD"
printf "--------------------------------------------------\n"
printf "客户端导入链接 (直接复制导入):\n"
printf "${GREEN}%s${NC}\n" "$SS_URI"
printf "${GREEN}==================================================${NC}\n"