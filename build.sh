#!/usr/bin/env bash
# Cairn 一键构建脚本：构建全部镜像（cairn-app + worker 容器）
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

WORKER_IMAGE="cairn-worker-container:cn"

die() { echo "[错误] $*" >&2; exit 1; }

check_env() {
    command -v docker >/dev/null || die "未找到 docker 命令"
    docker info >/dev/null 2>&1 || die "无法访问 Docker（权限不足？可尝试: sudo usermod -aG docker \$USER 后重新登录）"
}

build_app() {
    echo "[*] 构建 cairn-app（server + dispatcher）..."
    docker compose build
    echo "[✓] cairn-app 构建完成"
}

build_worker() {
    if docker image inspect "$WORKER_IMAGE" >/dev/null 2>&1 && [ "$FORCE" != "1" ]; then
        echo "[=] $WORKER_IMAGE 已存在，跳过（加 --force 强制重建）"
        return 0
    fi
    echo "[*] 构建 worker 镜像 $WORKER_IMAGE（Kali 工具集，耗时较长，请耐心等待）..."
    docker build $BUILD_FLAGS -t "$WORKER_IMAGE" ./container
    echo "[✓] worker 镜像构建完成"
}

FORCE=""
BUILD_FLAGS=""
TARGET="all"
while [ $# -gt 0 ]; do
    case "$1" in
        --force|-f)  FORCE="1" ;;
        --no-cache)  BUILD_FLAGS="$BUILD_FLAGS --no-cache"; FORCE="1" ;;
        app)         TARGET="app" ;;
        worker)      TARGET="worker" ;;
        *)           die "未知参数: $1（用法: $0 [app|worker] [--force] [--no-cache]）" ;;
    esac
    shift
done

check_env

case "$TARGET" in
    app)    build_app ;;
    worker) build_worker ;;
    all)    build_worker; build_app ;;
esac

echo
echo "== 当前镜像 =="
docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" | head -5

if [ "$TARGET" != "app" ] && docker image inspect "$WORKER_IMAGE" >/dev/null 2>&1; then
    if [ -f dispatch.yaml ] && ! grep -q "image: \"$WORKER_IMAGE\"" dispatch.yaml; then
        echo
        echo "[提示] dispatch.yaml 的 container.image 未指向 $WORKER_IMAGE"
        echo "       如需使用本地镜像，请修改为:  image: \"$WORKER_IMAGE\""
    fi
fi

echo
echo "[✓] 构建流程完成，可执行 ./cairnctl.sh start 启动项目"
