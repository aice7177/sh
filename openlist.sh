#!/bin/bash

#================================================================================
# OpenList 全自动安装与配置脚本 for Debian/Ubuntu
#
# 功能:
#   - 自动安装 OpenList
#   - 自动配置 Systemd 守护进程
#   - 自动安装/配置 Nginx 反向代理
#   - 自动申请 Let's Encrypt SSL 证书 (by acme.sh)
#   - 自动实现磁盘容量显示和界面美化
#
#================================================================================

# 字体颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
   echo -e "${RED}错误: 此脚本必须以 root 用户权限运行。${PLAIN}" 1>&2
   exit 1
fi

# 检查系统是否使用 Systemd
if ! command -v systemctl &> /dev/null; then
    echo -e "${RED}错误: 看不见 'systemctl' 命令, 本脚本只支持使用 Systemd 的系统。${PLAIN}"
    exit 1
fi

# 变量初始化
DOMAIN=""
STORAGE_PATH=""
OPENLIST_PORT=""
ADMIN_PASSWORD=""
NGINX_INSTALLED=false

# 捕获中断信号
trap 'echo -e "\n${RED}安装被用户中断。${PLAIN}"; exit 1' INT

# 函数：获取用户输入
get_user_input() {
    # 循环直到获得有效的域名
    while true; do
        read -p "请输入您的域名 (例如 www.example.com): " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            echo -e "${RED}域名不能为空，请重新输入!${PLAIN}"
        elif ! echo "$DOMAIN" | grep -Pq '(?=^.{4,253}$)(^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$)'; then
            echo -e "${RED}域名格式不正确，请重新输入!${PLAIN}"
        else
            # 检查域名解析
            echo -e "${YELLOW}正在验证域名解析...${PLAIN}"
            local domain_ip
            domain_ip=$(ping -c 1 "$DOMAIN" | sed '1{s/[^(]*(//;s/).*//;q;}')
            local local_ip
            local_ip=$(curl -s ip.sb)
            if [ "$domain_ip" == "$local_ip" ]; then
                echo -e "${GREEN}域名解析正确，IP 为: ${domain_ip}${PLAIN}"
                break
            else
                echo -e "${RED}错误: 域名 ${DOMAIN} 未解析到本机公网 IP (${local_ip})。${PLAIN}"
                echo -e "${RED}检测到的域名 IP 为: ${domain_ip}。请先设置好 DNS 解析再运行脚本。${PLAIN}"
                exit 1
            fi
        fi
    done

    # 循环直到获得有效的存储路径
    while true; do
        read -p "请输入 OpenList 的本地存储路径 (例如 /data/openlist_files, 默认为 /app/openlist/data/local): " STORAGE_PATH
        STORAGE_PATH=${STORAGE_PATH:-/app/openlist/data/local} # 设置默认值
        
        # 检查路径是否为绝对路径
        if [[ ! "$STORAGE_PATH" =~ ^/ ]]; then
            echo -e "${RED}路径必须为绝对路径 (以 / 开头)，请重新输入!${PLAIN}"
        else
            break
        fi
    done
}

# 函数：安装依赖
install_dependencies() {
    echo -e "${GREEN}正在更新软件包列表并安装依赖...${PLAIN}"
    apt-get update > /dev/null 2>&1
    if ! apt-get install -y wget tar curl socat cron &> /dev/null; then
        echo -e "${RED}依赖安装失败，请检查您的软件源。${PLAIN}"
        exit 1
    fi

    # 检查 Nginx
    if command -v nginx &> /dev/null; then
        NGINX_INSTALLED=true
        echo -e "${YELLOW}检测到 Nginx 已安装。${PLAIN}"
    else
        echo -e "${GREEN}正在安装 Nginx...${PLAIN}"
        if ! apt-get install -y nginx &> /dev/null; then
            echo -e "${RED}Nginx 安装失败。${PLAIN}"
            exit 1
        fi
        systemctl enable nginx > /dev/null 2>&1
    fi
}

