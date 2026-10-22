.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help up infra cp register workloads ccloud flink status down fmt validate

help: ## Show targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

up: infra cp register workloads ccloud ## Full deploy: infra -> CP -> USM registration -> connectors/apps -> cloud cluster link

infra: ## Terraform: VPC, EKS, S3, PrivateLink, CCloud env + USM service account
	./scripts/infra.sh

cp: ## CFK operator, CP 8.3, USM Agent
	./scripts/deploy-cp.sh

register: ## Register CP Kafka + Connect clusters with USM
	./scripts/register-usm.sh

workloads: ## Connectors (Datagen, S3 sink) + Kafka Streams / consumer apps
	./scripts/deploy-workloads.sh

ccloud: ## Cluster link CP -> CCloud Enterprise, managed Datagen, cloud consumer
	./scripts/deploy-ccloud.sh

flink: ## (optional) CMF + Flink operator + drop-gender SQL job
	./scripts/flink.sh

status: ## Show CP + USM status
	./scripts/status.sh

down: ## Tear everything down
	./scripts/down.sh

fmt: ## terraform fmt
	terraform -chdir=terraform fmt -recursive

validate: ## terraform validate
	terraform -chdir=terraform init -backend=false -input=false >/dev/null && terraform -chdir=terraform validate
