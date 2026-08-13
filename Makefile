.PHONY: test
test:
	go test ./...

.PHONY: check
check:
	gofmt -l internal
	go vet ./...
	go test ./...
	terraform -chdir=terraform fmt -check -recursive

.PHONY: fmt
fmt:
	gofmt -w internal
	terraform -chdir=terraform fmt -recursive