# 函数：安装 OpenList
install_openlist() {
    echo -e "${GREEN}正在安装 OpenList...${PLAIN}"
    
    # 1. 下载并解压
    mkdir -p /app/openlist
    cd /app
    if ! wget -O openlist-linux-amd64.tar.gz https://github.com/OpenListTeam/OpenList/releases/latest/download/openlist-linux-amd64.tar.gz; then
        echo -e "${RED}OpenList 下载失败，请检查网络或 GitHub Release 页面。${PLAIN}"
        exit 1
    fi
    tar -zxvf openlist-linux-amd64.tar.gz -C /app/openlist > /dev/null 2>&1
    rm -f openlist-linux-amd64.tar.gz
    chmod +x /app/openlist/openlist

    # 2. 首次运行以生成配置和密码
    echo -e "${GREEN}正在初始化 OpenList 并获取管理员密码...${PLAIN}"
    cd /app/openlist
    # 使用 expect 自动化首次运行，捕获密码
    ADMIN_PASSWORD=$(./openlist admin | grep 'password:' | awk '{print $NF}')
    
    if [ -z "$ADMIN_PASSWORD" ]; then
        echo -e "${RED}获取初始管理员密码失败，正在尝试重置...${PLAIN}"
        ADMIN_PASSWORD=$(./openlist admin random | grep 'New password' | awk '{print $NF}')
        if [ -z "$ADMIN_PASSWORD" ]; then
            echo -e "${RED}重置密码也失败了，请检查程序。${PLAIN}"
            exit 1
        fi
    fi

    # 启动一次服务器以生成 config.json
    ./openlist server &
    local openlist_pid=$!
    sleep 5 # 等待 config.json 生成
    kill $openlist_pid
    wait $openlist_pid 2>/dev/null


    # 3. 修改端口为随机高位端口
    OPENLIST_PORT=$(shuf -i 49152-65535 -n 1)
    sed -i 's/"http_port": 5244/"http_port": '"$OPENLIST_PORT"'/' /app/openlist/data/config.json
    
    # 4. 设置根文件夹路径
    # 将 JSON 路径中的反斜杠转义
    local escaped_storage_path
    escaped_storage_path=$(echo "$STORAGE_PATH" | sed 's/\//\\\//g')
    sed -i 's/"root_folder_path": "\/"/"root_folder_path": "'"$escaped_storage_path"'"/' /app/openlist/data/config.json
    # 关闭允许挂载
    sed -i 's/"allow_mounted": true/"allow_mounted": false/' /app/openlist/data/config.json


    # 5. 创建守护进程
    echo -e "${GREEN}正在创建 OpenList 的 Systemd 服务...${PLAIN}"
    groupadd --system openlist > /dev/null 2>&1
    useradd --system --gid openlist --no-create-home --shell /usr/sbin/nologin --comment "openlist" openlist > /dev/null 2>&1
    
    cat > /etc/systemd/system/openlist.service <<EOF
[Unit]
Description=OpenList Service
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

    # 6. 设置权限并启动
    mkdir -p "$STORAGE_PATH"
    chown -R openlist:openlist /app/openlist
    chown -R openlist:openlist "$STORAGE_PATH"

    systemctl daemon-reload
    systemctl enable openlist > /dev/null 2>&1
    systemctl start openlist
}

