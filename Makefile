.PHONY: airlockd airlockd-arm64 image clean tidy test

BIN := bin
PKG := github.com/emdzej/airlock/cmd/airlockd

# Version — prefer `git describe` (picks up tags), fall back to the value
# baked into cmd/airlockd/main.go if git isn't available.
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)
LDFLAGS := -s -w -X main.version=$(VERSION)

airlockd:
	@mkdir -p $(BIN)
	go build -trimpath -ldflags="$(LDFLAGS)" -o $(BIN)/airlockd $(PKG)

airlockd-arm64:
	@mkdir -p $(BIN)
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="$(LDFLAGS)" -o $(BIN)/airlockd.arm64 $(PKG)

image: airlockd-arm64
	./image/pi-gen/build.sh

test:
	go test ./... -race

tidy:
	go mod tidy

clean:
	rm -rf $(BIN) dist
