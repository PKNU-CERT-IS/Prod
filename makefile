COMPOSE_FILE		    := docker-compose-prod.yml
COMPOSE_DEV_FILE		:= docker-compose-dev.yml

all:
	DOCKER_BUILDKIT=1 docker compose -f $(COMPOSE_FILE) up --build -d

dev:
	DOCKER_BUILDKIT=1 docker compose -f $(COMPOSE_DEV_FILE) up --build -d

clean:
	docker compose -f $(COMPOSE_FILE) down

fclean:
	docker compose -f $(COMPOSE_FILE) down --rmi all --volumes --remove-orphans
	docker system prune --all --volumes --force

re:
	make fclean
	make all

dev-clean:
	docker compose -f $(COMPOSE_DEV_FILE) down

dev-fclean:
	docker compose -f $(COMPOSE_DEV_FILE) down --rmi all --volumes --remove-orphans
	docker system prune --all --volumes --force

dev-re:
	make fclean
	make all


.PHONY: all clean fclean re dev-clean dev-fclean dev-re