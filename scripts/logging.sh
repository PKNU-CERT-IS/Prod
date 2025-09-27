#!/bin/bash
# ===========================================
# CERT-IS 프로덕션 환경 설정 스크립트 (Docker 설치 후 실행)
# 전제조건: Docker가 이미 설치되어 있어야 함
# 실행 방법: chmod +x setup-production-environment.sh && ./setup-production-environment.sh
# ===========================================

set -e  # 에러 발생 시 스크립트 중단

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 설정 변수
PROJECT_DIR="/home/ubuntu/Prod"
LOG_DIR="/var/log/cert-is"
BACKUP_DIR="/home/ubuntu/backups"
SCRIPT_DIR="/home/ubuntu/Prod/scripts"
S3_BUCKET="${S3_LOG_BUCKET:-certis-log-archive}"
AWS_REGION="${AWS_REGION:-ap-south-1}"

# 로깅 함수
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Docker 설치 확인
check_docker_installation() {
    log "Docker 설치 확인 중..."
    
    if ! command -v docker &> /dev/null; then
        error "Docker가 설치되지 않았습니다. 먼저 setup-docker-environment.sh를 실행해주세요."
        exit 1
    fi
    
    if ! docker compose version &> /dev/null; then
        error "Docker Compose가 설치되지 않았습니다. 먼저 setup-docker-environment.sh를 실행해주세요."
        exit 1
    fi
    
    info "Docker 설치 확인 완료: $(docker --version)"
    info "Docker Compose 확인 완료: $(docker compose version --short)"
}

# 추가 프로덕션 패키지 설치
install_production_packages() {
    log "프로덕션 환경 추가 패키지 설치 중..."
    
    # Docker 기본 스크립트에서 설치되지 않은 추가 패키지들
    sudo apt-get install -y \
        htop \
        tree \
        vim \
        git \
        jq \
        awscli \
        fail2ban \
        ufw \
        logrotate \
        rsync \
        zip \
        bc
    
    log "추가 패키지 설치 완료!"
}

# 프로덕션 디렉토리 구조 생성 (기존과 다른 부분만)
create_production_directories() {
    log "프로덕션 디렉토리 구조 생성 중..."
    
    # 로그 디렉토리 (기존 /var/data와 별도)
    sudo mkdir -p "$LOG_DIR"
    sudo mkdir -p "$LOG_DIR/archive"
    sudo mkdir -p "$BACKUP_DIR"
    sudo mkdir -p "$SCRIPT_DIR"
    sudo mkdir -p "$PROJECT_DIR/logs/caddy"
    sudo mkdir -p "$PROJECT_DIR/BE/uploads"
    sudo mkdir -p "$PROJECT_DIR/fail2ban"
    
    # 권한 설정
    sudo chown -R ubuntu:ubuntu "$PROJECT_DIR"
    sudo chown -R ubuntu:ubuntu "$BACKUP_DIR"
    sudo chown -R ubuntu:ubuntu "$LOG_DIR"
    
    # 로그 디렉토리 권한 설정
    sudo chmod 755 "$LOG_DIR"
    sudo chmod 755 "$PROJECT_DIR/logs"
    
    log "프로덕션 디렉토리 구조 생성 완료!"
}

