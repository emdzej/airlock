.PHONY: airlockd airlockd-arm64 image clean tidy test fmt vet lint

BIN := bin
PKG := github.com/emdzej/airlock/cmd/airlockd

# Version — prefer `git describe` (picks up tags), fall back to the value
# baked into cmd/airlockd/main.go if git isn't available.
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)
LDFLAGS := -s -w -X main.version=$(VERSION)

# Shell scripts checked by `make lint` (same set as CI).
SHELL_SCRIPTS := $(shell git ls-files -- 'scripts/*.sh' 'image/pi-gen/*.sh' 'companion/mac/*.sh') \
	image/pi-gen/stage-airlock/07-ssh-host-keys/files/usr/local/sbin/airlock-ssh-host-keys

airlockd:
	@mkdir -p $(BIN)
	go build -trimpath -ldflags="$(LDFLAGS)" -o $(BIN)/airlockd $(PKG)

airlockd-arm64:
	@mkdir -p $(BIN)
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="$(LDFLAGS)" -o $(BIN)/airlockd.arm64 $(PKG)

# build.sh (re)builds the arm64 binary itself.
image:
	./image/pi-gen/build.sh

test:
	go test ./... -race

fmt:
	gofmt -w .

vet:
	go vet ./...

# gofmt check + vet + shellcheck — what CI runs, minus the tests.
lint: vet
	@test -z "$$(gofmt -l .)" || { echo "gofmt needed:"; gofmt -l .; exit 1; }
	shellcheck $(SHELL_SCRIPTS)

tidy:
	go mod tidy

clean:
	rm -rf $(BIN) dist
