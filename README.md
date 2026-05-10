# xray-setup

CentOS 9.4 服务器上一键自动化部署 3x-ui 面板、VMESS 代理节点，自动生成节点分享链接及通用订阅配置。
---
## 快速开始

  ### 1. 直接在服务器上创建该脚本文件并赋予执行权限：

```bash
  curl -O https://raw.githubusercontent.com/gsmhai/one_key_vps/main/vmess.sh
  chmod +x vmess.sh
```
### 2.用户名密码配置
如果想修改web面板的用户名和密码，手动编辑文件开头的用户名和密码，默认用户名密码都为:admin，如果不想改直接跳过
```bash
  PANEL_USER="admin"   # 面板登录用户名
  PANEL_PASS="admin"   # 面板登录密码
```
### 3. 执行脚本
运行环境要求：CentOS 9.4 (自带 Firewalld 防火墙控制)
```bash
bash vmess.sh
```

## 脚本说明

运行后脚本将进入全自动流程，你无需进行任何输入。脚本将会自动完成以下操作：

安装必备系统依赖。

配置 Firewalld 防火墙，放行 80、随机面板端口及随机节点端口。

全自动无交互安装 3x-ui 并申请基于 IP 的 SSL 证书。

在底层数据库静默注入 VMESS 代理节点及订阅 ID。

终端输出完整的面板 HTTPS 访问地址、VMESS 导入链接及通用订阅链接。

直接复制输出的链接至 V2rayN 或 Clash 订阅转换器即可使用。