# Fail2Ban 설정
setup_fail2ban() {
    log "Fail2Ban 설정 중..."
    
    # Fail2Ban이 실행 중이면 중지
    sudo systemctl stop fail2ban 2>/dev/null || true
    
    # Fail2Ban 설정 디렉토리 생성
    mkdir -p "$PROJECT_DIR/fail2ban/action.d"
    mkdir -p "$PROJECT_DIR/fail2ban/filter.d"
    mkdir -p "$PROJECT_DIR/fail2ban/jail.d"
    
    # Caddy 필터 설정
    cat > "$PROJECT_DIR/fail2ban/filter.d/caddy-auth.conf" << 'EOF'
[Definition]
failregex = ^.*\[ERROR\].*"remote_ip":"<HOST>".*"status":40[13].*$
            ^.*\[ERROR\].*"remote_addr":"<HOST>".*authentication failed.*$
ignoreregex =
EOF
    
    # Jail 설정
    cat > "$PROJECT_DIR/fail2ban/jail.d/caddy.conf" << 'EOF'
[caddy-auth]
enabled = true
port = http,https
filter = caddy-auth
logpath = /home/ubuntu/Prod/logs/caddy/*.log
maxretry = 5
bantime = 3600
findtime = 600
action = iptables-allports[name=caddy-auth, protocol=all]
EOF
    
    # Fail2Ban 설정 적용
    sudo systemctl start fail2ban
    sudo systemctl enable fail2ban
    
    log "Fail2Ban 설정 완료!"
}

# 로그 관리 스크립트 설치
install_log_management_scripts() {
    log "로그 관리 스크립트 설치 중..."
    
    # 로그 모니터링 스크립트
    cat > "$SCRIPT_DIR/log_monitor.sh" << 'EOF'
#!/bin/bash
# 로그 모니터링 스크립트

LOG_DIR="/var/log/cert-is"
ERROR_LOG="$LOG_DIR/error.log"
APP_LOG="$LOG_DIR/application.log"

# 에러 카운트 체크
check_errors() {
    if [ -f "$ERROR_LOG" ]; then
        error_count=$(tail -n 100 "$ERROR_LOG" | grep "$(date '+%Y-%m-%d %H:%M' -d '5 minutes ago')" | wc -l)
        if [ "$error_count" -gt 10 ]; then
            echo "HIGH ERROR RATE: $error_count errors in last 5 minutes"
        fi
    fi
}

# 디스크 사용량 체크
check_disk_usage() {
    disk_usage=$(df -h /var/log | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ "$disk_usage" -gt 85 ]; then
        echo "HIGH DISK USAGE: ${disk_usage}% on /var/log"
    fi
}

# 애플리케이션 헬스체크
check_app_health() {
    health_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/actuator/health 2>/dev/null || echo "000")
    if [ "$health_status" != "200" ]; then
        echo "APPLICATION HEALTH CHECK FAILED: HTTP $health_status"
    fi
}

check_errors
check_disk_usage
check_app_health
EOF
    
    # S3 로그 아카이브 스크립트
    cat > "$SCRIPT_DIR/archive_logs.sh" << EOF
#!/bin/bash
# 로그 아카이브 스크립트

LOG_DIR="/var/log/cert-is"
ARCHIVE_DIR="\$LOG_DIR/archive"
S3_BUCKET="$S3_BUCKET"
DATE=\$(date +%Y%m%d)

# 30일 이상 된 로그 압축 및 S3 업로드
archive_old_logs() {
    find "\$LOG_DIR" -name "*.log" -mtime +30 | while read logfile; do
        if [ -f "\$logfile" ]; then
            filename=\$(basename "\$logfile")
            archive_name="\${filename%.*}_\${DATE}.gz"
            
            # 압축
            gzip -c "\$logfile" > "\$ARCHIVE_DIR/\$archive_name"
            
            # S3 업로드 (AWS CLI가 설치되어 있는 경우)
            if command -v aws &> /dev/null; then
                aws s3 cp "\$ARCHIVE_DIR/\$archive_name" "s3://\$S3_BUCKET/logs/\$(date +%Y)/\$(date +%m)/" --storage-class GLACIER
                
                # 업로드 성공하면 로컬 파일 삭제
                if [ \$? -eq 0 ]; then
                    rm "\$ARCHIVE_DIR/\$archive_name"
                    echo "Archived and uploaded \$logfile to S3 Glacier"
                fi
            fi
            
            # 원본 로그 파일을 빈 파일로 초기화
            > "\$logfile"
        fi
    done
}

# Docker 로그 정리
cleanup_docker_logs() {
    docker system prune -f
    
    # 컨테이너 로그 크기 제한 (30일 이상 된 로그)
    find /var/lib/docker/containers/ -name "*.log" -mtime +30 -exec truncate -s 0 {} \; 2>/dev/null || true
}

archive_old_logs
cleanup_docker_logs

echo "Log archival completed on \$(date)"
EOF
    
    # 시스템 리소스 체크 스크립트
    cat > "$SCRIPT_DIR/system_check.sh" << 'EOF'
#!/bin/bash
# 시스템 리소스 체크

LOG_FILE="/var/log/cert-is/system_resources.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

# CPU 사용률
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//')

# 메모리 사용률
MEM_USAGE=$(free | grep Mem | awk '{printf "%.2f", ($3/$2) * 100.0}')

# 디스크 사용률
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')

# 로드 평균
LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}')

# 로그에 기록
echo "$DATE - CPU: ${CPU_USAGE}%, MEM: ${MEM_USAGE}%, DISK: ${DISK_USAGE}%, LOAD:$LOAD_AVG" >> "$LOG_FILE"

# 알림 조건 체크
if (( $(echo "$MEM_USAGE > 85" | bc -l) )); then
    echo "$DATE - HIGH MEMORY USAGE: ${MEM_USAGE}%" >> "$LOG_FILE"
fi

if [ "$DISK_USAGE" -gt 90 ]; then
    echo "$DATE - HIGH DISK USAGE: ${DISK_USAGE}%" >> "$LOG_FILE"
fi
EOF
    
    # 권한 설정
    chmod +x "$SCRIPT_DIR/log_monitor.sh"
    chmod +x "$SCRIPT_DIR/archive_logs.sh"
    chmod +x "$SCRIPT_DIR/system_check.sh"
    
    log "로그 관리 스크립트 설치 완료!"
}

# Crontab 설정
setup_crontab() {
    log "Crontab 설정 중..."
    
    # 기존 cron 작업 백업
    crontab -l > "$BACKUP_DIR/crontab.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    
    # 새로운 cron 작업 설정
    (crontab -l 2>/dev/null; cat << EOF

# CERT-IS Production Monitoring
*/5 * * * * $SCRIPT_DIR/log_monitor.sh >> $LOG_DIR/monitor.log 2>&1
*/5 * * * * $SCRIPT_DIR/system_check.sh
0 2 * * 0 $SCRIPT_DIR/archive_logs.sh >> $LOG_DIR/archive.log 2>&1
0 * * * * curl -f http://localhost:8081/actuator/health > /dev/null 2>&1 || echo "Health check failed at \$(date)" >> $LOG_DIR/health_check.log
*/10 * * * * docker system df >> $LOG_DIR/docker_usage.log
EOF
    ) | crontab -
    
    log "Crontab 설정 완료!"
}

