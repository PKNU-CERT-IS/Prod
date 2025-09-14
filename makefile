COMPOSE_WAS_FILE		:= docker-compose-prod-was.yml
COMPOSE_DB_FILE		    := docker-compose-prod-db.yml
COMPOSE_DEV_FILE		:= docker-compose-dev.yml

# 환경 변수 파일 경로
ENV_WAS_FILE		:= ./BE/.env.prod
ENV_DB_FILE			:= .env

was:
	bash -c 'set -a && source $(ENV_WAS_FILE) && set +a && DOCKER_BUILDKIT=1 docker compose -f $(COMPOSE_WAS_FILE) up --build -d'

was-clean:
	bash -c 'set -a && source $(ENV_WAS_FILE) && set +a && docker compose -f $(COMPOSE_WAS_FILE) down'

was-fclean:
	bash -c 'set -a && source $(ENV_WAS_FILE) && set +a && docker compose -f $(COMPOSE_WAS_FILE) down --rmi all --volumes --remove-orphans'
	docker system prune --all --volumes --force

db:
	bash -c 'set -a && source $(ENV_DB_FILE) && set +a && DOCKER_BUILDKIT=1 docker compose -f $(COMPOSE_DB_FILE) up --build -d'

db-clean:
	bash -c 'set -a && source $(ENV_DB_FILE) && set +a && docker compose -f $(COMPOSE_DB_FILE) down'

db-fclean:
	bash -c 'set -a && source $(ENV_DB_FILE) && set +a && docker compose -f $(COMPOSE_DB_FILE) down --rmi all --volumes --remove-orphans'
	docker system prune --all --volumes --force
dev:
	DOCKER_BUILDKIT=1 docker compose -f $(COMPOSE_DEV_FILE) up --build -d

dev-clean:
	docker compose -f $(COMPOSE_DEV_FILE) down

dev-fclean:
	docker compose -f $(COMPOSE_DEV_FILE) down --rmi all --volumes --remove-orphans
	docker system prune --all --volumes --force

re:
	make fclean
	make all


.PHONY: was was-clean was-fclean db db-clean db-fclean dev dev-clean dev-fclean re
