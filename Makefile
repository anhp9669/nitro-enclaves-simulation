# Makefile for dev setup with QEMU VM simulating Nitro Enclave

# CONFIGURATION
VM_IMG=ubuntu-nitro-dev.qcow2
BASE_IMG_URL=https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img
BASE_IMG=focal-server-cloudimg-amd64.img
SEED_IMG=seed.img
VM_MEM=1024
VM_CPUS=2
VSOCK_PORT=9000
VSOCK_CID=3
KMS_PORT=4566
VM_USER=ubuntu
SSH_KEY=~/.ssh/dev-vm
SSH_PUB_KEY=~/.ssh/dev-vm.pub

.PHONY: all setup-vm run-localstack build-enclave start-enclave build-vsock-proxy setup-kms ssh-vm prepare-vm-image clean kill-all

all: run-localstack build-enclave setup-kms build-vm setup-vm

##############################################
# BUILD AND RUN SERVICES
##############################################

run-localstack:
	docker-compose up -d localstack

build-enclave:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go install -a -ldflags '-extldflags "-static"' ./cmd/enclave

build-connector:
	go install ./cmd/connector

build-vsock-proxy:
	go install ./cmd/vsock-proxy

show-bins:
	@echo "Binaries installed at:"
	@echo "  enclave: $(shell go env GOBIN)/enclave"
	@echo "  connector: $(shell go env GOBIN)/connector"
	@echo "  vsock-proxy: $(shell go env GOBIN)/vsock-proxy"

setup-kms:
	docker exec -i localstack awslocal kms create-key --description "Test Dev KMS Key" --key-usage ENCRYPT_DECRYPT --origin EXTERNAL --policy file:///etc/localstack/kms-test-policy.json || true
	docker exec -i localstack awslocal kms create-alias --alias-name alias/dev-key --target-key-id $$(docker exec -i localstack awslocal kms list-keys --query "Keys[0].KeyId" --output text) || true

##############################################
# VM BUILD & BOOT
##############################################

build-vm: $(BASE_IMG) create-vm $(SEED_IMG)

$(BASE_IMG):
	wget -O $(BASE_IMG) $(BASE_IMG_URL)

$(SEED_IMG): cloud-init.yaml $(SSH_PUB_KEY)
	cp cloud-init.yaml user-data
	sed -i "s|REPLACE_ME_WITH_YOUR_SSH_KEY|$$(cat $(SSH_PUB_KEY))|" user-data
	cloud-localds $(SEED_IMG) user-data

setup-vm:
	@echo "Booting QEMU VM with cloud-init and vsock..."
	qemu-system-x86_64 \
	  -m 1024 \
	  -smp 2 \
	  -enable-kvm \
	  -cpu host \
	  -drive file=ubuntu-nitro-dev.qcow2,if=virtio,format=qcow2 \
	  -drive file=seed.img,format=raw,if=virtio \
	  -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::9000-:9000 \
	  -device virtio-net-pci,netdev=net0 \
	  -device vhost-vsock-pci,guest-cid=3 \
	  -nographic

create-vm:
	@echo "Creating writable copy of base VM image with expanded disk space..."
	cp $(BASE_IMG) $(VM_IMG)
	qemu-img resize $(VM_IMG) 10G

##############################################
# VM INTERACTION
##############################################

start-enclave:
	scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 2222 -i $(SSH_KEY) $(shell go env GOBIN)/enclave $(VM_USER)@localhost:/home/$(VM_USER)/
	ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 -i $(SSH_KEY) $(VM_USER)@localhost "chmod +x /home/$(VM_USER)/enclave && nohup ./enclave > enclave.log 2>&1 &"

start-vsock-proxy:
	docker-compose up -d vsock-proxy

ssh-vm:
	ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 $(VM_USER)@localhost -i $(SSH_KEY)

clean:
	rm -f $(SEED_IMG) user-data
kill-all:
	@echo "Stopping Docker services..."
	-docker compose down

	@echo "Killing QEMU VM if running..."
	-pkill -f "qemu-system-x86_64.*$(VM_IMG)"

	@echo "Removing temporary VM artifacts..."
	rm -f $(VM_IMG) $(SEED_IMG) user-data
	rm -f $(shell go env GOBIN)/enclave $(shell go env GOBIN)/connector $(shell go env GOBIN)/vsock-proxy

	@echo "All dev resources cleaned up."