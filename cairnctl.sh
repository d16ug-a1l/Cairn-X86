#!/usr/bin/env bash
# Cairn 一键管理脚本：启动 / 停止 / 状态 / 日志
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

SERVER_URL="http://127.0.0.1:8000"

die() { echo "[错误] $*" >&2; exit 1; }

check_env() {
    command -v docker >/dev/null || die "未找到 docker 命令"
    docker info >/dev/null 2>&1 || die "无法访问 Docker（权限不足？可尝试: sudo usermod -aG docker \$USER 后重新登录）"
}

check_config() {
    [ -f dispatch.yaml ] || die "缺少 dispatch.yaml（可从 dispatch.example.yaml 复制并填写配置）"
}

cmd_start() {
    check_env
    check_config
    echo "[*] 启动 Cairn（server + dispatcher）..."
    docker compose up -d "$@"
    echo "[*] 等待 server 健康检查..."
    for i in $(seq 1 30); do
        if curl -sf -o /dev/null --max-time 2 "$SERVER_URL/projects"; then
            echo "[✓] 启动完成，Web UI: $SERVER_URL"
            return 0
        fi
        sleep 2
    done
    die "server 在 60 秒内未就绪，请用 '$0 logs' 查看日志"
}

cmd_stop() {
    check_env
    echo "[*] 停止 Cairn..."
    docker compose down
    echo "[✓] 已停止"
}

cmd_status() {
    check_env
    echo "== 容器状态 =="
    docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
    echo
    echo "== server 接口 =="
    if curl -sf -o /dev/null --max-time 3 "$SERVER_URL/projects"; then
        echo "[✓] $SERVER_URL 正常"
    else
        echo "[✗] $SERVER_URL 无响应"
    fi
    echo
    echo "== dispatcher 最近日志 =="
    docker logs cairn-dispatcher --tail 5 2>&1 || echo "(dispatcher 未运行)"
}

cmd_logs() {
    check_env
    # 用法: logs [server|dispatcher] [额外 docker compose logs 参数]
    local svc=""
    case "${1:-}" in
        server)     svc="cairn-server"; shift ;;
        dispatcher) svc="cairn-dispatcher"; shift ;;
    esac
    docker compose logs -f --tail 100 "$@" $svc
}

case "${1:-}" in
    start)  shift; cmd_start "$@" ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    logs)   shift; cmd_logs "$@" ;;
    restart) cmd_stop && cmd_start ;;
    *)
        cat <<EOF
Cairn 项目管理脚本

用法: $0 <命令> [参数]

  start       一键启动（自动等待 server 就绪）
  stop        停止并移除容器
  restart     重启
  status      查看容器状态、server 健康、dispatcher 最近日志
  logs        跟踪全部日志
  logs server       只看 server 日志
  logs dispatcher   只看 dispatcher 日志

示例:
  $0 start
  $0 logs dispatcher
EOF
        ;;
esac
