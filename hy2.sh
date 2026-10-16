#!/usr/bin/env bash
#
# 一键安装 Hysteria2 服务端 (手搓版)
#
# 用法:
#   bash hy2.sh                          # 默认 10000~65535 随机 UDP 端口,随机密码
#   HY2_PORT=8443 bash hy2.sh            # 自定义端口
#   HY2_PASSWORD=xxxxxx bash hy2.sh      # 自定义密码
#   HY2_HOP="20000:30000" bash hy2.sh    # 端口跳跃:Surge 在该 UDP 段内轮跳
#                                        # (需独立 IP,iptables 做段转发;NAT 机不适用)
#
# 支持: Debian / Ubuntu / Alpine,systemd / OpenRC
#
set -e

# ---------------- 配置 ----------------
CONFIG_DIR="/etc/hysteria"
BIN="/usr/local/bin/hysteria"
SNI_DOMAIN="www.bing.com"

# 端口:没指定就 10000~65535 随机
if [ -z "$HY2_PORT" ]; then
  if command -v shuf >/dev/null 2>&1; then
    HY2_PORT="$(shuf -i 10000-65535 -n 1)"
  else
    HY2_PORT="$(awk 'BEGIN{srand(); print int(10000+rand()*55536)}')"
  fi
fi

# ---------------- 端口跳跃 (可选) ----------------
# 原理: Surge 在 HOP_START:HOP_END 段内轮跳 UDP 端口;
#       服务端用 iptables 把整段转发到 HY2_PORT,hysteria 本体只监听一个端口。
# 注意: NAT 机每个端口都要商家单独映射,不适用;只适合有独立 IP 的机器。
HOP_START=""
HOP_END=""
if [ -n "$HY2_HOP" ]; then
  _HOP_RANGE="$(echo "$HY2_HOP" | tr '-' ':')"
  HOP_START="${_HOP_RANGE%%:*}"
  HOP_END="${_HOP_RANGE##*:}"
  if ! [[ "$HOP_START" =~ ^[0-9]+$ && "$HOP_END" =~ ^[0-9]+$ ]] \
     || [ "$HOP_START" -lt 1 ] || [ "$HOP_END" -gt 65535 ] \
     || [ "$HOP_START" -ge "$HOP_END" ]; then
    echo "HY2_HOP 格式错误,应为 起始:结束,例如 \"20000:30000\""
    exit 1
  fi
  echo "端口跳跃: UDP ${HOP_START}:${HOP_END} -> ${HY2_PORT}"
fi

# ---------------- 必须是 root ----------------
if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行: sudo bash $0"
  exit 1
fi

# ---------------- 架构 ----------------
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

# ---------------- 装依赖 ----------------
echo "==> 安装依赖..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq curl openssl ca-certificates >/dev/null
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache curl openssl ca-certificates >/dev/null
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q curl openssl ca-certificates >/dev/null
else
  echo "未知包管理器,请手动装好 curl 和 openssl 再跑"
  exit 1
fi

# 端口跳跃必须有 iptables
if [ -n "$HOP_START" ] && ! command -v iptables >/dev/null 2>&1; then
  echo "==> 安装 iptables (端口跳跃需要)..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y -qq iptables >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache iptables >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q iptables >/dev/null
  fi
fi

# ---------------- 下载 hysteria2 ----------------
echo "==> 下载 Hysteria2..."
curl -fsSL -o "$BIN" "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
chmod +x "$BIN"
"$BIN" version 2>/dev/null | head -1 || true

# ---------------- 生成密码和证书 ----------------
if [ -z "$HY2_PASSWORD" ]; then
  HY2_PASSWORD="$(openssl rand -hex 16)"
fi
mkdir -p "$CONFIG_DIR"
echo "==> 生成自签证书..."
openssl req -x509 -newkey rsa:2048 \
  -keyout "$CONFIG_DIR/cert.key" \
  -out "$CONFIG_DIR/cert.crt" \
  -days 3650 -nodes \
  -subj "/CN=${SNI_DOMAIN}" 2>/dev/null
chmod 600 "$CONFIG_DIR/cert.key"

# ---------------- 写配置 ----------------
echo "==> 写入配置..."
cat > "$CONFIG_DIR/config.yaml" <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${CONFIG_DIR}/cert.crt
  key: ${CONFIG_DIR}/cert.key

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
chmod 600 "$CONFIG_DIR/config.yaml"

# ---------------- 放行防火墙 (UDP) ----------------
echo "==> 放行 UDP/${HY2_PORT}..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${HY2_PORT}/udp" >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${HY2_PORT}/udp" >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
elif command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p udp --dport "${HY2_PORT}" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p udp --dport "${HY2_PORT}" -j ACCEPT 2>/dev/null || true
fi

# ---------------- 端口跳跃:防火墙段转发 ----------------
if [ -n "$HOP_START" ]; then
  echo "==> 配置端口跳跃转发 (UDP ${HOP_START}:${HOP_END} -> ${HY2_PORT})..."
  # 生成幂等的转发脚本:整段 REDIRECT 到主端口 + 放行 INPUT
  cat > /usr/local/bin/hy2-hop-nat.sh <<EOF
#!/bin/sh
# Hysteria2 端口跳跃转发规则 (幂等,可重复执行)
iptables -t nat -C PREROUTING -p udp --dport ${HOP_START}:${HOP_END} -j REDIRECT --to-port ${HY2_PORT} 2>/dev/null \
  || iptables -t nat -A PREROUTING -p udp --dport ${HOP_START}:${HOP_END} -j REDIRECT --to-port ${HY2_PORT} 2>/dev/null || true
