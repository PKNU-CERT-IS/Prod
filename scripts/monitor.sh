#!/bin/bash

# 서버 모니터링 스크립트
# Cron으로 5분마다 실행 권장: */5 * * * * /home/ubuntu/scripts/monitor.sh

LOG_FILE="/home/ubuntu/logs/monitor.log"
ALERT_EMAIL="admin@yourdomain.com"  # 실제 이메일로 변경
WEBHOOK_URL=""  # Slack 웹훅 URL (선택사항)

# 로그 함수
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
}

# 알림 함수
send_alert() {
    local message="$1"
    log "ALERT: $message"
    
    # 이메일 알림 (sendmail 설치 필요)
    if command -v sendmail &> /dev/null; then
        echo "Subject: Server Alert - $(hostname)
        
$message" | sendmail "$ALERT_EMAIL"
    fi
    
    # Slack 알림 (선택사항)
    if [ ! -z "$WEBHOOK_URL" ]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"🚨 Server Alert: $message\"}" \
            "$WEBHOOK_URL"
    fi
}

# 시스템 리소스 체크
check_system_resources() {
    # 메모리 사용률 체크 (90% 이상시 알림)
    MEMORY_USAGE=$(free | grep Mem | awk '{printf("%.0f", $3/$2 * 100)}')
    if [ $MEMORY_USAGE -gt 90 ]; then
        send_alert "High memory usage: ${MEMORY_USAGE}%"
    fi
    
    # 디스크 사용률 체크 (85% 이상시 알림)
    DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ $DISK_USAGE -gt 85 ]; then
        send_alert "High disk usage: ${DISK_USAGE}%"
    fi
    
    # CPU 로드 평균 체크
    LOAD_AVG=$(uptime | awk -F'load average:' '{ print $2 }' | awk '{ print $1 }' | sed 's/,//')
    CPU_CORES=$(nproc)
    LOAD_THRESHOLD=$(echo "$CPU_CORES * 2" | bc)
    
    if (( $(echo "$LOAD_AVG > $LOAD_THRESHOLD" | bc -l) )); then
        send_alert "High CPU load: $LOAD_AVG (threshold: $LOAD_THRESHOLD)"
    fi
}

# Docker 컨테이너 상태 체크
check_docker_containers() {
    local required_containers=("certis-backend" "certis-postgresql" "certis-redis" "certis-caddy")
    
    for container in "${required_containers[@]}"; do
        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            send_alert "Container $container is not running"
        else
            # 컨테이너 헬스체크
            health=$(docker inspect --format='{{.State.Health.Status}}' $container 2>/dev/null || echo "no-healthcheck")
            if [ "$health" = "unhealthy" ]; then
                send_alert "Container $container is unhealthy"
            fi
        fi
    done
}

# 서비스 응답 체크
check_service_health() {
    # Backend API 체크
    if ! curl -f http://localhost:8080/actuator/health > /dev/null 2>&1; then
        send_alert "Backend API health check failed"
    fi
    
    # 웹사이트 응답 체크
    if ! curl -f http://localhost:80 > /dev/null 2>&1; then
        send_alert "Website health check failed"
    fi
    
    # HTTPS 인증서 만료일 체크 (30일 이내)
    if command -v openssl &> /dev/null; then
        CERT_DAYS=$(echo | openssl s_client -servername yourdomain.com -connect yourdomain.com:443 2>/dev/null | openssl x509 -noout -dates | grep notAfter | cut -d= -f2)
        if [ ! -z "$CERT_DAYS" ]; then
            DAYS_LEFT=$(( ($(date -d "$CERT_DAYS" +%s) - $(date +%s)) / 86400 ))
            if [ $DAYS_LEFT -lt 30 ]; then
                send_alert "SSL certificate expires in $DAYS_LEFT days"
            fi
        fi
    fi
}

# 로그 파일 크기 체크
check_log_files() {
    find /home/ubuntu/logs -name "*.log" -size +100M -exec basename {} \; | while read logfile; do
        send_alert "Log file $logfile is larger than 100MB"
    done
}

# 메인 실행
main() {
    log "Starting monitoring check..."
    
    check_system_resources
    check_docker_containers  
    check_service_health
    check_log_files
    
    log "Monitoring check completed"
    
    # 상태 요약 (정상시에도 기록)
    echo "=== System Status $(date) ===" >> $LOG_FILE
    echo "Memory: ${MEMORY_USAGE:-0}%" >> $LOG_FILE
    echo "Disk: ${DISK_USAGE:-0}%" >> $LOG_FILE
    echo "Load: ${LOAD_AVG:-0}" >> $LOG_FILE
    echo "Containers: $(docker ps --format '{{.Names}}' | tr '\n' ' ')" >> $LOG_FILE
    echo "================================" >> $LOG_FILE
}

# 스크립트 실행
main