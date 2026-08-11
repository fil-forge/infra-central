# Build and publish the provision Lambda image.
#
# The image is pushed by digest and carries no tag at all. The digest is derived
# from the image itself, so it is correct whether or not anything is committed,
# and an identical rebuild produces no diff in the stack. A git SHA names the last
# commit rather than the code that was just built, so two builds against a dirty
# tree would claim the same tag; nothing reads a tag here, so there is none.
#
# There is no CI for this yet: an operator runs the target on their own machine
# with credentials for the target account, then commits the digest it writes.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

AWS_REGION  ?= us-east-2
AWS_ACCOUNT ?= $(shell aws sts get-caller-identity --query Account --output text)
ECR_REPO    ?= forge-central/provision
ECR_HOST    := $(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com
IMAGE       := $(ECR_HOST)/$(ECR_REPO)

# Where `make publish` records the digest: the stage's own Pulumi config, which is
# committed. Prod's digest is set the same way, copied from dev when a change is
# promoted rather than written by whatever was built last.
STAGE       ?= dev
PLATFORM    := pulumi/platform
STACK_CONF  := $(PLATFORM)/Pulumi.$(STAGE).yaml
DIGEST_KEY  := forge-central:provisionImageDigest

METADATA    := build/metadata.json

# Docker Desktop's default builder uses the `docker` driver, which cannot push
# by digest. A dedicated docker-container builder can, and it also cross-builds
# for arm64 from any host.
BUILDER     ?= forge-central

# Lambda reads only a single Docker Image Manifest V2 Schema 2. Left to itself
# buildx writes OCI media types and attaches a provenance attestation, which
# turns the pushed digest into a manifest index; Lambda rejects both.
.PHONY: publish
publish: login builder
	docker buildx build \
	  --builder $(BUILDER) \
	  --platform linux/arm64 \
	  --file build/provision.Dockerfile \
	  --provenance=false \
	  --sbom=false \
	  --output type=image,name=$(IMAGE),push=true,push-by-digest=true,name-canonical=true,oci-mediatypes=false \
	  --metadata-file $(METADATA) \
	  .
	@digest=$$(jq -r '."containerimage.digest"' $(METADATA)); \
	  if [[ -z "$$digest" || "$$digest" == "null" ]]; then \
	    echo "no digest in $(METADATA); did the push succeed?" >&2; exit 1; \
	  fi; \
	  pulumi -C $(PLATFORM) config set --stack $(STAGE) $(DIGEST_KEY) "$$digest"; \
	  echo; \
	  echo "  image  $(IMAGE)@$$digest"; \
	  echo "  wrote  $(STACK_CONF)"; \
	  echo; \
	  echo "Commit $(STACK_CONF), then \`pulumi -C $(PLATFORM) up --stack $(STAGE)\`."

.PHONY: builder
builder:
	@docker buildx inspect $(BUILDER) >/dev/null 2>&1 \
	  || docker buildx create --name $(BUILDER) --driver docker-container

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

# Check a deployed stage over public HTTPS. Not part of `check` or `test`, which
# have to keep passing with no stage deployed and no network.
.PHONY: smoke
smoke:
	scripts/smoke-test.sh $(STAGE)

# The infrastructure is Go too, so one formatter and one test runner cover the
# whole repository. `go test ./...` includes the Pulumi components, which build
# against a mocked resource monitor and need no credentials or network.
.PHONY: check
check:
	gofmt -l cmd internal pulumi
	go vet ./...
	go test ./...

.PHONY: fmt
fmt:
	gofmt -w cmd internal pulumi
