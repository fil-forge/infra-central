# Build and publish the provision Lambda image.
#
# The image is pushed by digest and carries no tag at all. The digest is derived
# from the image itself, so it is correct whether or not anything is committed,
# and an identical rebuild produces no Terraform diff. A git SHA names the last
# commit rather than the code that was just built, so two builds against a dirty
# tree would claim the same tag; nothing reads a tag here, so there is none.
#
# There is no CI for this yet: an operator runs the target on their own machine
# with credentials for the target account, then commits the digest it writes.

# .SHELLFLAGS only takes effect on GNU Make 3.82+. macOS ships 3.81 (Apple
# stopped updating make over the license change) and silently ignores it, so
# a recipe that pipes or chains commands sets `set -euo pipefail` itself
# rather than depending on this line.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# AWS_ACCOUNT and its derivatives expand lazily so that only the targets that
# reference them (publish, login) call the AWS CLI; `make test` and `make
# check` stay offline.
AWS_REGION  ?= us-east-2
AWS_ACCOUNT ?= $(shell aws sts get-caller-identity --query Account --output text)
ECR_REPO    ?= forge-central/provision
ECR_HOST    = $(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com
IMAGE       = $(ECR_HOST)/$(ECR_REPO)

# Where `make publish` records the digest. The file is committed: the stage is
# planned by a workflow, which sees only what is in version control. Prod pins its
# digest in a committed terraform.tfvars, copied from dev when a change is
# promoted.
STAGE       ?= dev
TFVARS      := terraform/envs/$(STAGE)/platform/image.auto.tfvars

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
	@set -euo pipefail; \
	  digest=$$(jq -r '."containerimage.digest"' $(METADATA)); \
	  if [[ -z "$$digest" || "$$digest" == "null" ]]; then \
	    echo "no digest in $(METADATA); did the push succeed?" >&2; exit 1; \
	  fi; \
	  mkdir -p $(dir $(TFVARS)); \
	  printf 'provision_image_digest = "%s"\n' "$$digest" > $(TFVARS); \
	  echo; \
	  echo "  image  $(IMAGE)@$$digest"; \
	  echo "  wrote  $(TFVARS)"; \
	  echo; \
	  echo "Commit $(TFVARS) so the deploy workflow for $(STAGE) picks up the new image."

.PHONY: builder
builder:
	@docker buildx inspect $(BUILDER) >/dev/null 2>&1 \
	  || docker buildx create --name $(BUILDER) --driver docker-container

.PHONY: login
login:
	set -euo pipefail; \
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

# Mint a regional appliance's unseal credential. The region's transit key must
# already exist, which means its label committed to appliance_regions and merged.
#
#   make mint-appliance-token REGION=us-east-9 NODE_IP=203.0.113.7
#   make mint-appliance-token REGION=us-east-9 NODE_IP=203.0.113.7 TOKEN_ARGS=--reissue
REGION     ?=
NODE_IP    ?=
TOKEN_ARGS ?=

.PHONY: mint-appliance-token
mint-appliance-token:
	scripts/mint-appliance-token.sh --stage $(STAGE) --region $(REGION) --node-ip $(NODE_IP) $(TOKEN_ARGS)

# Register an appliance with sprue, hilt and the delegator, and return the
# delegation its Ingot needs. Run it once the appliance has provisioned its keys.
#
#   make onboard-appliance REGION=us-east-9 PIRI_DID=did:key:… \
#     PIRI_URL=https://piri.dev.forge-sandbox.fil.one \
#     PIRI_PROOF=piri-proof.txt
PIRI_DID      ?=
PIRI_URL      ?=
PIRI_PROOF    ?=
ONBOARD_ARGS  ?=

.PHONY: onboard-appliance
onboard-appliance:
	scripts/onboard-appliance.sh --stage $(STAGE) --region $(REGION) \
	  --piri-did $(PIRI_DID) --piri-url $(PIRI_URL) \
	  $(if $(PIRI_PROOF),--piri-proof-file $(PIRI_PROOF),) $(ONBOARD_ARGS)

# Remove a region's Ingot identity from hilt and SSM, so it can be onboarded
# again under a different DID. Run it before re-onboarding, or the onboard phase
# returns the delegation it issued the first time.
#
#   make retire-region STAGE=dev REGION=us-east-9
RETIRE_ARGS ?=

.PHONY: retire-region
retire-region:
	scripts/retire-region.sh --stage $(STAGE) --region $(REGION) $(RETIRE_ARGS)

.PHONY: test
test:
	go test ./...

# Check a deployed stage over public HTTPS. Not part of `check` or `test`, which
# have to keep passing with no stage deployed and no network.
.PHONY: smoke
smoke:
	scripts/smoke-test.sh $(STAGE)

# Scripts are discovered rather than listed, so one added under scripts/ is checked
# without the recipe being edited. Only tracked files: an untracked script is skipped
# here and caught by CI, which checks out the tree. xargs -r so shellcheck is never
# invoked with no arguments, where it would read stdin and hang.
.PHONY: check
check:
	@unformatted=$$(gofmt -l cmd internal); \
	if [ -n "$$unformatted" ]; then \
		echo "gofmt needed for:"; echo "$$unformatted"; exit 1; \
	fi
	go vet ./...
	go test ./...
	tofu -chdir=terraform fmt -check -recursive
	set -o pipefail; git ls-files -z '*.sh' | xargs -0 -r shellcheck

.PHONY: fmt
fmt:
	gofmt -w cmd internal
	tofu -chdir=terraform fmt -recursive
