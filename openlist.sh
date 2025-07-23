#!/bin/bash
set -euo pipefail

# 检查是否以 root 身份运行
if [[ $EUID -ne 0 ]]; then
  echo "本脚本必须以 root 用户运行。" >&2
  exit 1
fi

# 1. 询问域名并清理前缀
read -rp "请输入您的域名 (例如 example.com): " INPUT_DOMAIN
# 去掉可能的前导 'www.' 或 ':'
DOMAIN=${INPUT_DOMAIN#www.}
DOMAIN=${DOMAIN#:}
# 生成带 www 的域名
WWW_DOMAIN="www.$DOMAIN"

# 2. 随机生成一个高位端口供 OpenList 使用
PORT=$(shuf -i 20000-65000 -n1)
echo "已选择 OpenList 端口：$PORT"

# 3. 自动检测根分区设备以便后续磁盘检测
ROOT_DEV=$(df / --output=source | tail -n1)
echo "检测到根分区设备：$ROOT_DEV"

# 4. 检查并安装必要依赖（包含 nginx）
apt-get update
# 必装依赖
apt-get install -y wget tar socat curl cron jq

# 判断 nginx 是否已安装
if command -v nginx >/dev/null 2>&1; then
  echo "检测到 nginx 已安装，跳过安装 nginx 步骤。"
else
  echo "未检测到 nginx，正在安装 nginx..."
  apt-get install -y nginx
fi

# 5. 下载并安装 OpenList
cd /tmp
wget https://github.com/OpenListTeam/OpenList/releases/latest/download/openlist-linux-amd64.tar.gz
tar zxvf openlist-linux-amd64.tar.gz
mkdir -p /app/openlist
mv openlist /app/openlist/openlist
chmod +x /app/openlist/openlist

# 6. 初始化 OpenList 管理员并获取初始密码
cd /app/openlist
ADMIN_OUTPUT=$(./openlist admin)
PASSWORD=$(echo "$ADMIN_OUTPUT" | grep -Eo 'Password: .*' | cut -d' ' -f2)

# 7. 修改 OpenList 配置文件中的端口号
CONFIG_FILE=/app/openlist/data/config.json
jq ".server.port = $PORT" "$CONFIG_FILE" > /app/openlist/data/config.tmp && mv /app/openlist/data/config.tmp "$CONFIG_FILE"

# 8. 创建系统用户和设置权限
groupadd --system openlist || true
useradd --system --gid openlist --create-home --shell /usr/sbin/nologin --comment "openlist" openlist || true
chown -R openlist:openlist /app/openlist

# 9. 创建并启用 OpenList systemd 服务
cat >/etc/systemd/system/openlist.service <<EOF
[Unit]
Description=OpenList 服务
After=network.target

[Service]
User=openlist
Group=openlist
Type=simple
WorkingDirectory=/app/openlist
ExecStart=/app/openlist/openlist server --port $PORT
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openlist.service
systemctl start openlist.service

# 10. 申请并安装 SSL 证书（acme.sh）
systemctl stop nginx || true
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl
~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" -d "$WWW_DOMAIN" -k ec-256
~/.acme.sh/acme.sh --installcert -d "$DOMAIN" -d "$WWW_DOMAIN" \
    --fullchain-file /etc/nginx/ssl/$WWW_DOMAIN.crt \
    --key-file /etc/nginx/ssl/$WWW_DOMAIN.key --ecc

# 11. 配置 Nginx 反向代理
cat >/etc/nginx/nginx.conf <<EOF
user  root;
worker_processes  auto;
error_log  /etc/nginx/error.log warn;
pid        /run/nginx.pid;
events { worker_connections  1024; }
http {
    include       /etc/nginx/conf/mime.types;
    default_type  application/octet-stream;
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                  '\$status \$body_bytes_sent "\$http_referer" '
                  '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log /etc/nginx/access.log main;
    sendfile        on;
    keepalive_timeout  120;
    client_max_body_size 20m;
    include /etc/nginx/conf.d/*.conf;
}
EOF

cat >/etc/nginx/conf.d/openlist.conf <<EOF
server {
    listen 443 ssl;
    ssl_certificate       /etc/nginx/ssl/$WWW_DOMAIN.crt;
    ssl_certificate_key   /etc/nginx/ssl/$WWW_DOMAIN.key;
    ssl_protocols         TLSv1.3;
    server_name $WWW_DOMAIN;

    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$PORT;
        client_max_body_size 20000m;
    }
    ssl_early_data on;
    ssl_stapling on;
    ssl_stapling_verify on;
    proxy_set_header Early-Data \$ssl_early_data;
    add_header Strict-Transport-Security "max-age=31536000";
}

server {
    listen 80;
    server_name $DOMAIN $WWW_DOMAIN;
    return 301 https://$WWW_DOMAIN\$request_uri;
}
EOF

systemctl restart nginx

# 12. 创建磁盘空间检测脚本并定时执行
CHECK_SCRIPT=/app/openlist/check_space.sh
cat >"$CHECK_SCRIPT" <<EOF
#!/bin/bash
# 获取总空间和可用空间
all=$(df -h | grep -w "$ROOT_DEV" | awk '{print \$2}')
free=$(df -h | grep -w "$ROOT_DEV" | awk '{print \$4}')
TXT_PATH=/app/openlist/data/local_disk_space.txt
# 对比并更新显示文件
if [[ "${free}x" != "$(awk '{print \$2}' "\$TXT_PATH")x" ]]; then
  sed -i "1c 本地磁盘可用空间: ${free} / ${all}" "\$TXT_PATH"
fi
EOF
chmod +x "$CHECK_SCRIPT"

echo "本地磁盘可用空间: 0 / 0" > /app/openlist/data/local_disk_space.txt
chown openlist:openlist /app/openlist/data/local_disk_space.txt

# 定时单元
cat >/etc/systemd/system/checkspace.service <<EOF
[Unit]
Description=磁盘空间检测服务
After=network.target

[Service]
Type=oneshot
ExecStart=$CHECK_SCRIPT
EOF

cat >/etc/systemd/system/checkspace.timer <<EOF
[Unit]
Description=每20秒运行一次磁盘检测

[Timer]
OnBootSec=1
OnUnitActiveSec=20
Unit=checkspace.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable checkspace.timer
systemctl start checkspace.timer

# 13. 安装完成后显示登录信息
echo
echo "OpenList 安装完成！"
echo "用户名: admin"
echo "密码: $PASSWORD"
echo "端口: $PORT"
