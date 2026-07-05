#!/bin/bash
# new-api 服务器部署/更新脚本
# 用法: bash deploy.sh [options]
#   -h, --help     显示帮助信息
#   --docker       使用 Docker 部署（默认）
#   --bare         使用裸机部署（直接编译二进制）
#
# 首次部署:
#   bash deploy.sh
# 后续更新:
#   git pull && bash deploy.sh

set -e

APP_NAME="new-api"
INSTALL_DIR="${INSTALL_DIR:-/opt/new-api}"
BRANCH="${BRANCH:-master}"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        OS=$(uname -s)
    fi
    echo "$OS"
}

# 检测命令是否存在
check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        error "$1 未安装，请先安装: $2"
    fi
}

# Docker 部署
deploy_docker() {
    info "使用 Docker 部署..."

    # 检查必要的命令
    check_cmd docker "curl -fsSL https://get.docker.com | bash"
    check_cmd docker-compose "apt install docker-compose || pip install docker-compose"

    # 检查数据目录
    mkdir -p ./data ./logs

    # 检查 .env 文件
    if [ ! -f .env ]; then
        warn ".env 文件不存在，创建默认配置..."
        cat > .env << 'ENVEOF'
DEBUG=false
GENERATE_DEFAULT_TOKEN=true
ENVEOF
        info "请编辑 .env 文件配置您的数据库和 Redis 连接"
        info "然后重新运行: bash deploy.sh"
        exit 0
    fi

    # 拉取最新镜像并重启
    docker-compose down
    docker-compose pull
    docker-compose up -d

    info "Docker 部署完成！"
    info "访问: http://$(curl -s ifconfig.me):3000"
}

# 裸机部署
deploy_bare() {
    info "使用裸机部署..."

    OS=$(detect_os)
    info "检测到系统: $OS"

    # 检查依赖
    check_cmd go "https://go.dev/dl/"
    check_cmd node "https://nodejs.org/"
    check_cmd npm "https://nodejs.org/"

    # 检查 npm 是否可用（部分系统用 nodejs 包名）
    if ! command -v npm &>/dev/null; then
        error "npm 未安装"
    fi

    # 构建前端
    info "构建前端..."
    cd web
    if [ ! -d node_modules ]; then
        npm install
    fi
    VITE_REACT_APP_VERSION=$(cat ../VERSION) npm run build
    cd ..

    # 构建后端
    info "构建后端..."
    go build -ldflags "-s -w -X 'github.com/QuantumNous/new-api/common.Version=$(cat VERSION)'" -o "$APP_NAME"

    # 安装到目标目录
    if [ "$INSTALL_DIR" != "$(pwd)" ]; then
        info "安装到 $INSTALL_DIR ..."
        mkdir -p "$INSTALL_DIR"
        cp "$APP_NAME" "$INSTALL_DIR/"
        cp -r web/dist "$INSTALL_DIR/web/" 2>/dev/null || true
        cp .env "$INSTALL_DIR/" 2>/dev/null || true
    fi

    # 重启服务
    if command -v systemctl &>/dev/null && systemctl is-enabled "$APP_NAME" &>/dev/null 2>&1; then
        info "重启 systemd 服务..."
        sudo systemctl restart "$APP_NAME"
    else
        info "停止旧进程..."
        pkill "$APP_NAME" 2>/dev/null || true
        sleep 1
        info "启动新进程..."
        if [ "$INSTALL_DIR" != "$(pwd)" ]; then
            cd "$INSTALL_DIR"
        fi
        nohup "./$APP_NAME" > "${APP_NAME}.log" 2>&1 &
        info "PID: $!"
    fi

    info "裸机部署完成！"
}

# 首次部署引导
first_deploy_guide() {
    echo ""
    echo "============================================"
    echo "  new-api 部署指南"
    echo "============================================"
    echo ""
    echo "方式一: Docker 部署（推荐）"
    echo "  1. 服务器安装 Docker"
    echo "  2. 编辑 .env 文件配置数据库"
    echo "  3. 运行: bash deploy.sh --docker"
    echo ""
    echo "方式二: 裸机部署"
    echo "  1. 安装 Go 1.22+, Node.js"
    echo "  2. 编辑 .env 文件"
    echo "  3. 运行: bash deploy.sh --bare"
    echo "  4. 配置 systemd 服务实现自启动"
    echo ""
    echo "============================================"
}

# 更新流程
update_app() {
    info "开始更新..."

    # 保存当前版本
    if [ -f VERSION ]; then
        OLD_VERSION=$(cat VERSION)
        info "当前版本: $OLD_VERSION"
    fi

    # 拉取最新代码
    if [ -d .git ]; then
        info "拉取最新代码 (分支: $BRANCH)..."
        git fetch origin "$BRANCH"
        git checkout "$BRANCH"
        git pull origin "$BRANCH"
    fi

    # 根据部署方式重建
    if [ -f docker-compose.yml ] && command -v docker &>/dev/null; then
        deploy_docker
    else
        deploy_bare
    fi

    # 显示新版本
    if [ -f VERSION ]; then
        NEW_VERSION=$(cat VERSION)
        info "更新完成: $OLD_VERSION → $NEW_VERSION"
    else
        info "更新完成！"
    fi
}

# main
case "${1:-}" in
    -h|--help)    first_deploy_guide ;;
    --docker)     deploy_docker ;;
    --bare)       deploy_bare ;;
    update)       update_app ;;
    *)
        if [ -f .git ] || [ -d .git ]; then
            # 已有 git 仓库 → 更新模式
            if [ -f "$APP_NAME" ] || [ -f docker-compose.yml ]; then
                update_app
            else
                first_deploy_guide
            fi
        else
            first_deploy_guide
        fi
        ;;
esac
