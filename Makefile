# Makefile for Nitro Enclave Development with QEMU VM
# A complete development environment for experimenting with AWS Nitro Enclaves

# CONFIGURATION
VM_IMG=ubuntu-24.04-minimal-cloudimg-amd64.qcow2
BASE_IMG_URL=https://cloud-images.ubuntu.com/minimal/releases/noble/release-20250619/ubuntu-24.04-minimal-cloudimg-amd64.img
BASE_IMG=ubuntu-24.04-minimal-cloudimg-amd64.img
SEED_IMG=seed.img
VM_MEM=1024
VM_CPUS=2
VSOCK_PORT=9000
VSOCK_CID=3
SSH_PORT=2222
KMS_PORT=4566
VM_USER=ubuntu
SSH_KEY=~/.ssh/dev-vm
SSH_PUB_KEY=~/.ssh/dev-vm.pub

# Helper function to find available port
find_available_port = $(shell python3 -c "import socket; s=socket.socket(); s.bind(('', 0)); print(s.getsockname()[1]); s.close()")

.PHONY: help all start-vsock-proxy start-connector setup-vm start-enclave ssh-vm view-logs get-logs build-all clean kill-all

# Default target - show help
help:
	@echo "=== Nitro Enclave Development Environment ==="
	@echo ""
	@echo "Quick Start:"
	@echo "  make start-vsock-proxy  # Start localstack, setup KMS, and run vsock-proxy"
	@echo "  make start-connector    # Start the connector Go application"
	@echo "  make setup-vm           # Boot the QEMU VM"
	@echo "  make start-enclave      # Build and start enclave inside the VM"
	@echo ""
	@echo "VM Interaction:"
	@echo "  make ssh-vm             # SSH into the VM"
	@echo "  make view-logs          # View enclave logs in real-time"
	@echo "  make get-logs           # Copy logs from VM to host"
	@echo ""
	@echo "Development:"
	@echo "  make build-all          # Build all Go applications"
	@echo "  make clean              # Clean up temporary files"
	@echo "  make kill-all           # Stop all services and clean up"
	@echo ""

# Main workflow targets
all: start-vsock-proxy start-connector setup-vm start-enclave

##############################################
# CORE WORKFLOW TARGETS
##############################################

start-vsock-proxy:
	@echo "=== Starting VSOCK Proxy Environment ==="
	@echo "Starting localstack..."
	docker-compose up -d localstack
	@echo "Waiting for localstack to be ready..."
	@sleep 5
	@echo "Setting up KMS..."
	@$(MAKE) setup-kms
	@echo "Building vsock-proxy..."
	@$(MAKE) build-vsock-proxy
	@echo "Starting vsock-proxy..."
	@echo "VSOCK proxy is now running and streaming logs. Press Ctrl+C to stop."
	@$(shell go env GOBIN)/vsock-proxy

start-connector:
	@echo "=== Starting Connector ==="
	@echo "Building connector..."
	@$(MAKE) build-connector
	@echo "Starting connector..."
	@echo "Connector is now running. Enter text to encrypt or type 'exit' to quit."
	@$(shell go env GOBIN)/connector

setup-vm: check-ports kill-qemu build-vm
	@echo "=== Booting QEMU VM ==="
	@echo "Starting VM with cloud-init and vsock..."
	qemu-system-x86_64 \
	  -m $(VM_MEM) \
	  -smp $(VM_CPUS) \
	  -enable-kvm \
	  -cpu host \
	  -drive file=$(VM_IMG),if=virtio,format=qcow2 \
	  -drive file=$(SEED_IMG),format=raw,if=virtio \
	  -netdev user,id=net0,hostfwd=tcp::$(SSH_PORT)-:22,hostfwd=tcp::$(VSOCK_PORT)-:$(VSOCK_PORT) \
	  -device virtio-net-pci,netdev=net0 \
	  -device vhost-vsock-pci,guest-cid=$(VSOCK_CID) \
	  -nographic

