#!/usr/bin/env bash
# =============================================================================
# tcloud-ssl-deploy.sh
# acme.sh 续签证书后，自动上传到腾讯云 SSL 并一键更新关联云资源
#
# 特性：
#   - 自动查询当前账号下指定域名最旧有效证书作为"旧证书 ID"，无需手动填写
#   - 对比本地证书与旧证书 SHA1 指纹，相同则跳过（无需重复上传/更新）
#     ※ 指纹统一转为无分隔符大写格式后再比较，避免格式差异误判
#   - 上传 acme 续签的新证书，上传后轮询确认证书入库成功
#   - 一键更新所有关联云资源（clb/cdn/waf/teo/cos/apigateway/live 等）
#
# 用法：
#   1. 填写下方 [配置区] 的必填项
#   2. 配置 acme.sh --reloadcmd 调用本脚本，或手动执行
#      acme.sh --install-cert -d example.com --reloadcmd "/path/to/tcloud-ssl-deploy.sh"
#
# 依赖：jq、python3、openssl
# =============================================================================

set -euo pipefail

# =============================================================================
# [配置区] 请根据实际情况修改
# =============================================================================

# 腾讯云 API 密钥（建议使用子账号，仅授予 QcloudSSLFullAccess 权限）
SECRET_ID="your_secret_id"
SECRET_KEY="your_secret_key"

# 域名（用于自动匹配旧证书）
DOMAIN="example.com"

# acme.sh 证书文件路径
CERT_DIR="$HOME/acme.sh/${DOMAIN}_ecc"   # ECC 证书目录；RSA 去掉 _ecc
CERT_FILE="${CERT_DIR}/fullchain.cer"       # 证书链（公钥）
KEY_FILE="${CERT_DIR}/${DOMAIN}.key"        # 私钥

# 需要更新的云资源类型（空格分隔）
RESOURCE_TYPES="clb cdn waf teo cos apigateway live"

# 是否忽略旧证书到期提醒（1=忽略，0=不忽略）
CERT_ALIAS_PREFIX="${DOMAIN}"

# 是否忽略旧证书到期提醒（1=忽略，0=不忽略）
EXPIRING_NOTIFICATION_SWITCH=1

# 上传后等待证书入库的最大轮询次数（每次间隔 3 秒）
UPLOAD_CONFIRM_RETRIES=3

# 自动获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#  日志文件（留空则只输出到 stdout）
LOG_FILE="${SCRIPT_DIR}/tcloud-ssl-deploy.log"

# =============================================================================
# 工具函数
# =============================================================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

# 关键修复：将 debug 信息重定向到 stderr (>&2)，避免被 $(...) 捕获
debug() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*"
    echo "$msg" >&2
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

countdown() {
    local seconds=$1
    while [ "$seconds" -gt 0 ]; do
        printf "\r[$(date '+%Y-%m-%d %H:%M:%S')] [Wait] 正在同步云端索引，剩余时间: %2d 秒..." "$seconds"
        sleep 1
        seconds=$((seconds - 1))
    done
    printf "\r[$(date '+%Y-%m-%d %H:%M:%S')] [Done] 缓冲结束，准备执行更新...          \n"
}

tcloud_api() {
    local service="$1"
    local action="$2"
    local payload="$3"
    local host="${service}.tencentcloudapi.com"
    local version="2019-12-05"

    python3 - <<PYEOF
import hmac, hashlib, datetime, urllib.request, time, json
secret_id  = "${SECRET_ID}"
secret_key = "${SECRET_KEY}".encode("utf-8")
service    = "${service}"
host        = "${host}"
action     = "${action}"
version    = "${version}"
payload    = r"""${payload}"""
timestamp = int(time.time())
date_str  = datetime.datetime.utcfromtimestamp(timestamp).strftime("%Y-%m-%d")
canonical_headers = f"content-type:application/json; charset=utf-8\nhost:{host}\nx-tc-action:{action.lower()}\n"
signed_headers    = "content-type;host;x-tc-action"
hashed_payload    = hashlib.sha256(payload.encode("utf-8")).hexdigest()
canonical_request = "\n".join(["POST", "/", "", canonical_headers, signed_headers, hashed_payload])
credential_scope = f"{date_str}/{service}/tc3_request"
hashed_cr         = hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
string_to_sign   = "\n".join(["TC3-HMAC-SHA256", str(timestamp), credential_scope, hashed_cr])
def sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()
sig = hmac.new(
    sign(sign(sign(b"TC3" + secret_key, date_str), service), "tc3_request"),
    string_to_sign.encode("utf-8"), hashlib.sha256
).hexdigest()
authorization = f"TC3-HMAC-SHA256 Credential={secret_id}/{credential_scope}, SignedHeaders={signed_headers}, Signature={sig}"
req = urllib.request.Request(
    f"https://{host}",
    data=payload.encode("utf-8"),
    headers={
        "Authorization": authorization,
        "Content-Type": "application/json; charset=utf-8",
        "Host": host,
        "X-TC-Action": action,
        "X-TC-Timestamp": str(timestamp),
        "X-TC-Version": version,
    },
    method="POST"
)
try:
    with urllib.request.urlopen(req) as resp:
        print(resp.read().decode("utf-8"))
except Exception as e:
    # 打印详细错误方便排查
    if hasattr(e, 'read'):
        print(e.read().decode("utf-8"))
    else:
        print(f'{{"Response": {{"Error": {{"Code": "NetworkError", "Message": "{str(e)}"}} }} }}')
PYEOF
}