# 방화벽 설정
setup_firewall() {
    log "방화벽 설정 중..."
    
    # UFW 기본 정책 설정
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    
    # 필요한 포트 열기
    sudo ufw allow 22/tcp    # SSH
    sudo ufw allow 80/tcp    # HTTP
    sudo ufw allow 443/tcp   # HTTPS
    
    # UFW 활성화
    sudo ufw --force enable
    
    log "방화벽 설정 완료!"
}

# AWS CLI 설정 확인
check_aws_cli() {
    log "AWS CLI 설정 확인 중..."
    
    if command -v aws &> /dev/null; then
        aws_version=$(aws --version 2>&1)
        info "AWS CLI 버전: $aws_version"
        
        # AWS 자격 증명 확인
        if aws sts get-caller-identity &> /dev/null; then
            info "AWS 자격 증명 확인됨"
        else
            warning "AWS 자격 증명이 설정되지 않았습니다. 'aws configure' 명령어로 설정해주세요."
        fi
    else
        warning "AWS CLI가 설치되지 않았습니다."
    fi
}

# S3 버킷 생성 (선택사항)
create_s3_bucket() {
    log "S3 버킷 생성 확인 중..."
    
    if command -v aws &> /dev/null && aws sts get-caller-identity &> /dev/null; then
        # 버킷 존재 확인
        if ! aws s3 ls "s3://$S3_BUCKET" &> /dev/null; then
            info "S3 버킷 '$S3_BUCKET' 생성 중..."
            aws s3 mb "s3://$S3_BUCKET" --region "$AWS_REGION"
            
            # 라이프사이클 정책 설정 (30일 후 Glacier, 365일 후 Deep Archive)
            cat > /tmp/lifecycle.json << EOF
{
    "Rules": [
        {
            "ID": "LogArchivalPolicy",
            "Status": "Enabled",
            "Transitions": [
                {
                    "Days": 30,
                    "StorageClass": "GLACIER"
                },
                {
                    "Days": 365,
                    "StorageClass": "DEEP_ARCHIVE"
                }
            ]
        }
    ]
}
EOF
            
            aws s3api put-bucket-lifecycle-configuration --bucket "$S3_BUCKET" --lifecycle-configuration file:///tmp/lifecycle.json
            rm /tmp/lifecycle.json
            
            info "S3 버킷 '$S3_BUCKET' 생성 및 라이프사이클 정책 설정 완료!"
        else
            info "S3 버킷 '$S3_BUCKET'이 이미 존재합니다."
        fi
    else
        warning "AWS CLI가 설정되지 않아 S3 버킷을 생성할 수 없습니다."
    fi
}