iptables -C INPUT -p udp --dport ${HOP_START}:${HOP_END} -j ACCEPT 2>/dev/null \
  || iptables -I INPUT -p udp --dport ${HOP_START}:${HOP_END} -j ACCEPT 2>/dev/null || true
EOF
  chmod +x /usr/local/bin/hy2-hop-nat.sh
  if /usr/local/bin/hy2-hop-nat.sh 2>/dev/null; then
    echo "转发规则已生效"
  else
    echo "警告: iptables NAT 规则写入失败(容器/受限内核常见),端口跳跃可能不工作"
    echo "请手动执行 /usr/local/bin/hy2-hop-nat.sh 查看报错"
  fi
  # 开机持久化
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    cat > /etc/systemd/system/hysteria-hop-nat.service <<EOF
[Unit]
Description=Hysteria2 port hopping NAT rules
After=network.target
Before=hysteria-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/hy2-hop-nat.sh

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-hop-nat >/dev/null 2>&1 || true
    echo "已注册开机任务: hysteria-hop-nat.service"
  elif command -v rc-service >/dev/null 2>&1; then
    mkdir -p /etc/local.d
    cat > /etc/local.d/hy2-hop-nat.start <<'RCEOF'
#!/bin/sh
/usr/local/bin/hy2-hop-nat.sh
RCEOF
    chmod +x /etc/local.d/hy2-hop-nat.start
    rc-update add local default >/dev/null 2>&1 || true
    echo "已注册开机任务: /etc/local.d/hy2-hop-nat.start"
  else
    echo "未识别 init 系统,重启后请手动执行 /usr/local/bin/hy2-hop-nat.sh 恢复转发"
  fi
fi

# ---------------- BBR ----------------
echo "==> 开启 BBR..."
sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
  { echo "net.core.default_qdisc=fq"; echo "net.ipv4.tcp_congestion_control=bbr"; } >> /etc/sysctl.conf 2>/dev/null || true
fi

# ---------------- 注册服务并启动 ----------------
echo "==> 启动 Hysteria2..."
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
ExecStart=${BIN} server -c ${CONFIG_DIR}/config.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now hysteria-server >/dev/null
  sleep 2
  if systemctl is-active --quiet hysteria-server; then
    echo "服务运行中"
  else
    echo "服务启动失败,查看: journalctl -u hysteria-server -n 50"
    exit 1
  fi
elif command -v rc-service >/dev/null 2>&1; then
  cat > /etc/init.d/hysteria <<'RCEOF'
#!/sbin/openrc-run
name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria.pid"
depend() {
  need net
}
RCEOF
  chmod +x /etc/init.d/hysteria
  rc-update add hysteria default >/dev/null 2>&1 || true
  rc-service hysteria restart >/dev/null 2>&1 || rc-service hysteria start >/dev/null 2>&1 || true
  sleep 2
  rc-service hysteria status 2>/dev/null | grep -qi "started" && echo "服务运行中" || echo "请手动检查: rc-service hysteria status"
else
  echo "没找到 systemd/openrc,请手动运行: ${BIN} server -c ${CONFIG_DIR}/config.yaml"
fi

# ---------------- 取本机公网 IP ----------------
SERVER_IP="$(curl -s4 --max-time 8 https://api.ip.sb/ip 2>/dev/null || curl -s4 --max-time 8 https://ifconfig.me 2>/dev/null || echo "你的服务器IP")"
SERVER_IP="$(echo "$SERVER_IP" | tr -d ' \r\n')"

# ---------------- 输出结果 ----------------
echo ""
echo "=============================================="
echo " Hysteria2 安装完成!"
echo "=============================================="
echo "端口:  ${HY2_PORT} (UDP)"
echo "密码:  ${HY2_PASSWORD}"
echo "SNI:   ${SNI_DOMAIN}"
if [ -n "$HOP_START" ]; then
  echo "跳跃段: ${HOP_START}:${HOP_END} (UDP) -> ${HY2_PORT}"
fi
echo ""
echo "--- 通用链接 (v2rayN / Nekoray / Streisand 可导入) ---"
echo "hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?sni=${SNI_DOMAIN}&insecure=1#HY2-${HY2_PORT}"
if [ -n "$HOP_START" ]; then
  echo "(注: 通用链接不带端口跳跃,其他客户端请按各客户端格式自行加跳跃段)"
fi
echo ""
echo "--- Surge 配置 (加到 [Proxy] 段) ---"
SURGE_LINE="HY2-${HY2_PORT} = hysteria2, ${SERVER_IP}, ${HY2_PORT}, password=${HY2_PASSWORD}, sni=${SNI_DOMAIN}, skip-cert-verify=true"
if [ -n "$HOP_START" ]; then
  SURGE_LINE="${SURGE_LINE}, port-hopping=\"${HOP_START}-${HOP_END}\", port-hopping-interval=30"
fi
echo "$SURGE_LINE"
if [ -n "$HOP_START" ]; then
  echo "(注: 开启端口跳跃后 Surge 会忽略行首主端口,在 ${HOP_START}-${HOP_END} 内每 30 秒轮跳)"
fi
echo ""
echo "--- 常用命令 ---"
echo "systemd: systemctl status|restart hysteria-server"
echo "OpenRC : rc-service hysteria status|restart   (Alpine 用这个)"
echo "配置:    ${CONFIG_DIR}/config.yaml"
echo "=============================================="
