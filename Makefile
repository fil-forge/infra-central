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

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

AWS_REGION  ?= us-east-2
AWS_ACCOUNT ?= $(shell aws sts get-caller-identity --query Account --output text)
ECR_REPO    ?= forge-central/provision
ECR_HOST    := $(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com
IMAGE       := $(ECR_HOST)/$(ECR_REPO)

# Where `make publish` records the digest. The file is committed: the stage
# plans in HCP, which sees only what is in version control. Prod pins its digest
# in a committed terraform.tfvars, copied from dev when a change is promoted.
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
	@digest=$$(jq -r '."containerimage.digest"' $(METADATA)); \
	  if [[ -z "$$digest" || "$$digest" == "null" ]]; then \
	    echo "no digest in $(METADATA); did the push succeed?" >&2; exit 1; \
	  fi; \
	  printf 'provision_image_digest = "%s"\n' "$$digest" > $(TFVARS); \
	  echo; \
	  echo "  image  $(IMAGE)@$$digest"; \
	  echo "  wrote  $(TFVARS)"; \
	  echo; \
	  echo "Commit $(TFVARS) so the HCP run for $(STAGE) picks up the new image."

.PHONY: builder
builder:
	@docker buildx inspect $(BUILDER) >/dev/null 2>&1 \
	  || docker buildx create --name $(BUILDER) --driver docker-container

.PHONY: login
login:
	aws ecr get-login-password --region $(AWS_REGION) \
	  | docker login --username AWS --password-stdin $(ECR_HOST)

.PHONY: test
test:
	go test ./...

.PHONY: check
check:
	@unformatted=$$(gofmt -l cmd internal); \
	if [ -n "$$unformatted" ]; then \
		echo "gofmt needed for:"; echo "$$unformatted"; exit 1; \
	fi
	go vet ./...
	go test ./...
	terraform -chdir=terraform fmt -check -recursive

.PHONY: fmt
fmt:
	gofmt -w cmd internal
	terraform -chdir=terraform fmt -recursive
