#!/bin/bash

# EC2 Ubuntu 24.04에서 Docker Compose 환경 설정 스크립트
# 실행 방법: chmod +x setup-docker-environment.sh && ./setup-docker-environment.sh

set -e  # 에러 발생시 스크립트 종료

echo "========================================="
echo "Docker Compose 환경 설정을 시작합니다..."
echo "========================================="

# 현재 사용자 확인
CURRENT_USER=$(whoami)
echo "현재 사용자: $CURRENT_USER"

# 시스템 업데이트
echo "1. 시스템 패키지 업데이트 중..."
sudo apt update && sudo apt upgrade -y

# 필요한 기본 패키지 설치
echo "2. 필수 패키지 설치 중..."
sudo apt install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    make \
    wget \
    unzip

# Docker 공식 GPG 키 추가
echo "3. Docker GPG 키 추가 중..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Docker 리포지토리 추가
echo "4. Docker 리포지토리 추가 중..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 패키지 인덱스 업데이트
sudo apt update

# Docker Engine 설치
echo "5. Docker Engine 설치 중..."
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start Docker service and enable auto-start at boot
echo "6. Configuring Docker service..."
sudo systemctl start docker
sudo systemctl enable docker

# Add current user to docker group
echo "7. Setting up user permissions..."
sudo usermod -aG docker $CURRENT_USER

# Create data directories (for docker-compose.yml volume mounts)
echo "8. Creating data directories..."
sudo mkdir -p /var/data/postgresql
sudo mkdir -p /var/data/redis

# Set directory permissions (make accessible to docker group)
sudo chown -R $CURRENT_USER:docker /var/data/postgresql
sudo chown -R $CURRENT_USER:docker /var/data/redis
sudo chmod -R 755 /var/data

# Check Docker version
echo "9. Checking installed Docker version..."
docker --version
docker compose version

# Check Docker service status
echo "10. Checking Docker service status..."
sudo systemctl status docker --no-pager

echo "========================================="
echo "Installation completed successfully!"
echo "========================================="
echo ""
echo "Important Notes:"
echo "1. In the current terminal session, you need 'sudo' to use docker commands."
echo "2. To apply docker group permissions, perform one of the following:"
echo "   - Logout and login again"
echo "   - Start a new terminal session"
echo "   - Or execute 'newgrp docker' command"
echo ""
echo "3. The following directories have been created:"
echo "   - /var/data/postgresql (for PostgreSQL data)"
echo "   - /var/data/redis (for Redis data)"
echo ""
echo "Now you can run Docker Compose with the following commands:"
echo "   make all          # Run production environment"
echo "   make dev          # Run development environment"
echo "   make clean        # Stop containers"
echo "   make fclean       # Complete cleanup"
echo ""
echo "To test the installation, run:"
echo "   docker run hello-world"