# nezha_agent 固定版本 v0.14.11 安装脚本

本项目提供一个用于安装 **哪吒监控固定版本 v0.14.11 的 Agent 的一键脚本**，支持以下功能：

- 自动判断系统类型（Alpine / Debian / Ubuntu）
- 自动判断 CPU 架构（x86_64 / ARM）
- 部署固定版本 Agent 并注册为守护进程
- 支持开机自启 + 探针崩溃自动重启（OpenRC / systemd）

---

## 使用说明

### 1. 前往哪吒面板，复制 Agent 安装命令

通常格式类似于：

```bash
curl -L https:///install.sh -o nezha.sh && chmod +x nezha.sh && sudo ./nezha.sh install_agent <面板地址> <端口> <密钥> --tls
```

### 2. 替换脚本地址为本项目地址：

将哪吒面板安装命令中的脚本地址部分替换为以下链接：

```bash
https://raw.githubusercontent.com/pingmike2/nezha/main/nezha.sh
```

### 3. 示例命令

以下是完整的一键安装命令示例（请根据你的面板信息替换参数）：

```bash
curl -L https://raw.githubusercontent.com/pingmike2/nezha/main/nezha.sh -o nezha.sh && chmod +x nezha.sh && sudo ./nezha.sh install_agent nezha.xxxx.nyc.mn 443 hZzhvVnS4JuecsZ --tls
```

示例中使用了 TLS，若你的面板未配置 TLS，可去掉 --tls 参数.

一键清理并重启
(慎用)
systemctl stop nezha-agent 2>/dev/null || rc-service nezha-agent stop 2>/dev/null

清理敏感命令历史
history -d $(history 1)

### 卸载方法

如需卸载 Agent，使用以下命令：

```bash
sudo ./nezha.sh uninstall_agent
```

该命令将自动判断系统类型并清理对应的守护服务（systemd 或 OpenRC）、二进制文件及日志。

### 注意事项

- 哪吒监控 v1.x 已发布，面板默认安装的是 v0.20.5 的 Agent。
- 本脚本强制使用 **固定版本 v0.14.11**，不会自动升级，适用于旧版本面板或定制需求。
- 支持系统：
  - Debian / Ubuntu（使用 systemd）
  - Alpine（使用 OpenRC）
- 支持架构：
  - x86_64
  - ARMv7 / ARM64
- 不建议混合部署多个版本的探针，避免冲突或资源占用异常。
- Agent 安装后会以守护进程方式运行，支持开机自启和异常自动重启。
- 
- 灵感来源来源于 老王node-ws
- https://github.com/eooce/node-ws

- 代码中使用了OTC大佬的反代服务，目前不清楚是不是公益服务，为了测试脚本临时使用，如果大佬介意，我还接着用


### 免责声明

本项目为个人自用脚本，仅供技术测试和学习交流使用。

- 使用本脚本即表示你已知悉并接受所有风险。
- 作者不对因使用本脚本造成的任何数据损失、服务器故障或安全问题负责。
- 本项目不提供技术支持服务，出现问题请自行排查解决。
