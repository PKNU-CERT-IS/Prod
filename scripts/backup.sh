#!/bin/bash

# 자동 백업 스크립트
# Cron으로 매일 새벽 2시에 실행: 0 2 * * * /home/ubuntu/scripts/backup.sh

set -e

BACKUP_DIR="/home/ubuntu/backups"
APP_DIR="/home/ubuntu/app"
LOG_FILE="/home/ubuntu/logs/backup.log"
RETENTION_DAYS=7  # 백업 보관 기간 (일)
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="backup_$DATE"

# AWS CLI 설정 (S3 백업용, 선택사항)
AWS_BUCKET="your-backup-bucket"  # 실제 S3 버킷명으로 변경
AWS_REGION="ap-northeast-2"

# 로그 함수
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# 백업 디렉터리 생성
create_backup_dir() {
    mkdir -p "$BACKUP_DIR/$BACKUP_NAME"
    log "Created backup directory: $BACKUP_DIR/$BACKUP_NAME"
}

# 데이터베이스 백업
backup_database() {
    log "Starting PostgreSQL backup..."
    
    if docker ps | grep -q "certis-postgresql"; then
        # SQL 덤프 생성
        docker exec certis-postgresql pg_dump \
            -U certis_user \
            -d certis_db \
            --verbose \
            --format=custom \
            --compress=9 > "$BACKUP_DIR/$BACKUP_NAME/database.dump"
        
        # 추가 텍스트 백업 (복원 용이성)
        docker exec certis-postgresql pg_dump \
            -U certis_user \
            -d certis_db \
            --verbose > "$BACKUP_DIR/$BACKUP_NAME/database.sql"
            
        log "PostgreSQL backup completed"
    else
        log "WARNING: PostgreSQL container not found"
    fi
}

# Redis 백업
backup_redis() {
    log "Starting Redis backup..."
    
    if docker ps | grep -q "certis-redis"; then
        # Redis 데이터 백업
        docker exec certis-redis redis-cli BGSAVE
        sleep 10  # BGSAVE 완료 대기
        
        # RDB 파일 복사
        docker cp certis-redis:/data/dump.rdb "$BACKUP_DIR/$BACKUP_NAME/"
        
        # Redis 설정 백업
        docker exec certis-redis cat /usr/local/etc/redis/redis.conf > "$BACKUP_DIR/$BACKUP_NAME/redis.conf" 2>/dev/null || true
        
        log "Redis backup completed"
    else
        log "WARNING: Redis container not found"
    fi
}

# 애플리케이션 파일 백업
backup_application() {
    log "Starting application files backup..."
    
    # 중요한 설정 파일들 백업
    tar -czf "$BACKUP_DIR/$BACKUP_NAME/app_configs.tar.gz" \
        -C "$APP_DIR" \
        docker-compose-prod.yml \
        docker-compose-dev.yml \
        Makefile \
        BE/.env.prod \
        BE/.env.dev \
        Caddy/Caddyfile \
        2>/dev/null || log "Some config files not found, continuing..."
    
    # 로그 파일 백업 (최근 7일)
    find /home/ubuntu/logs -name "*.log" -mtime -7 -exec cp {} "$BACKUP_DIR/$BACKUP_NAME/" \;
    
    log "Application files backup completed"
}

# Docker 볼륨 백업
backup_docker_volumes() {
    log "Starting Docker volumes backup..."
    
    # PostgreSQL 데이터 볼륨
    if [ -d "/var/data/postgresql" ]; then
        tar -czf "$BACKUP_DIR/$BACKUP_NAME/postgresql_data.tar.gz" \
            -C /var/data postgresql/
    fi
    
    # Redis 데이터 볼륨
    if [ -d "/var/data/redis" ]; then
        tar -czf "$BACKUP_DIR/$BACKUP_NAME/redis_data.tar.gz" \
            -C /var/data redis/
    fi
    
    log "Docker volumes backup completed"
}

