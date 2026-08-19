.PHONY: test
test:
	go test ./...

.PHONY: check
check:
	@unformatted=$$(gofmt -l internal); \
	if [ -n "$$unformatted" ]; then \
		echo "gofmt needed for:"; echo "$$unformatted"; exit 1; \
	fi
	go vet ./...
	go test ./...
	terraform -chdir=terraform fmt -check -recursive

.PHONY: fmt
fmt:
	gofmt -w internal
	terraform -chdir=terraform fmt -recursive