# SSL 인증서 설정 안내
setup_ssl_info() {
    log "SSL 인증서 설정 안내..."
    
    info "Caddy가 자동으로 Let's Encrypt SSL 인증서를 관리합니다."
    info "도메인이 설정되면 자동으로 HTTPS가 활성화됩니다."
    info "Caddyfile에서 도메인을 설정해주세요."
}

# 로그 순환 설정
setup_logrotate() {
    log "로그 순환 설정 중..."
    
    # 애플리케이션 로그 로테이트 설정
    sudo tee /etc/logrotate.d/certis << EOF > /dev/null
$LOG_DIR/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    copytruncate
    create 644 ubuntu ubuntu
}
EOF
    
    # Docker 로그 로테이트 설정
    sudo tee /etc/logrotate.d/docker-certis << EOF > /dev/null
/var/lib/docker/containers/*/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
    maxsize 100M
}
EOF
    
    log "로그 순환 설정 완료!"
}

# 메인 실행 함수
main() {
    log "======================================"
    log "CERT-IS 프로덕션 환경 설정을 시작합니다"
    log "======================================"
    
    check_docker_installation
    install_production_packages
    create_production_directories
    setup_fail2ban
    install_log_management_scripts
    setup_crontab
    setup_firewall
    setup_logrotate
    check_aws_cli
    setup_ssl_info
    create_s3_bucket
    
    log "======================================"
    log "프로덕션 환경 설정이 완료되었습니다!"
    log "======================================"
    
    info "다음 단계를 진행하세요:"
    echo "1. AWS 자격 증명 설정: aws configure"
    echo "2. .env.prod 파일 설정"
    echo "3. 도메인 설정 (Caddyfile에서)"
    echo "4. application-prod.yml 파일 배치"
    echo "5. 애플리케이션 배포: make was"
    echo ""
    warning "현재 터미널에서는 docker 명령어에 sudo가 필요합니다."
    warning "그룹 권한을 적용하려면 재로그인하거나 'newgrp docker' 실행하세요."
    echo ""
    info "설치된 주요 구성요소:"
    echo "- 로그 모니터링: $SCRIPT_DIR/log_monitor.sh"
    echo "- 로그 아카이빙: $SCRIPT_DIR/archive_logs.sh"
    echo "- 시스템 모니터링: $SCRIPT_DIR/system_check.sh"
    echo "- Fail2Ban 보안 설정"
    echo "- UFW 방화벽 설정"
    echo "- 자동 로그 순환"
    echo "- S3 Glacier 아카이빙 준비"
}

# 스크립트 실행
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi