# tcloud-ssl-deploy

腾讯云 SSL 证书自动部署脚本 - acme.sh 续签证书后，自动上传到腾讯云 SSL 并一键更新关联云资源。

## 功能特性

- ✅ **自动查询旧证书**：自动查询当前腾讯云账号下指定域名的最旧有效证书作为"旧证书 ID"，无需手动填写
- ✅ **智能指纹对比**：对比本地证书与旧证书 SHA1 指纹，相同则跳过（无需重复上传/更新），指纹统一转为无分隔符大写格式避免格式差异误判
- ✅ **证书自动上传**：上传 acme.sh 续签的新证书，上传后轮询确认证书入库成功
- ✅ **一键资源更新**：自动更新所有关联云资源，支持 CLB、CDN、WAF、TEO、COS、API Gateway、Live 等
- ✅ **详细日志记录**：支持输出到 stdout 和日志文件，便于排查问题

## 系统要求

### 依赖工具

- **jq**：JSON 处理工具
- **python3**：用于腾讯云 API 签名计算
- **openssl**：用于证书指纹提取

### 操作系统

- Linux / macOS
- Windows (WSL)

## 安装

1. 克隆或下载本项目：

```bash
git clone https://github.com/city-demo/tcloud-ssl-deploy.git
cd tcloud-ssl-deploy
```

2. 确保依赖工具已安装：

```bash
# Ubuntu/Debian
sudo apt-get install jq python3 openssl

# CentOS/RHEL
sudo yum install jq python3 openssl

# macOS
brew install jq python3 openssl
```

3. 添加执行权限：

```bash
chmod +x tcloud-ssl-deploy.sh
```

## 配置

编辑 `tcloud-ssl-deploy.sh` 文件，修改 `[配置区]` 中的以下必填项：

### 必填配置

```bash
# 腾讯云 API 密钥（建议使用子账号，仅授予 QcloudSSLFullAccess 权限）
SECRET_ID="your_secret_id"
SECRET_KEY="your_secret_key"

# 域名（用于自动匹配旧证书）
DOMAIN="example.com"

# acme.sh 证书文件路径
CERT_DIR="$HOME/acme.sh/${DOMAIN}_ecc"   # ECC 证书目录；RSA 证书去掉 _ecc
CERT_FILE="${CERT_DIR}/fullchain.cer"     # 证书链（公钥）
KEY_FILE="${CERT_DIR}/${DOMAIN}.key"      # 私钥
```

### 可选配置

```bash
# 需要更新的云资源类型（空格分隔）
RESOURCE_TYPES="clb cdn waf teo cos apigateway live"

# 证书别名前缀
CERT_ALIAS_PREFIX="${DOMAIN}"

# 是否忽略旧证书到期提醒（1=忽略，0=不忽略）
EXPIRING_NOTIFICATION_SWITCH=1

# 上传后等待证书入库的最大轮询次数（每次间隔 3 秒）
UPLOAD_CONFIRM_RETRIES=3

# 日志文件路径（留空则只输出到 stdout）
LOG_FILE="${SCRIPT_DIR}/tcloud-ssl-deploy.log"
```

## 使用方法

```bash
./tcloud-ssl-deploy.sh
```

## 工作流程

```
1. 检查环境依赖
   ↓
2. 读取本地证书文件
   ↓
3. 获取本地证书 SHA1 指纹
   ↓
4. 查询腾讯云账号下该域名的有效证书
   ↓
5. 对比指纹
   ├─ 相同 → 跳过更新，退出
   └─ 不同 ↓
6. 上传新证书到腾讯云
   ↓
7. 等待证书入库确认
   ↓
8. 60秒缓冲等待云端同步
   ↓
9. 执行一键更新关联云资源
   ↓
10. 部署完成
```

## 腾讯云权限配置

建议创建子账号并仅授予以下权限：

- **QcloudSSLFullAccess**：SSL 证书管理完全访问权限

如果需要更新特定资源，可能还需要：

- **QcloudCLBFullAccess**：负载均衡
- **QcloudCDNFullAccess**：CDN
- **QcloudWAFFullAccess**：Web 应用防火墙
- **QcloudCOSFullAccess**：对象存储
- **QcloudAPIGatewayFullAccess**：API 网关
- **QcloudLiveFullAccess**：云直播

## 日志示例

```
[2024-01-15 10:30:00] ===== 腾讯云 SSL 证书自动部署开始 =====
[2024-01-15 10:30:00] 正在执行证书指纹校验...
[2024-01-15 10:30:01] 指纹不匹配，准备上传并更新...
[2024-01-15 10:30:02] 新证书上传成功，ID: abc123def456
[2024-01-15 10:30:02] 等待新证书 abc123def456 基础入库...
[2024-01-15 10:30:05] OK: 证书 abc123def456 已确认基础入库
[2024-01-15 10:30:05] 启动 60 秒强制缓冲，确保云端资源系统同步...
[2024-01-15 10:31:05] 执行一键更新任务: old_cert_id -> new_cert_id
[2024-01-15 10:31:06] OK: 部署任务已成功创建！任务 ID: 789xyz
[2024-01-15 10:31:06] ===== 部署完成 =====
```

## 故障排查

### 常见问题

1. **缺少依赖命令**
   ```
   ERROR: 缺少依赖命令：jq
   ```
   解决：安装对应的依赖工具

2. **证书文件不存在**
   ```
   ERROR: 证书文件不存在：/path/to/cert
   ```
   解决：检查 `CERT_FILE` 和 `KEY_FILE` 路径配置

3. **API 调用失败**
   ```
   ERROR: 查询失败：[错误信息]
   ```
   解决：检查 `SECRET_ID` 和 `SECRET_KEY` 是否正确，以及子账号权限

4. **部署任务创建超时**
   ```
   ERROR: 部署任务创建超时。请检查腾讯云控制台。
   ```
   解决：检查腾讯云控制台查看任务状态，或增加重试次数

### 调试模式

脚本内置了 `debug` 函数，会输出详细的调试信息到 stderr。如需查看更多调试信息，可以修改脚本或查看日志文件。

## 安全建议

1. **使用子账号**：不要使用主账号的 API 密钥
2. **最小权限原则**：仅授予必要的 SSL 管理权限
3. **保护密钥文件**：确保 `SECRET_KEY` 不被泄露
4. **定期轮换密钥**：定期更换腾讯云 API 密钥

## 许可证

MIT License