# 函数：配置 Nginx 和 SSL
configure_nginx_ssl() {
    echo -e "${GREEN}正在配置 Nginx 和申请 SSL 证书...${PLAIN}"
    
    # 1. 申请证书
    systemctl stop nginx
    
    # 安装 acme.sh
    if [ ! -d ~/.acme.sh ]; then
        curl https://get.acme.sh | sh
    fi
    source ~/.bashrc
    
    echo -e "${YELLOW}正在使用 acme.sh 申请证书，请稍候...${PLAIN}"
    
    local root_domain
    local www_domain_arg=""
    # 处理域名
    if [[ $DOMAIN == www.* ]]; then
        root_domain=${DOMAIN#www.}
        www_domain_arg="-d $root_domain"
    else
        root_domain=$DOMAIN
    fi

    if ! ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt; then
        echo -e "${RED}设置默认 CA 失败。${PLAIN}"
        systemctl start nginx
        exit 1
    fi

    if ! ~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" $www_domain_arg -k ec-256; then
        echo -e "${RED}SSL 证书申请失败。请检查域名解析和端口 80 是否被占用。${PLAIN}"
        systemctl start nginx
        exit 1
    fi
    
    mkdir -p /etc/nginx/ssl/
    if ! ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" --fullchain-file "/etc/nginx/ssl/$DOMAIN.crt" --key-file "/etc/nginx/ssl/$DOMAIN.key" --ecc; then
        echo -e "${RED}证书安装失败。${PLAIN}"
        systemctl start nginx
        exit 1
    fi
    
    # 2. 配置 Nginx
    if [ "$NGINX_INSTALLED" = false ]; then
        # 如果是新安装的Nginx，写入一个基础的 nginx.conf
        cat > /etc/nginx/nginx.conf <<EOF
user root;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    keepalive_timeout 120;
    client_max_body_size 20000m;
    include /etc/nginx/conf.d/*.conf;
}
EOF
    fi

    # 创建 OpenList 的 Nginx 配置文件
    cat > /etc/nginx/conf.d/openlist.conf <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/ssl/$DOMAIN.crt;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers TLS13-AES-256-GCM-SHA384:TLS13-CHACHA20-POLY1305-SHA256:EECDH+AESGCM:EDH+AESGCM;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$OPENLIST_PORT;
        client_max_body_size 20000m;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}
EOF

    # 如果是 www 域名，添加从根域名到 www 的重定向
    if [[ $DOMAIN == www.* ]]; then
    cat >> /etc/nginx/conf.d/openlist.conf <<EOF

server {
    listen 80;
    listen [::]:80;
    server_name $root_domain;
    return 301 https://$DOMAIN\$request_uri;
}
EOF
    fi

    # 3. 重启 Nginx
    systemctl restart nginx
    echo -e "${GREEN}Nginx 配置完成。${PLAIN}"
}

# 函数：设置美化和磁盘显示
setup_beautification() {
    echo -e "${GREEN}正在配置美化与磁盘容量显示功能...${PLAIN}"
    
    # 1. 自动检测磁盘分区
    local disk_partition
    disk_partition=$(df "$STORAGE_PATH" | awk 'NR==2 {print $1}')
    if [ -z "$disk_partition" ]; then
        echo -e "${YELLOW}警告: 无法自动检测存储路径 '${STORAGE_PATH}' 所在的分区。磁盘容量脚本可能不工作。${PLAIN}"
        # 使用一个通用但可能不准确的回退值
        disk_partition="/dev/vda1"
    else
        echo -e "${GREEN}成功检测到存储分区为: ${disk_partition}${PLAIN}"
    fi

    local txt_file_path="$STORAGE_PATH/本地磁盘空间.txt"

    # 2. 创建用于显示磁盘容量的脚本
    cat > /app/openlist/check_space.sh <<EOF
#!/bin/bash
all=\$(df -h | grep -w ${disk_partition} | awk '{ print \$2 }')
free=\$(df -h | grep -w ${disk_partition} | awk '{ print \$4 }')
if [ "\${free}x" != \$(awk '{print \$4}' "${txt_file_path}")x ]; then
    echo "本地磁盘可用空间: \${free} / \${all}" > "${txt_file_path}"
fi
EOF
    chmod +x /app/openlist/check_space.sh
    # 立即执行一次以创建文件
    /app/openlist/check_space.sh
    chown openlist:openlist "$txt_file_path"

    # 3. 创建 Systemd 定时器来定期更新磁盘信息
    cat > /etc/systemd/system/checkspace.service <<EOF
[Unit]
Description=Check Disk Space for OpenList

[Service]
Type=simple
ExecStart=/app/openlist/check_space.sh
EOF

    cat > /etc/systemd/system/checkspace.timer <<EOF
[Unit]
Description=Run check_space.sh every 30 seconds

[Timer]
OnBootSec=30
OnUnitActiveSec=30
Unit=checkspace.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable checkspace.timer > /dev/null 2>&1
    systemctl start checkspace.timer

    # 4. 生成自定义HTML并注入到OpenList配置中
    # 注意：这里的 /dav/ 是 OpenList 默认本地存储的WebDAV路径前缀
    local txt_file_url="https://$DOMAIN/dav/本地磁盘空间.txt"
    
    # 创建包含JSON转义字符的HTML代码
    local custom_html
    custom_html=$(cat <<EOF
<!DOCTYPE html><html><head><meta charset="utf-8" /><meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate" /><meta http-equiv="Pragma" content="no-cache" /><meta http-equiv="Expires" content="0" /><div id="customize" style="display: none;"><div id="content" style="text-align: center ; font-weight: bold; margin-top: 10px;"></div><style>.footer span,.footer a:nth-of-type(1){display:none;}.footer span,.footer a:nth-of-type(2){display:none;}.hope-stack.hope-c-dhzjXW.hope-c-PJLV.hope-c-PJLV-ihYBJPK-css {display: none !important;}</style><div style="text-align: center ; "><p align="center"><a target="_blank" href="https://openlist.nn.ci/zh/" > © Powered by OpenList</a><span> | </span><a target="_blank" href="/@manage" >管理</a></p></div></div><script>let interval = setInterval(() => {if (document.querySelector(".footer")) {document.querySelector("#customize").style.display = "";clearInterval(interval);}}, 200);<\/script><script>var xhttp = new XMLHttpRequest();xhttp.open("GET", "${txt_file_url}", true);xhttp.onreadystatechange = function() {if (this.readyState == 4 && this.status == 200) {var text = this.responseText;document.getElementById("content").innerHTML = text;}};xhttp.send();<\/script></head></html>
EOF
)
    # 停止 OpenList 以安全地修改配置
    systemctl stop openlist

    # 读取旧配置，删除结尾的 `}`，添加新内容，再加回 `}`
    # 这是一个比较稳定的方法，可以避免破坏JSON结构
    head -n -1 /app/openlist/data/config.json > /tmp/config.tmp
    echo "," >> /tmp/config.tmp
    echo '  "custom_body": "'"$custom_html"'"' >> /tmp/config.tmp
    echo "}" >> /tmp/config.tmp
    mv /tmp/config.tmp /app/openlist/data/config.json
    
    chown openlist:openlist /app/openlist/data/config.json
    systemctl start openlist
    
    echo -e "${GREEN}美化设置已应用。${PLAIN}"
}

# --- 主程序 ---
main() {
    clear
    echo -e "=============================================================="
    echo -e "         OpenList 全自动安装与配置脚本"
    echo -e "=============================================================="

    get_user_input
    install_dependencies
    install_openlist
    configure_nginx_ssl
    setup_beautification

    # 清理
    rm -f /app/check_space.sh

    # 显示最终信息
    echo -e "=============================================================="
    echo -e "${GREEN}祝贺您！OpenList 已成功安装并配置完毕！${PLAIN}"
    echo -e "--------------------------------------------------------------"
    echo -e "访问地址:   ${YELLOW}https://$DOMAIN${PLAIN}"
    echo -e "内部端口:   ${YELLOW}$OPENLIST_PORT${PLAIN}"
    echo -e "用 户 名:   ${YELLOW}admin${PLAIN}"
    echo -e "初始密码:   ${RED}$ADMIN_PASSWORD${PLAIN}"
    echo -e "--------------------------------------------------------------"
    echo -e "${YELLOW}请立即登录并修改您的初始密码。${PLAIN}"
    echo -e "${YELLOW}磁盘容量信息可能需要一分钟左右才会首次显示。${PLAIN}"
    echo -e "=============================================================="
}

main