normalize_fingerprint() {
    echo "$1" | tr -d ': ' | tr '[:lower:]' '[:upper:]' | xargs
}

get_local_fingerprint() {
    local cert_file="$1"
    local raw
    raw=$(openssl x509 -noout -fingerprint -sha1 -in "$cert_file" | sed 's/.*Fingerprint=//')
    debug "本地原始指纹 (SHA1): $raw"
    normalize_fingerprint "$raw"
}

get_old_cert_info() {
    debug "正在查询域名 ${DOMAIN} 下的有效证书..."   # ← log 改 debug
    local resp
    resp=$(tcloud_api ssl DescribeCertificates "{\"SearchKey\": \"${DOMAIN}\", \"Limit\": 100}")
    
    local err_code
    err_code=$(echo "$resp" | jq -r '.Response.Error.Code // empty')
    [[ -n "$err_code" ]] && die "查询失败：$(echo "$resp" | jq -r '.Response.Error.Message')"

    local old_cert_id
    old_cert_id=$(echo "$resp" | jq -r '
        .Response.Certificates
        | map(select(.Status == 1 and (.Domain == "'"${DOMAIN}"'" or (.SubjectAltName // [] | any(. == "'"${DOMAIN}"'" or . == "*.'"${DOMAIN}"'")))))
        | sort_by(.CertEndTime) | reverse | .[0].CertificateId // empty')

    if [[ -z "$old_cert_id" || "$old_cert_id" == "null" ]]; then
        debug "云端未找到匹配的有效证书"
        echo "|"
        return
    fi

    debug "云端证书 ID: $old_cert_id"
    
    local detail_resp
    detail_resp=$(tcloud_api ssl DescribeCertificateDetail "{\"CertificateId\": \"${old_cert_id}\"}")
    local raw_fp
    raw_fp=$(echo "$detail_resp" | jq -r '.Response.CertFingerprint // empty')
    
    debug "云端原始指纹: $raw_fp"
    echo "${old_cert_id}|$(normalize_fingerprint "$raw_fp")"
}

wait_cert_ready() {
    local cert_id="$1"
    local i=0
    log "等待新证书 ${cert_id} 基础入库..."
    while [[ $i -lt $UPLOAD_CONFIRM_RETRIES ]]; do
        local detail
        detail=$(tcloud_api ssl DescribeCertificateDetail "{\"CertificateId\": \"${cert_id}\"}")
        if [[ -z "$(echo "$detail" | jq -r '.Response.Error.Code // empty')" ]]; then
            log "OK: 证书 ${cert_id} 已确认基础入库"
            return 0
        fi
        debug "入库轮询中... ($((i+1))/${UPLOAD_CONFIRM_RETRIES})"
        i=$((i + 1))
        sleep 3
    done
    die "新证书入库轮询超时"
}

main() {
    log "===== 腾讯云 SSL 证书自动部署开始 ====="

    # 1. 检查环境依赖
    for cmd in jq python3 openssl; do
        command -v "$cmd" &>/dev/null || die "缺少依赖命令：$cmd"
    done
    [[ -f "$CERT_FILE" ]] || die "证书文件不存在：$CERT_FILE"
    [[ -f "$KEY_FILE"  ]] || die "私钥文件不存在：$KEY_FILE"

    # 2. 执行指纹校验（已修复 debug 函数污染 stdout 的问题）
    log "正在执行证书指纹校验..."
    local local_fingerprint
    local_fingerprint=$(get_local_fingerprint "$CERT_FILE")
    
    local old_info old_cert_id old_fingerprint
    old_info=$(get_old_cert_info)
    old_cert_id="${old_info%%|*}"
    old_fingerprint="${old_info##*|}"

    debug "最终对比 -> 本地: [$local_fingerprint] | 云端: [$old_fingerprint]"

    # 如果指纹一致，直接退出
    if [[ -n "$old_fingerprint" && "$local_fingerprint" == "$old_fingerprint" ]]; then
        log "OK: 本地与云端证书一致 ($local_fingerprint)，跳过更新。"
        exit 0
    fi

    # 3. 上传新证书
    log "指纹不匹配，准备上传并更新..."
    local cert_alias="${CERT_ALIAS_PREFIX}-$(date +%Y%m%d%H%M)"
    local upload_payload
    upload_payload=$(jq -n --arg pub "$(cat "$CERT_FILE")" --arg priv "$(cat "$KEY_FILE")" --arg alias "$cert_alias" \
        '{CertificatePublicKey: $pub, CertificatePrivateKey: $priv, CertificateType: "SVR", Alias: $alias, Repeatable: true}')

    local upload_resp
    upload_resp=$(tcloud_api ssl UploadCertificate "$upload_payload")
    local new_cert_id
    new_cert_id=$(echo "$upload_resp" | jq -r '.Response.CertificateId // .Response.RepeatCertId')
    
    if [[ -z "$new_cert_id" || "$new_cert_id" == "null" ]]; then
        debug "上传响应详情: $upload_resp"
        die "证书上传失败"
    fi
    log "新证书上传成功，ID: $new_cert_id"

    # 4. 等待云端基础入库并缓冲
    wait_cert_ready "$new_cert_id"
    
    log "启动 60 秒强制缓冲，确保云端资源系统同步..."
    countdown 60

    # 5. 执行一键更新任务（已修复 DeployRecordId 为 0 的轮询逻辑）
    if [[ -n "$old_cert_id" && -n "$RESOURCE_TYPES" ]]; then
        log "执行一键更新任务: $old_cert_id -> $new_cert_id"
        local types_json
        types_json=$(echo "$RESOURCE_TYPES" | tr ' ' '\n' | jq -R . | jq -s .)
        local update_payload
        update_payload=$(jq -n --arg old "$old_cert_id" --arg new "$new_cert_id" --argjson ts "$types_json" --argjson n "$EXPIRING_NOTIFICATION_SWITCH" \
            '{OldCertificateId: $old, CertificateId: $new, ResourceTypes: $ts, ExpiringNotificationSwitch: $n}')

        local deploy_record_id=0
        local retry=0
        # 增加至 15 次重试，每次 120 秒，总计约 30 分钟轮询窗口
        while [[ "$retry" -lt 15 ]]; do
            local update_resp
            update_resp=$(tcloud_api ssl UpdateCertificateInstance "$update_payload")
            local err_code
            err_code=$(echo "$update_resp" | jq -r '.Response.Error.Code // empty')
            
            # 处理 API 报错
            if [[ -n "$err_code" ]]; then
                debug "更新接口响应异常 ($((retry+1))): $update_resp"
                if [[ "$err_code" == "ResourceNotFound.CertificateNotFound" || "$update_resp" == *"证书不存在"* ]]; then
                    log "Wait: 云端索引未就绪，120 秒后重试..."
                    sleep 120
                    retry=$((retry + 1))
                    continue
                fi
                die "更新失败：$(echo "$update_resp" | jq -r '.Response.Error.Message')"
            fi
            
            # 获取任务 ID
            deploy_record_id=$(echo "$update_resp" | jq -r '.Response.DeployRecordId // 0')
            
            # 只有 ID 大于 0 才代表任务真正下发成功
            if [[ "$deploy_record_id" != "0" && -n "$deploy_record_id" && "$deploy_record_id" != "null" ]]; then
                log "OK: 部署任务已成功创建！任务 ID: ${deploy_record_id}"
                break
            else
                log "Wait: 任务创建中 (DeployRecordId=0)，120 秒后进行第 $((retry+1)) 次确认..."
                sleep 120
                retry=$((retry + 1))
            fi
        done

        if [[ "$deploy_record_id" == "0" || -z "$deploy_record_id" ]]; then
            die "部署任务创建超时。请检查腾讯云控制台。 "
        fi
    else
        log "Skip: 未发现旧证书 ID 或未配置资源类型，跳过关联资源更新。"
    fi

    log "===== 部署完成 ====="
}

main "$@"