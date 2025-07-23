#!/bin/bash

#================================================================================
# OpenList 全自动安装与配置脚本 (v1.1 - 修正版)
#
# 更新日志:
#   v1.1: 修正了在验证域名前未安装 curl 的逻辑错误。
#================================================================================

# 字体颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# ... (其他函数定义与之前相同，这里为简洁省略) ...
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
            local_ip=$(curl -s ip.sb || curl -s ifconfig.me) # 增加备用IP查询服务
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
    if ! apt-get update > /dev/null 2>&1; then
        echo -e "${RED}软件包列表更新失败，请检查软件源。${PLAIN}"
        exit 1
    fi

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
# ... (其他函数 install_openlist, configure_nginx_ssl, setup_beautification 与之前版本相同) ...
# 为了简洁，此处省略了未改动的函数，实际使用时请包含完整脚本。

# --- 主程序 ---
main() {
    clear
    echo -e "=============================================================="
    echo -e "         OpenList 全自动安装与配置脚本 (v1.1)"
    echo -e "=============================================================="

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

    # **修正点**: 将依赖安装提前到所有操作之前
    install_dependencies

    get_user_input
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

# 脚本入口
main
