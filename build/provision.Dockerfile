# Lambda container image for the provision function.
#
# Built and pushed by `make publish`, from CI on merge and from a developer's
# machine while iterating. Terraform never builds it; it only references the
# resulting manifest digest.

FROM golang:1.25-bookworm AS build

WORKDIR /src

# Dependency layer first, so editing Go source does not re-download modules.
COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd
COPY internal ./internal

# -trimpath keeps absolute build paths out of the binary, so the same source
# produces the same bytes regardless of where it was built. That matters here:
# the image digest is the deploy identifier, and a path baked into the binary
# would change it for no reason.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -trimpath -ldflags="-s -w" -o /bootstrap ./cmd/provision

FROM public.ecr.aws/lambda/provided:al2023

# The name is the runtime's, not ours: an OS-only runtime starts a function by
# executing a file called exactly bootstrap. The command stays cmd/provision.
COPY --from=build /bootstrap ${LAMBDA_RUNTIME_DIR}/bootstrap

CMD [ "bootstrap" ]