# 시스템 정보 백업
backup_system_info() {
    log "Collecting system information..."
    
    # 시스템 정보
    {
        echo "=== System Information ==="
        uname -a
        echo ""
        echo "=== Docker Version ==="
        docker version
        echo ""
        echo "=== Docker Compose Version ==="
        docker compose version
        echo ""
        echo "=== Running Containers ==="
        docker ps -a
        echo ""
        echo "=== Docker Images ==="
        docker images
        echo ""
        echo "=== Disk Usage ==="
        df -h
        echo ""
        echo "=== Memory Usage ==="
        free -h
        echo ""
        echo "=== Network Configuration ==="
        ip addr show
        echo ""
    } > "$BACKUP_DIR/$BACKUP_NAME/system_info.txt"
    
    log "System information collected"
}

# S3에 백업 업로드 (선택사항)
upload_to_s3() {
    if command -v aws &> /dev/null && [ ! -z "$AWS_BUCKET" ]; then
        log "Uploading backup to S3..."
        
        tar -czf "$BACKUP_DIR/${BACKUP_NAME}.tar.gz" -C "$BACKUP_DIR" "$BACKUP_NAME"
        
        aws s3 cp "$BACKUP_DIR/${BACKUP_NAME}.tar.gz" \
            "s3://$AWS_BUCKET/backups/" \
            --region "$AWS_REGION"
            
        if [ $? -eq 0 ]; then
            log "Backup uploaded to S3 successfully"
            # 로컬 압축 파일 삭제
            rm -f "$BACKUP_DIR/${BACKUP_NAME}.tar.gz"
        else
            log "Failed to upload backup to S3"
        fi
    else
        log "AWS CLI not configured or S3 bucket not specified, skipping S3 upload"
    fi
}

# 오래된 백업 정리
cleanup_old_backups() {
    log "Cleaning up old backups (older than $RETENTION_DAYS days)..."
    
    find "$BACKUP_DIR" -type d -name "backup_*" -mtime +$RETENTION_DAYS -exec rm -rf {} \; 2>/dev/null || true
    
    # S3에서도 오래된 백업 정리 (선택사항)
    if command -v aws &> /dev/null && [ ! -z "$AWS_BUCKET" ]; then
        CUTOFF_DATE=$(date -d "$RETENTION_DAYS days ago" +%Y-%m-%d)
        aws s3 ls "s3://$AWS_BUCKET/backups/" | while read -r line; do
            backup_date=$(echo $line | awk '{print $1}')
            backup_file=$(echo $line | awk '{print $4}')
            
            if [[ "$backup_date" < "$CUTOFF_DATE" ]]; then
                aws s3 rm "s3://$AWS_BUCKET/backups/$backup_file"
                log "Removed old backup from S3: $backup_file"
            fi
        done
    fi
    
    log "Old backups cleanup completed"
}

# 백업 검증
verify_backup() {
    log "Verifying backup integrity..."
    
    local backup_path="$BACKUP_DIR/$BACKUP_NAME"
    
    # 백업 파일 존재 확인
    if [ -f "$backup_path/database.dump" ]; then
        log "✓ Database dump exists"
    else
        log "✗ Database dump missing"
    fi
    
    if [ -f "$backup_path/dump.rdb" ]; then
        log "✓ Redis dump exists"
    else
        log "✗ Redis dump missing"
    fi
    
    # 백업 크기 확인
    backup_size=$(du -sh "$backup_path" | cut -f1)
    log "Backup size: $backup_size"
    
    log "Backup verification completed"
}

# 메인 실행
main() {
    log "========================================="
    log "Starting backup process: $BACKUP_NAME"
    log "========================================="
    
    create_backup_dir
    backup_database
    backup_redis
    backup_application
    backup_docker_volumes
    backup_system_info
    verify_backup
    upload_to_s3
    cleanup_old_backups
    
    log "========================================="
    log "Backup process completed successfully"
    log "Backup location: $BACKUP_DIR/$BACKUP_NAME"
    log "========================================="
}

# 스크립트 실행
main