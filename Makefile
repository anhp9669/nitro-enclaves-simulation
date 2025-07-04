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
VSOCK_PROXY_PORT=8000
VSOCK_CID=3
SSH_PORT=2222
KMS_PORT=4566
VM_USER=ubuntu
SSH_KEY=~/.ssh/dev-vm
SSH_PUB_KEY=~/.ssh/dev-vm.pub


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
	@VSOCK_PORT=$(VSOCK_PROXY_PORT) ./bin/vsock-proxy

start-connector:
	@echo "=== Starting Connector ==="
	@echo "Building connector..."
	@$(MAKE) build-connector
	@echo "Starting connector..."
	@echo "Connector is now running. Enter text to encrypt or type 'exit' to quit."
	@./bin/connector

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
	scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $(SSH_PORT) -i $(SSH_KEY) ./bin/enclave $(VM_USER)@localhost:/home/$(VM_USER)/
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
	@mkdir -p ./bin
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ./bin/enclave -a -ldflags '-extldflags "-static"' ./cmd/enclave

build-connector:
	@echo "Building connector..."
	@mkdir -p ./bin
	go build -o ./bin/connector ./cmd/connector

build-vsock-proxy:
	@echo "Building vsock-proxy..."
	@mkdir -p ./bin
	go build -o ./bin/vsock-proxy ./cmd/vsock-proxy

show-bins:
	@echo "Binaries built at:"
	@echo "  enclave: ./bin/enclave"
	@echo "  connector: ./bin/connector"
	@echo "  vsock-proxy: ./bin/vsock-proxy"

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
	@if lsof -i :$(VSOCK_PROXY_PORT) > /dev/null 2>&1; then \
		echo "Warning: VSOCK proxy port $(VSOCK_PROXY_PORT) is already in use"; \
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
	
	@echo "Killing processes on known ports..."
	@-fuser -k 2222/tcp 2>/dev/null || true
	@-fuser -k 8000/tcp 2>/dev/null || true
	@-fuser -k 9000/tcp 2>/dev/null || true
	@-fuser -k 4566/tcp 2>/dev/null || true
	
	@echo "Force cleaning up VSOCK bindings..."
	@-rmmod vhost_vsock 2>/dev/null || true
	@-rmmod vmw_vsock_virtio_transport_common 2>/dev/null || true
	@-rmmod vmw_vsock_virtio_transport 2>/dev/null || true
	@-rmmod vsock 2>/dev/null || true
	@echo "Reloading VSOCK kernel modules..."
	@-modprobe vsock 2>/dev/null || true
	@-modprobe vmw_vsock_virtio_transport 2>/dev/null || true
	@-modprobe vmw_vsock_virtio_transport_common 2>/dev/null || true
	@-modprobe vhost_vsock 2>/dev/null || true
	
	@echo "Removing temporary VM artifacts..."
	-rm -f $(VM_IMG) $(SEED_IMG) user-data
	-rm -rf ./bin/
	
	@echo "Cleaning up temporary files..."
	-rm -f *.tmp *.log 2>/dev/null || true
	-rm -rf vm-logs/ 2>/dev/null || true
	
	@echo "=== All development resources cleaned up ==="
