COMPOSE_WAS_FILE		:= docker-compose-prod-was.yml
COMPOSE_DB_FILE		    := docker-compose-prod-db.yml
COMPOSE_DEV_FILE		:= docker-compose-dev.yml

was:
	DOCKER_BUILDKIT=1 docker compose -f $(COMPOSE_WAS_FILE) up --build -d

was-clean:
	docker compose -f $(COMPOSE_WAS_FILE) down

was-fclean:
	docker compose -f $(COMPOSE_WAS_FILE) down --rmi all --volumes --remove-orphans
	docker system prune --all --volumes --force

db:
	DOCKER_BUILDKIT=1 docker compose -f $(COMPOSE_DB_FILE) up --build -d

db-clean:
	docker compose -f $(COMPOSE_DB_FILE) down

db-fclean:
	docker compose -f $(COMPOSE_DB_FILE) down --rmi all --volumes --remove-orphans
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