start-enclave: build-enclave
	@echo "=== Starting Enclave in VM ==="
	@echo "Copying enclave binary to VM..."
	scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $(SSH_PORT) -i $(SSH_KEY) $(shell go env GOBIN)/enclave $(VM_USER)@localhost:/home/$(VM_USER)/
	@echo "Starting enclave process..."
	ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $(SSH_PORT) -i $(SSH_KEY) $(VM_USER)@localhost "chmod +x /home/$(VM_USER)/enclave && nohup /home/$(VM_USER)/enclave > /home/$(VM_USER)/enclave.log 2>&1 &"
	@echo "Enclave started! Use 'make view-logs' to see logs."

##############################################
# VM INTERACTION TARGETS
##############################################

ssh-vm:
	@echo "=== SSH into VM ==="
	ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $(SSH_PORT) $(VM_USER)@localhost -i $(SSH_KEY)

view-logs:
	@echo "=== Viewing Enclave Logs ==="
	@echo "Tailing enclave logs from VM (Ctrl+C to stop)..."
	ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $(SSH_PORT) -i $(SSH_KEY) $(VM_USER)@localhost "tail -f /home/$(VM_USER)/enclave.log"

get-logs:
	@echo "=== Copying Logs from VM ==="
	@mkdir -p vm-logs
	scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $(SSH_PORT) -i $(SSH_KEY) $(VM_USER)@localhost:/home/$(VM_USER)/*.log ./vm-logs/ 2>/dev/null || echo "No log files found"
	@echo "Logs copied to ./vm-logs/ directory"

##############################################
# BUILD TARGETS
##############################################

build-all: build-enclave build-connector build-vsock-proxy
	@echo "All applications built successfully!"

build-enclave:
	@echo "Building enclave..."
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go install -a -ldflags '-extldflags "-static"' ./cmd/enclave

build-connector:
	@echo "Building connector..."
	go install ./cmd/connector

build-vsock-proxy:
	@echo "Building vsock-proxy..."
	go install ./cmd/vsock-proxy

show-bins:
	@echo "Binaries installed at:"
	@echo "  enclave: $(shell go env GOBIN)/enclave"
	@echo "  connector: $(shell go env GOBIN)/connector"
	@echo "  vsock-proxy: $(shell go env GOBIN)/vsock-proxy"

##############################################
# SETUP AND UTILITY TARGETS
##############################################

setup-kms:
	@echo "Setting up KMS in localstack..."
	docker exec -i localstack awslocal kms create-key --description "Test Dev KMS Key" --key-usage ENCRYPT_DECRYPT --policy file:///etc/localstack/kms-test-policy.json || true
	docker exec -i localstack awslocal kms create-alias --alias-name alias/dev-key --target-key-id $$(docker exec -i localstack awslocal kms list-keys --query "Keys[0].KeyId" --output text) || true

check-ports:
	@echo "Checking if ports are available..."
	@if lsof -i :$(SSH_PORT) > /dev/null 2>&1; then \
		echo "Warning: SSH port $(SSH_PORT) is already in use"; \
	fi
	@if lsof -i :$(VSOCK_PORT) > /dev/null 2>&1; then \
		echo "Warning: VSOCK port $(VSOCK_PORT) is already in use"; \
	fi

kill-qemu:
	@echo "Killing any existing QEMU processes..."
	@-pkill -f "qemu-system-x86_64" || true

build-vm: $(BASE_IMG) create-vm $(SEED_IMG)

$(BASE_IMG):
	@echo "Downloading base VM image..."
	wget -O $(BASE_IMG) $(BASE_IMG_URL)

$(SEED_IMG): cloud-init.yaml $(SSH_PUB_KEY)
	@echo "Creating cloud-init seed image..."
	cp cloud-init.yaml user-data
	sed -i "s|REPLACE_ME_WITH_YOUR_SSH_KEY|$$(cat $(SSH_PUB_KEY))|" user-data
	cloud-localds $(SEED_IMG) user-data

create-vm:
	@echo "Creating writable copy of base VM image..."
	cp $(BASE_IMG) $(VM_IMG)
	qemu-img resize $(VM_IMG) 10G

##############################################
# CLEANUP TARGETS
##############################################

clean:
	@echo "Cleaning up temporary files..."
	rm -f $(SEED_IMG) user-data

kill-all:
	@echo "=== Stopping all development services ==="
	
	@echo "Stopping Docker services..."
	-docker compose down --remove-orphans --timeout 10
	
	@echo "Killing all QEMU processes..."
	@-pkill -f "qemu-system-x86_64" || true
	@-pkill -f "qemu" || true
	
	@echo "Killing Go application processes..."
	@-pkill -f "vsock-proxy" || true
	@-pkill -f "connector" || true
	@-pkill -f "enclave" || true
	
	@echo "Killing processes using our ports..."
	@echo "Checking SSH port $(SSH_PORT)..."
	@-lsof -ti:$(SSH_PORT) | xargs -r kill -9 || true
	@echo "Checking VSOCK port $(VSOCK_PORT)..."
	@-lsof -ti:$(VSOCK_PORT) | xargs -r kill -9 || true
	@echo "Checking KMS port $(KMS_PORT)..."
	@-lsof -ti:$(KMS_PORT) | xargs -r kill -9 || true
	@echo "Checking port 8000 (common vsock port)..."
	@-lsof -ti:8000 | xargs -r kill -9 || true
	
	@echo "Killing any processes with our binary names..."
	@-pgrep -f "vsock-proxy" | xargs -r kill -9 || true
	@-pgrep -f "connector" | xargs -r kill -9 || true
	@-pgrep -f "enclave" | xargs -r kill -9 || true
	
	@echo "Scanning for any other processes using common development ports..."
	@for port in 8000 8001 8002 9000 9001 9002 2222 2223 4566 4567; do \
		if lsof -i :$$port > /dev/null 2>&1; then \
			echo "Found process on port $$port, killing..."; \
			lsof -ti:$$port | xargs -r kill -9 || true; \
		fi; \
	done
	
	@echo "Waiting for processes to terminate..."
	@sleep 3
	
	@echo "Force killing any remaining processes on our ports..."
	@-fuser -k $(SSH_PORT)/tcp 2>/dev/null || true
	@-fuser -k $(VSOCK_PORT)/tcp 2>/dev/null || true
	@-fuser -k $(KMS_PORT)/tcp 2>/dev/null || true
	@-fuser -k 8000/tcp 2>/dev/null || true
	
	@echo "Removing temporary VM artifacts..."
	-rm -f $(VM_IMG) $(SEED_IMG) user-data
	-rm -f $(shell go env GOBIN)/enclave $(shell go env GOBIN)/connector $(shell go env GOBIN)/vsock-proxy 2>/dev/null || true
	
	@echo "Cleaning up any remaining temporary files..."
	-rm -f *.tmp *.log 2>/dev/null || true
	-rm -rf vm-logs/ 2>/dev/null || true
	
	@echo "Checking for any remaining processes..."
	@echo "Checking QEMU processes..."
	@if pgrep -f "qemu" > /dev/null; then \
		echo "Warning: Some QEMU processes may still be running. Use 'pkill -9 -f qemu' to force kill."; \
	else \
		echo "All QEMU processes terminated successfully."; \
	fi
	@echo "Checking Go application processes..."
	@if pgrep -f "vsock-proxy\|connector\|enclave" > /dev/null; then \
		echo "Warning: Some Go processes may still be running. Use 'pkill -9 -f vsock-proxy\|connector\|enclave' to force kill."; \
	else \
		echo "All Go application processes terminated successfully."; \
	fi
	@echo "Checking port usage..."
	@if lsof -i :$(SSH_PORT) > /dev/null 2>&1; then \
		echo "Warning: SSH port $(SSH_PORT) is still in use"; \
	else \
		echo "SSH port $(SSH_PORT) is free"; \
	fi
	@if lsof -i :$(VSOCK_PORT) > /dev/null 2>&1; then \
		echo "Warning: VSOCK port $(VSOCK_PORT) is still in use"; \
	else \
		echo "VSOCK port $(VSOCK_PORT) is free"; \
	fi
	@if lsof -i :$(KMS_PORT) > /dev/null 2>&1; then \
		echo "Warning: KMS port $(KMS_PORT) is still in use"; \
	else \
		echo "KMS port $(KMS_PORT) is free"; \
	fi
	@if lsof -i :8000 > /dev/null 2>&1; then \
		echo "Warning: Port 8000 is still in use"; \
	else \
		echo "Port 8000 is free"; \
	fi
	
	@echo "=== All development resources cleaned up ==="
