# atmos-eks-platform-aws — Makefile
# Convenience wrappers around the most common atmos workflows.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Default stack to operate on; override with `STACK=plat-platform-usw2-prod ...`
STACK ?= plat-platform-usw2-dev

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

.PHONY: vendor
vendor: ## Pull / refresh vendored Cloud Posse components
	atmos vendor pull

.PHONY: validate
validate: ## Validate all stacks
	atmos validate stacks

.PHONY: describe
describe: ## Describe a stack (STACK=...)
	atmos describe stacks -s $(STACK)

.PHONY: list-components
list-components: ## List components in STACK
	atmos list components -s $(STACK)

.PHONY: list-stacks
list-stacks: ## List all stacks
	atmos list stacks

# ---------------------------------------------------------------------------
# Bootstrap order — run these once, in this order, when first standing up
# a brand-new account.
# ---------------------------------------------------------------------------

.PHONY: bootstrap
bootstrap: ## Bootstrap tfstate-backend, vpc, eks, addons, data, app for STACK
	@echo ">> Bootstrapping $(STACK)"
	atmos terraform apply tfstate-backend            -s $(STACK)
	atmos terraform apply vpc                        -s $(STACK)
	atmos terraform apply dns-primary                -s plat-platform-gbl-dns
	atmos terraform apply eks/cluster                -s $(STACK)
	atmos terraform apply eks/aws-load-balancer-controller -s $(STACK)
	atmos terraform apply eks/external-dns           -s $(STACK)
	atmos terraform apply eks/cert-manager           -s $(STACK)
	atmos terraform apply eks/external-secrets-operator    -s $(STACK)
	atmos terraform apply eks/metrics-server         -s $(STACK)
	atmos terraform apply rds                        -s $(STACK)
	atmos terraform apply three-tier-app             -s $(STACK)

.PHONY: destroy
destroy: ## Tear down STACK in reverse bootstrap order
	atmos terraform destroy three-tier-app           -s $(STACK)
	atmos terraform destroy rds                      -s $(STACK)
	atmos terraform destroy eks/metrics-server       -s $(STACK)
	atmos terraform destroy eks/external-secrets-operator    -s $(STACK)
	atmos terraform destroy eks/cert-manager         -s $(STACK)
	atmos terraform destroy eks/external-dns         -s $(STACK)
	atmos terraform destroy eks/aws-load-balancer-controller -s $(STACK)
	atmos terraform destroy eks/cluster              -s $(STACK)
	atmos terraform destroy vpc                      -s $(STACK)
