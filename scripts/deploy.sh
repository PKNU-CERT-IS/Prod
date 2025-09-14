#!/bin/bash

# EC2 배포 스크립트
set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 로깅 함수
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# 변수 설정
PROJECT_NAME="certis"
BACKUP_DIR="/backup"
DATA_DIR="/var/data"

log "Starting deployment process..."

# 1. 환경 확인
log "Checking environment..."
if ! command -v docker &> /dev/null; then
    error "Docker is not installed"
fi

if ! command -v docker-compose &> /dev/null; then
    error "Docker Compose is not installed"
fi

# 2. 환경변수 파일 확인
if [ ! -f ".env.prod" ]; then
    error ".env.prod file not found. Please create it first."
fi

# 3. 데이터 디렉토리 생성
log "Creating data directories..."
sudo mkdir -p ${DATA_DIR}/postgresql ${DATA_DIR}/redis
sudo chown -R 999:999 ${DATA_DIR}/postgresql  # PostgreSQL user
sudo chown -R 999:999 ${DATA_DIR}/redis       # Redis user

# 4. 백업 생성 (기존 서비스가 있는 경우)
if docker ps -q -f name=${PROJECT_NAME} | grep -q .; then
    log "Creating backup..."
    mkdir -p ${BACKUP_DIR}/$(date +%Y%m%d_%H%M%S)
    
    # PostgreSQL 백업
    if docker ps -q -f name=${PROJECT_NAME}-postgresql | grep -q .; then
        log "Backing up PostgreSQL..."
        docker exec ${PROJECT_NAME}-postgresql pg_dump -U certis_user certis_db > ${BACKUP_DIR}/$(date +%Y%m%d_%H%M%S)/postgresql.sql || warn "PostgreSQL backup failed"
    fi
    
    # Redis 백업
    if docker ps -q -f name=${PROJECT_NAME}-redis | grep -q .; then
        log "Backing up Redis..."
        docker exec ${PROJECT_NAME}-redis redis-cli BGSAVE || warn "Redis backup failed"
    fi
fi

# 5. 기존 컨테이너 중지 및 제거
log "Stopping existing containers..."
docker-compose -f docker-compose.yml down --remove-orphans || warn "No existing containers to stop"

# 6. 이미지 빌드
log "Building images..."
docker-compose -f docker-compose.yml build --no-cache

# 7. 서비스 시작
log "Starting services..."
docker-compose -f docker-compose.yml up -d

# 8. 헬스체크 대기
log "Waiting for services to be healthy..."
sleep 30

# PostgreSQL 헬스체크
for i in {1..30}; do
    if docker exec ${PROJECT_NAME}-postgresql pg_isready -U certis_user -d certis_db; then
        log "PostgreSQL is healthy"
        break
    fi
    if [ $i -eq 30 ]; then
        error "PostgreSQL health check failed"
    fi
    sleep 5
done

# Redis 헬스체크
for i in {1..30}; do
    if docker exec ${PROJECT_NAME}-redis redis-cli ping | grep -q PONG; then
        log "Redis is healthy"
        break
    fi
    if [ $i -eq 30 ]; then
        error "Redis health check failed"
    fi
    sleep 5
done

# Backend 헬스체크
for i in {1..60}; do
    if docker exec ${PROJECT_NAME}-backend curl -f http://localhost:8080/actuator/health; then
        log "Backend is healthy"
        break
    fi
    if [ $i -eq 60 ]; then
        error "Backend health check failed"
    fi
    sleep 10
done

# 9. 서비스 상태 확인
log "Checking service status..."
docker-compose -f docker-compose.yml ps

# 10. 로그 확인
log "Recent logs:"
docker-compose -f docker-compose.yml logs --tail=10

# 11. 정리 작업
log "Cleaning up unused images..."
docker image prune -f

log "Deployment completed successfully!"
log "Your API server is running at: https://$(grep DOMAIN .env.prod | cut -d'=' -f2)"

# 12. 모니터링 정보 제공
echo ""
log "Useful commands for monitoring:"
echo "  View logs: docker-compose logs -f [service_name]"
echo "  Check status: docker-compose ps"
echo "  Restart service: docker-compose restart [service_name]"
echo "  Scale backend: docker-compose up -d --scale backend=2"
echo ""

# 13. SSL 인증서 확인
log "Checking SSL certificate..."
sleep 5
if command -v curl &> /dev/null; then
    DOMAIN=$(grep DOMAIN .env.prod | cut -d'=' -f2)
    if curl -I https://$DOMAIN 2>/dev/null | head -n 1 | grep -q "200 OK"; then
        log "SSL certificate is working correctly"
    else
        warn "SSL certificate might not be ready yet. It may take a few minutes for Let's Encrypt to issue the certificate."
    fi
fi