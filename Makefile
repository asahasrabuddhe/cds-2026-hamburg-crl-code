.PHONY: build check fmt vet test lint clean vm vm-v1 vm-hardened vm-down

BIN := nsdemo

# The binary lands at the repo root because that is where scripts/demo.sh and
# the pre-flight check look for it, and where it is shortest to type on stage.
build:
	go build -o $(BIN) ./cmd/nsdemo

# Everything CI runs, and everything you should run before committing.
check: fmt vet test lint

fmt:
	@out=$$(gofmt -l . ); \
	if [ -n "$$out" ]; then echo "gofmt needed on:"; echo "$$out"; exit 1; fi
	@echo "gofmt: clean"

vet:
	go vet ./...

# internal/subid carries no Linux-specific API on purpose, so its tests run on
# a Mac as well as in the VM. cmd/nsdemo is build-tagged linux and is compiled
# rather than run here.
test:
	go test ./...

lint:
	shellcheck scripts/demo.sh scripts/bench.sh scripts/stage.sh qemu/vm.sh

clean:
	rm -f $(BIN)

# ---------------------------------------------------------------- the VMs ---
# Three variants of one definition. See qemu/README.md.

vm:
	./qemu/vm.sh up primary

vm-v1:
	./qemu/vm.sh up cgroupv1

vm-hardened:
	./qemu/vm.sh up hardened

vm-down:
	./qemu/vm.sh down
