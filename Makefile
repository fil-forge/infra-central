# Build and publish the forge-provision Lambda image.
#
# The deploy identifier is the image manifest digest that ECR returns on push,
# never a git SHA. A git SHA names the last commit rather than the code you just
# built, so two different builds against a dirty tree would claim the same tag.
# A digest is derived from the image itself, so it is correct whether or not
# anything is committed, and an identical rebuild produces no Terraform diff.
#
# The same target runs on a developer's machine and in CI. CI reaches ECR
# through GitHub OIDC rather than long-lived keys.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

AWS_REGION  ?= us-east-2
AWS_ACCOUNT ?= $(shell aws sts get-caller-identity --query Account --output text)
ECR_REPO    ?= forge-provision
ECR_HOST    := $(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com
IMAGE       := $(ECR_HOST)/$(ECR_REPO)

# Where `make publish` records the digest for the dev iteration loop. Gitignored
# and per-developer; prod pins its digest in a committed terraform.tfvars.
STAGE       ?= dev
TFVARS      := terraform/envs/$(STAGE)/platform/image.auto.tfvars

METADATA    := build/metadata.json
GIT_SHA     := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

.PHONY: publish
publish: login
	docker buildx build \
	  --platform linux/arm64 \
	  --file build/provision.Dockerfile \
	  --tag $(IMAGE):sha-$(GIT_SHA) \
	  --metadata-file $(METADATA) \
	  --push \
	  .
	@digest=$$(jq -r '."containerimage.digest"' $(METADATA)); \
	  if [[ -z "$$digest" || "$$digest" == "null" ]]; then \
	    echo "no digest in $(METADATA); did the push succeed?" >&2; exit 1; \
	  fi; \
	  printf 'provision_image_digest = "%s"\n' "$$digest" > $(TFVARS); \
	  echo; \
	  echo "  image  $(IMAGE)@$$digest"; \
	  echo "  tag    $(IMAGE):sha-$(GIT_SHA)  (for browsing ECR; Terraform ignores it)"; \
	  echo "  wrote  $(TFVARS)"; \
	  echo; \
	  echo "For prod, commit this line to terraform/envs/prod/platform/terraform.tfvars:"; \
	  printf '    provision_image_digest = "%s"\n' "$$digest"

.PHONY: login
login:
	aws ecr get-login-password --region $(AWS_REGION) \
	  | docker login --username AWS --password-stdin $(ECR_HOST)

# Move USDFC into the payer's FilecoinPay account. Signing happens inside the
# provision Lambda, so the payer key never leaves AWS.
#
# Amounts are overridable:
#   make fund-payer STAGE=dev DEPOSIT=5
#   make fund-payer FUND_ARGS="--rate-allowance 0.2 --force-deposit"
FUND_ARGS ?=
DEPOSIT   ?= 3

.PHONY: fund-payer
fund-payer:
	scripts/fund-payer.sh --stage $(STAGE) --deposit $(DEPOSIT) $(FUND_ARGS)

.PHONY: test
test:
	go test ./...

.PHONY: check
check:
	gofmt -l cmd internal
	go vet ./...
	go test ./...
	terraform -chdir=terraform fmt -check -recursive

.PHONY: fmt
fmt:
	gofmt -w cmd internal
	terraform -chdir=terraform fmt -recursive
