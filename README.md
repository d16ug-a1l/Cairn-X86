<div align="center">

<img src="./README/banner.png" alt="Cairn Banner"/>

# Cairn（国内镜像版）
### More Than Just AI Penetration Testing — Towards General State-Space Search

基于 [oritera/Cairn](https://github.com/oritera/Cairn) 的衍生版本：**全构建链路国内镜像加速 + 一键管理脚本**，无需访问国外网络即可完成构建与运行。

</div>

## 本版本与上游的区别

| 改动 | 说明 |
|------|------|
| 构建镜像源国内化 | 基础镜像走 `ghcr.nju.edu.cn` / `docker.m.daocloud.io`，无需访问 Docker Hub / GHCR |
| Worker 镜像构建国内化 | apt（USTC Kali）、pip（阿里云 PyPI）、npm（npmmirror）、playwright（npmmirror CDN）、GitHub 下载（gh-proxy 代理） |
| pwntools 安装修复 | 改用 Kali apt 仓库的 `python3-pwntools`，解决 Python 3.14 下 unicorn 源码编译失败问题 |
| 一键管理脚本 | `cairnctl.sh` 提供 start / stop / restart / status / logs |
| 纯本地运行 | 运行时只使用本地镜像，不发生任何镜像拉取 |

## 项目简介

Cairn 是一个通用的问题求解引擎：给定起点（origin）和目标（goal），在未知的状态空间中搜索路径。AI 渗透测试是首个被验证的领域（腾讯云黑客松智能渗透挑战赛第二届：54/54 全解，第三名）。

引擎基于**黑板架构**（Blackboard Architecture）与显式的 Fact–Intent 图，只有三个原语：

| 概念 | 含义 |
|------|------|
| **Fact** | 写入黑板的已确认客观发现（只增不改） |
| **Intent** | 声明的探索方向，由 Worker 认领执行 |
| **Hint** | 随时注入的人类判断，Agent 下次读取时吸收 |

三类任务均由同一 Worker 执行：**Bootstrap**（开局直接求解）、**Reason**（读全图决定下一步）、**Explore**（认领 Intent 探索并汇报 Fact）。

系统由两部分组成：

- **Cairn Server**：FastAPI + SQLite，维护图一致性，提供 Web UI（端口 8000）
- **Dispatcher**：唯一协议写入方，调度任务、为每个项目启动独立 Worker 容器

支持的 Worker 后端：**Claude Code**、**Codex**、**Pi**。

## 快速开始

**前置要求**

- Linux（含 WSL2）或 macOS
- Docker（容器模式必需）
- Python ≥ 3.12 + uv（仅手动方式/开发需要）

### 1. 准备配置

```bash
cp dispatch.example.yaml dispatch.yaml
# 编辑 dispatch.yaml，填入你的 LLM 端点和 API key
```

`dispatch.yaml` 已在 `.gitignore` 中，不会被提交。

### 2. 一键构建

```bash
./build.sh
```

脚本会构建全部镜像（worker 容器镜像 + cairn-app），全程走国内源，并在结束后列出镜像清单。

```bash
./build.sh              # 构建全部镜像（worker 已存在则跳过）
./build.sh worker       # 只构建 worker 容器镜像
./build.sh app          # 只构建 cairn-app（server + dispatcher）
./build.sh --force      # 强制重建 worker 镜像
./build.sh --no-cache   # 完全不用缓存重建
```

构建完成后，确保 `dispatch.yaml` 中的 `container.image` 指向本地镜像（脚本会自动检测并提示）：

```yaml
container:
  image: "cairn-worker-container:cn"
```

> 也可以不构建，直接从国内镜像拉取预构建的 worker 镜像：
>
> ```bash
> docker pull ghcr.nju.edu.cn/oritera/cairn-worker-container:latest
> ```

### 3. 一键启动

```bash
./cairnctl.sh start
```

启动完成后访问 Web UI：`http://localhost:8000`（WSL2 用户可直接在 Windows 浏览器打开）。

### 管理命令

```bash
./build.sh                 # 一键构建全部镜像
./cairnctl.sh start        # 一键启动（自动等待 server 就绪）
./cairnctl.sh stop         # 停止并清理容器
./cairnctl.sh restart      # 重启
./cairnctl.sh status       # 容器状态 + server 健康 + dispatcher 最近日志
./cairnctl.sh logs         # 跟踪全部日志
./cairnctl.sh logs dispatcher   # 只看调度器日志
./cairnctl.sh logs server       # 只看 server 日志
```

## 国内镜像源一览

| 依赖 | 源 |
|------|-----|
| cairn-app 基础镜像 (`uv:python3.13-trixie`) | `ghcr.nju.edu.cn` |
| Worker 基础镜像 (`kali-rolling`) | `docker.m.daocloud.io` |
| Kali apt | `mirrors.ustc.edu.cn/kali`（HTTP，GPG 签名校验） |
| Python pip | `mirrors.aliyun.com/pypi/simple` |
| Node npm | `registry.npmmirror.com` |
| Playwright 浏览器 | npmmirror 二进制镜像 |
| GitHub release / clone | `gh-proxy.com` 代理（`GH_PROXY` 环境变量，可一行替换） |

> 注意：`gh-proxy.com` 是第三方公益代理，若失效请修改 `container/Dockerfile` 顶部的 `GH_PROXY` 为其他可用代理。

## 其他运行方式

<details>
<summary>手动方式（uv 直跑，用于开发调试）</summary>

```bash
# 启动 server（默认 http://127.0.0.1:8000）
uv run --project cairn cairn serve

# 启动 dispatcher
uv run --project cairn cairn dispatch --config dispatch.yaml

# 只跑一个调度迭代 / 只跑启动健康检查
uv run --project cairn cairn dispatch --config dispatch.yaml --once
uv run --project cairn cairn dispatch --config dispatch.yaml --startup-healthcheck-only
```
</details>

<details>
<summary>Local 模式（无 Docker，复用宿主机已登录的 claude/codex/pi CLI）</summary>

```bash
cp dispatch.local.example.yaml dispatch.yaml
uv run --project cairn cairn serve
uv run --project cairn cairn dispatch --config dispatch.yaml
```

注意：Local 模式下 Agent 以当前用户权限直接在宿主机运行，无沙箱隔离，Dispatcher 必须在宿主机直跑（不能放进 Docker）。
</details>

<details>
<summary>运行测试</summary>

测试套件不需要 Docker 和真实模型端点：

```bash
uv run --project cairn --group dev pytest
```
</details>

## 安全与免责声明

Cairn 是通用问题求解引擎。尽管它支持渗透测试、CTF 解题、安全评估和漏洞研究工作流，但**仅应在获得明确授权的环境中使用**。

你需要对自己的使用方式负全部责任。未经系统所有者明确许可，不得对任何系统、网络、应用或数据使用 Cairn。未授权的安全测试、漏洞利用或数据访问可能违法并造成损害。

本项目开发者及贡献者不为任何滥用、损害、损失或法律后果承担责任。使用本项目即表示你同意确保自己的行为符合所在司法辖区的所有适用法律、法规、合同义务及行业政策。

## License

本项目基于 **GNU AGPLv3** 开源（个人与教育用途）。商业使用请联系作者获取商业许可。上游项目：[oritera/Cairn](https://github.com/oritera/Cairn)。
