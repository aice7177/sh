#!/bin/bash

#================================================================================
# OpenList 一键安装与配置脚本 (适用于 Debian/Ubuntu)
#
# 功能:
#   - 自动安装 OpenList 及其依赖
#   - 自动处理 Nginx 安装与反向代理配置
#   - 自动申请 Let's Encrypt SSL 证书 (acme.sh)
#   - 自动配置 systemd 守护进程与开机自启
#   - 自动生成并配置磁盘容量显示功能
#   - 使用随机端口，并最终显示所有配置信息
#
#================================================================================

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

# 错误退出
set -e

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：此脚本必须以 root 用户身份运行。${NC}"
    exit 1
fi

# 欢迎信息
echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}        OpenList 一键安装与配置脚本              ${NC}"
echo -e "${BLUE}=====================================================${NC}"

# 1. 域名输入与验证
#----------------------------------------------------
install_deps_for_domain_check() {
    echo -e "${GREEN}正在安装域名检查所需依赖 (curl)...${NC}"
    if ! command -v curl &> /dev/null; then
        apt-get update && apt-get install -y curl
    fi
}

ask_for_domain() {
    install_deps_for_domain_check
    while true; do
        read -p "请输入您的域名 (例如: mydomain.com 或 openlist.mydomain.com): " USER_DOMAIN
        if [[ -z "$USER_DOMAIN" ]]; then
            echo -e "${RED}域名不能为空，请重新输入。${NC}"
            continue
        fi

        # 简单的域名格式验证
        if ! [[ "$USER_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${RED}域名格式不正确，请重新输入。${NC}"
            continue
        fi

        # 检查域名解析
        echo -e "${YELLOW}正在验证域名解析，请确保您的域名已正确解析到本服务器IP...${NC}"
        DOMAIN_IP=$(curl -s "https://dns.google/resolve?name=$USER_DOMAIN&type=A" | grep -oP '"data": "\K[^"]+' | head -n 1)
        SERVER_IP=$(curl -s ifconfig.me)

        if [ "$DOMAIN_IP" == "$SERVER_IP" ]; then
            echo -e "${GREEN}域名解析验证成功！ ($USER_DOMAIN -> $SERVER_IP)${NC}"
            break
        else
            echo -e "${RED}错误：域名 ($USER_DOMAIN) 未解析到当前服务器IP ($SERVER_IP)。${NC}"
            echo -e "${RED}解析到的IP为：$DOMAIN_IP ${NC}"
            read -p "是否继续安装？(y/n): " choice
            if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
                break
            fi
        fi
    done
}


# 2. 安装依赖
#----------------------------------------------------
install_dependencies() {
    echo -e "${GREEN}正在更新软件包列表并安装所需依赖...${NC}"
    apt-get update
    apt-get install -y wget tar socat cron jq
}

# 3. 安装 OpenList
#----------------------------------------------------
install_openlist() {
    echo -e "${GREEN}开始安装 OpenList...${NC}"
    
    # 下载和解压
    wget https://github.com/OpenListTeam/OpenList/releases/latest/download/openlist-linux-amd64.tar.gz -O openlist-linux-amd64.tar.gz
    tar -zxvf openlist-linux-amd64.tar.gz
    
    # 创建目录和设置权限
    mkdir -p /app/openlist
    mv openlist /app/openlist
    chmod +x /app/openlist/openlist
    
    # 创建 OpenList 用户和组
    echo -e "${GREEN}正在创建用于运行 OpenList 的系统用户...${NC}"
    groupadd --system openlist || true
    useradd --system --gid openlist --create-home --shell /usr/sbin/nologin --comment "openlist" openlist || true

    # 切换到工作目录
    cd /app/openlist

    # 首次运行以生成配置文件并捕获密码
    echo -e "${YELLOW}首次启动 OpenList 以获取初始密码...${NC}"
    ./openlist server > openlist_initial_run.log 2>&1 &
    SERVER_PID=$!
    
    # 等待几秒钟让程序初始化
    sleep 5
    
    INITIAL_PASSWORD=$(grep 'initial password is:' openlist_initial_run.log | awk -F': ' '{print $2}')
    kill $SERVER_PID
    
    if [ -z "$INITIAL_PASSWORD" ]; then
        echo -e "${RED}错误：无法获取 OpenList 初始密码。请检查日志 /app/openlist/openlist_initial_run.log ${NC}"
        exit 1
    fi
    echo -e "${GREEN}成功获取初始密码！${NC}"

    # 生成随机端口
    LISTEN_PORT=$((RANDOM % 40000 + 10000))
    echo -e "${GREEN}为 OpenList 生成随机端口: $LISTEN_PORT ${NC}"
    
    # 使用 jq 修改配置文件中的端口
    jq --argjson port "$LISTEN_PORT" '.port = $port' data/config.json > data/config.tmp && mv data/config.tmp data/config.json
    
    # 设置守护进程
    echo -e "${GREEN}正在创建 systemd 服务...${NC}"
    cat > /etc/systemd/system/openlist.service <<EOF
[Unit]
Description=openlist
After=network.target

[Service]
User=openlist
Group=openlist
Type=simple
WorkingDirectory=/app/openlist
ExecStart=/app/openlist/openlist server
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    # 设置本地存储目录
    mkdir -p /html/网盘
    chown -R openlist:openlist /html/网盘
    chown -R openlist:openlist /app/openlist

    # 启动服务
    systemctl daemon-reload
    systemctl enable openlist
    systemctl start openlist
    echo -e "${GREEN}OpenList 服务已启动。${NC}"
}

# 4. 配置 Nginx 反向代理
#----------------------------------------------------
setup_nginx_reverse_proxy() {
    echo -e "${GREEN}开始配置 Nginx 反向代理...${NC}"

    # 检查并安装 Nginx
    if ! command -v nginx &> /dev/null; then
        echo -e "${YELLOW}未检测到 Nginx，正在安装...${NC}"
        apt-get install -y nginx
    else
        echo -e "${GREEN}Nginx 已安装。${NC}"
    fi

    # 停止 Nginx 以便 acme.sh 使用80端口
    systemctl stop nginx

    # 安装并配置 acme.sh
    echo -e "${GREEN}正在安装 acme.sh 并申请 SSL 证书...${NC}"
    curl https://get.acme.sh | sh
    source ~/.bashrc
    
    # 处理域名
    ACME_DOMAINS="-d $USER_DOMAIN"
    NGINX_SERVER_NAME="$USER_DOMAIN"
    count=$(echo "$USER_DOMAIN" | tr -cd '.' | wc -c)
    
    if [[ "$USER_DOMAIN" == www.* ]]; then
        MAIN_DOMAIN="${USER_DOMAIN#www.}"
        ACME_DOMAINS="-d $USER_DOMAIN -d $MAIN_DOMAIN"
        NGINX_SERVER_NAME="$MAIN_DOMAIN $USER_DOMAIN"
        PRIMARY_DOMAIN="$USER_DOMAIN"
    elif [ "$count" -eq 1 ]; then # 例如 mydomain.com
        MAIN_DOMAIN="$USER_DOMAIN"
        WWW_DOMAIN="www.$USER_DOMAIN"
        ACME_DOMAINS="-d $MAIN_DOMAIN -d $WWW_DOMAIN"
        NGINX_SERVER_NAME="$MAIN_DOMAIN $WWW_DOMAIN"
        PRIMARY_DOMAIN="www.$MAIN_DOMAIN" # 默认重定向到 www
    else # 例如 sub.mydomain.com
        PRIMARY_DOMAIN="$USER_DOMAIN"
    fi

    # 申请证书
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue --standalone $ACME_DOMAINS -k ec-256 --force

    # 安装证书
    SSL_CERT_PATH="/etc/nginx/ssl/${PRIMARY_DOMAIN}.crt"
    SSL_KEY_PATH="/etc/nginx/ssl/${PRIMARY_DOMAIN}.key"
    mkdir -p /etc/nginx/ssl
    ~/.acme.sh/acme.sh --installcert $ACME_DOMAINS --fullchain-file $SSL_CERT_PATH --key-file $SSL_KEY_PATH --ecc --force
    
    # 配置 Nginx
    echo -e "${GREEN}正在生成 Nginx 配置文件...${NC}"
    cat > /etc/nginx/conf.d/openlist.conf <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${NGINX_SERVER_NAME};

    ssl_certificate       ${SSL_CERT_PATH};
    ssl_certificate_key   ${SSL_KEY_PATH};
    ssl_protocols         TLSv1.3 TLSv1.2;
    ssl_ciphers           TLS13-AES-256-GCM-SHA384:TLS13-CHACHA20-POLY1305-SHA256:EECDH+AESGCM:EDH+AESGCM;

    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${LISTEN_PORT};
        client_max_body_size 0; # 无限制上传大小
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name ${NGINX_SERVER_NAME};
    return 301 https://${PRIMARY_DOMAIN}\$request_uri;
}
EOF
    
    # 检查 Nginx 配置并重启
    nginx -t
    systemctl restart nginx
    echo -e "${GREEN}Nginx 配置完成并已重启。${NC}"
}


# 5. 配置美化及磁盘容量显示
#----------------------------------------------------
setup_beautification() {
    echo -e "${GREEN}开始配置磁盘容量显示功能...${NC}"
    
    # 自动检测根目录所在分区
    DISK_PARTITION=$(df -P / | awk 'NR==2 {print $1}')
    echo -e "${YELLOW}自动检测到系统根分区为: $DISK_PARTITION ${NC}"
    
    # 创建显示磁盘空间的脚本
    cat > /app/openlist/check_disk_space.sh <<EOF
#!/bin/bash
all=\$(df -h | grep -w ${DISK_PARTITION} | awk '{ print \$2 }')
free=\$(df -h | grep -w ${DISK_PARTITION} | awk '{ print \$4 }')
TXT_FILE="/html/网盘/本地磁盘空间.txt"

# 首次运行时创建文件
if [ ! -f "\$TXT_FILE" ]; then
    touch "\$TXT_FILE"
    chown openlist:openlist "\$TXT_FILE"
fi

# 写入或更新内容
echo "本地磁盘可用空间: \${free} / \${all}" > "\$TXT_FILE"

EOF

    chmod +x /app/openlist/check_disk_space.sh

    # 创建 systemd service
    cat > /etc/systemd/system/checkspace.service <<EOF
[Unit]
Description=Update Disk Space Info for OpenList
After=network.target

[Service]
Type=simple
ExecStart=/app/openlist/check_disk_space.sh
EOF

    # 创建 systemd timer 定时器
    cat > /etc/systemd/system/checkspace.timer <<EOF
[Unit]
Description=Run checkspace service every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Unit=checkspace.service

[Install]
WantedBy=timers.target
EOF

    # 启动定时器
    systemctl daemon-reload
    systemctl enable checkspace.timer
    systemctl start checkspace.timer
    # 立即执行一次以生成文件
    /app/openlist/check_disk_space.sh

    echo -e "${GREEN}磁盘容量监控定时器已设置。${NC}"
    echo -e "${YELLOW}请注意：您需要在OpenList的“设置”->“存储”中添加一个“本地存储”，将“根文件夹路径”填写为 /html/网盘。${NC}"
    echo -e "${YELLOW}然后，在“设置”->“全局”->“自定义内容”中粘贴以下代码以显示磁盘容量。${NC}"
    
    CUSTOM_HTML_SNIPPET=$(cat <<EOF
<div id="customize" style="display: none;">
    <div id="disk-info" style="text-align: center; margin: 10px 0; color: #666;"></div>
    <style>
        .footer span, .footer a:nth-of-type(1), .footer a:nth-of-type(2) {
            display: none;
        }
        .hope-stack.hope-c-dhzjXW.hope-c-PJLV.hope-c-PJLV-ihYBJPK-css {
            display: none !important;
        }
    </style>
    <div style="text-align: center;">
        <p>
            <a target="_blank" href="https://openlist.nn.ci/zh/">© Powered by OpenList</a>
            <span>|</span>
            <a target="_blank" href="/@manage">管理</a>
        </p>
    </div>
</div>

<script>
    let interval = setInterval(() => {
        if (document.querySelector(".footer")) {
            document.querySelector("#customize").style.display = "";
            fetch('/d/本地磁盘空间.txt?v=' + new Date().getTime()) // 添加时间戳防止缓存
                .then(response => response.text())
                .then(text => {
                    document.getElementById("disk-info").innerHTML = text;
                });
            clearInterval(interval);
        }
    }, 200);
</script>
EOF
)
}

# 脚本主流程
#----------------------------------------------------
main() {
    ask_for_domain
    install_dependencies
    install_openlist
    setup_nginx_reverse_proxy
    setup_beautification
    
    # 显示最终信息
    echo -e "${BLUE}=====================================================${NC}"
    echo -e "${GREEN}           🎉 OpenList 安装配置完成！ 🎉          ${NC}"
    echo -e "${BLUE}=====================================================${NC}"
    echo -e "访问地址:   ${YELLOW}https://${PRIMARY_DOMAIN}${NC}"
    echo -e "内部端口:   ${YELLOW}${LISTEN_PORT}${NC}"
    echo -e "用 户 名:   ${YELLOW}admin${NC}"
    echo -e "初始密码:   ${RED}${INITIAL_PASSWORD}${NC}"
    echo -e "${BLUE}-----------------------------------------------------${NC}"
    echo -e "${YELLOW}重要操作提示:${NC}"
    echo -e "1. 登录后请立即修改您的密码。"
    echo -e "2. 请到OpenList [设置]>[存储]>[添加]，类型选择[本地存储]，[根文件夹路径]填写: ${GREEN}/html/网盘${NC}"
    echo -e "3. 复制以下代码到OpenList [设置]>[全局]>[自定义内容] 中，以实现磁盘容量显示和页脚美化:"
    echo -e "${BLUE}--------------------- 复制以下代码 --------------------${NC}"
    echo -e "${CUSTOM_HTML_SNIPPET}"
    echo -e "${BLUE}-----------------------------------------------------${NC}"
    echo -e "管理命令:"
    echo -e "  - 启动 OpenList: ${GREEN}systemctl start openlist${NC}"
    echo -e "  - 停止 OpenList: ${GREEN}systemctl stop openlist${NC}"
    echo -e "  - 查看状态:      ${GREEN}systemctl status openlist${NC}"
    echo -e "  - 重启 Nginx:    ${GREEN}systemctl restart nginx${NC}"
    echo -e "${BLUE}=====================================================${NC}"

}

# 执行主函数
main
