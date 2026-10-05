# Kafka -> KubeMQ migration showcase.
#
#   make CLOUD=gcp preflight      check tools, auth, APIs, quotas
#   make CLOUD=gcp infra-up       operator /32 -> terraform apply (infra) -> .rig/env
#   make CLOUD=gcp addons-up      terraform apply (k8s-addons) -> .rig/env
#   make CLOUD=gcp seed           seed Kafka (RECORDS=500000 default; RECORDS=5000000 full run)
#   make CLOUD=gcp status         quorum, laptop reachability, record counts
#   make kmq-install              kmq CLI at the pinned version
#   make CLOUD=gcp kubemq-install pointer to the kmq deploy steps (prompts/03)
#   make CLOUD=gcp down           pre-destroy -> destroy addons -> destroy infra -> verify-teardown
#   make CLOUD=gcp verify-teardown
#   make leak-scan lint
#
# CLOUD defaults to gcp. TF is terraform or tofu (auto-detected). Every target prints
# what it runs; nothing creates cloud resources without a terraform plan being shown.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

CLOUD ?= gcp
TF ?= $(shell command -v terraform >/dev/null 2>&1 && echo terraform || echo tofu)
RECORDS ?= 500000
export CLOUD TF RECORDS

INFRA  := terraform/$(CLOUD)/infra
ADDONS := terraform/$(CLOUD)/k8s-addons
SCRIPTS := $(wildcard scripts/*.sh scripts/kafka/*.sh) $(wildcard terraform/modules/*/wait-for-*.sh)

ifeq ($(filter $(CLOUD),gcp aws),)
$(error CLOUD must be gcp or aws, got '$(CLOUD)')
endif

.PHONY: help preflight cidr infra-up addons-up env seed status kmq-install kubemq-install \
        pre-destroy down verify-teardown leak-scan lint tf-fmt

help:
	@sed -n '2,15p' Makefile | sed 's/^# \{0,1\}//'

preflight:
	scripts/preflight.sh $(CLOUD)

cidr:
	scripts/operator-cidr.sh $(CLOUD)

# Pins from versions.env are passed as -var so terraform.tfvars never has to repeat them.
KAFKA_VARS = -var kafka_version=$$(. ./versions.env; echo $$KAFKA_VERSION) -var kafka_sha512=$$(. ./versions.env; echo $$KAFKA_SHA512)

infra-up: cidr
	@echo "== $(TF) init+apply in $(INFRA) (you will be shown the plan and asked to confirm) =="
	$(TF) -chdir=$(INFRA) init -input=false
	$(TF) -chdir=$(INFRA) apply $(KAFKA_VARS)
	scripts/write-env.sh $(CLOUD)

# The add-ons root reads the cluster identity from the infra root's outputs, so only the
# license variables (if any) need to be in $(ADDONS)/terraform.tfvars.
ifeq ($(CLOUD),gcp)
ADDONS_VARS = -var project_id=$$($(TF) -chdir=$(INFRA) output -raw project_id) -var cluster_name=$$($(TF) -chdir=$(INFRA) output -raw cluster_name) -var cluster_location=$$($(TF) -chdir=$(INFRA) output -raw cluster_location)
else
ADDONS_VARS = -var region=$$($(TF) -chdir=$(INFRA) output -raw region) -var cluster_name=$$($(TF) -chdir=$(INFRA) output -raw cluster_name)
endif

addons-up:
	@echo "== $(TF) init+apply in $(ADDONS) =="
	$(TF) -chdir=$(ADDONS) init -input=false
	$(TF) -chdir=$(ADDONS) apply $(ADDONS_VARS)
	scripts/write-env.sh $(CLOUD)

env:
	scripts/write-env.sh $(CLOUD)

seed:
	RECORDS=$(RECORDS) scripts/seed.sh $(SEED_ARGS)

status:
	scripts/kafka/verify.sh

kmq-install:
	scripts/kmq-install.sh

kubemq-install: kmq-install
	@echo
	@echo "KubeMQ is installed by the kmq CLI, not by Terraform. Follow prompts/03-install-kmq-and-kubemq.md:"
	@echo "   1. fill the __PLACEHOLDER__ values of kubemq/deploy-input.$(CLOUD).json into .rig/deploy-input.json (prompt 03, step 2)"
	@echo "   kmq deploy prepare --input .rig/deploy-input.json --out .rig/recipe.json"
	@echo "   kmq deploy plan    --input .rig/recipe.json       --out .rig/plan.json"
	@echo "   kmq deploy apply   --plan  .rig/plan.json"
	@echo "   kmq deploy forward --installation <installation_id from .rig/plan.json> --all   (keep running)"
	@echo "   kmq auth login     --installation <installation_id> --all --bootstrap --username admin --new-password-stdin --non-interactive < .rig/admin-password"
	@echo "Run 'kmq deploy --help' first; never invent flags. Templates live in kubemq/, state in .rig/env and .rig/kmq.env."

pre-destroy:
	scripts/pre-destroy.sh

down: pre-destroy
	@echo "== $(TF) destroy in $(ADDONS) =="
	if [ -d "$(ADDONS)" ]; then \
	  $(TF) -chdir=$(ADDONS) init -input=false >/dev/null && \
	  $(TF) -chdir=$(ADDONS) destroy $(ADDONS_VARS) -auto-approve; \
	fi
	@echo "== $(TF) destroy in $(INFRA) =="
	$(TF) -chdir=$(INFRA) init -input=false >/dev/null
	$(TF) -chdir=$(INFRA) destroy $(KAFKA_VARS) -auto-approve
	scripts/verify-teardown.sh $(CLOUD)
	rm -f .rig/env .rig/seed.env .rig/kubeconfig

verify-teardown:
	scripts/verify-teardown.sh $(CLOUD)

leak-scan:
	scripts/leak-scan.sh

tf-fmt:
	$(TF) fmt -check -recursive -diff terraform

lint: tf-fmt leak-scan
	shellcheck -x $(SCRIPTS)
	cd tools/seed && go vet ./... && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o /dev/null .
	@echo "✅ lint ok"
