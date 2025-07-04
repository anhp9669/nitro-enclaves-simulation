# Nitro Enclave Development Environment

A complete development environment for experimenting with AWS Nitro Enclaves using QEMU VM simulation. This project provides a local development setup that mimics the Nitro Enclave environment, allowing you to develop, test, and debug enclave applications without needing actual AWS hardware.

## 🚀 Quick Start

```bash
# Clone the repository
git clone <your-repo-url>
cd nitro-dev-qemu

# Start the complete environment (order matters!)
make setup-vm           # Boot the QEMU VM first
# ⚠️  IMPORTANT: Wait for VM to fully boot before continuing!
#    You'll see a login prompt when ready. Press Ctrl+A, then X to exit QEMU.

make start-enclave      # Build and start enclave inside the VM
make start-vsock-proxy  # Start localstack, setup KMS, and run vsock-proxy
make start-connector    # Start the connector Go application last

# View enclave logs
make view-logs
```

## 📋 Prerequisites

### System Requirements

- **OS**: Linux (Ubuntu 20.04+ recommended)
- **RAM**: At least 4GB available
- **Storage**: 10GB free space
- **CPU**: x86_64 with KVM support

### Required Software

```bash
# Install QEMU and KVM
sudo apt update
sudo apt install -y qemu-kvm qemu-system-x86 cloud-localds

# Install Docker and Docker Compose
sudo apt install -y docker.io docker-compose
sudo usermod -aG docker $USER

# Install Go (1.19+)
wget https://go.dev/dl/go1.21.0.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.0.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
source ~/.bashrc

# Install Python 3 (for port detection)
sudo apt install -y python3
```

### SSH Key Setup

```bash
# Generate SSH key for VM access
ssh-keygen -t rsa -b 4096 -f ~/.ssh/dev-vm -N ""
```

## 🏗️ Architecture

This development environment simulates the AWS Nitro Enclave architecture with a complete roundtrip communication flow:

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Host System   │    │   QEMU VM       │    │   LocalStack    │
│                 │    │                 │    │                 │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │  Connector  │ │    │ │   Enclave   │ │    │ │     KMS     │ │
│ │             │ │    │ │             │ │    │ │             │ │
│ └─────────────┘ │    │ └─────────────┘ │    │ └─────────────┘ │
│        │        │    │        │        │    │        │        │
│        │        │    │        │        │    │        │        │
│ ┌─────────────┐ │    │        │        │    │        │        │
│ │VSOCK Proxy  │ │    │        │        │    │        │        │
│ │             │ │    │        │        │    │        │        │
│ └─────────────┘ │    │        │        │    │        │        │
└─────────────────┘    └─────────────────┘    └─────────────────┘
        │                       │                       │
        │                       │                       │
        └───────────────────────┼───────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │   Communication Flow │
                    │                       │
                    │ 1. Connector → Enclave│
                    │ 2. Enclave → VSOCK    │
                    │ 3. VSOCK → KMS        │
                    │ 4. KMS → VSOCK        │
                    │ 5. VSOCK → Enclave    │
                    │ 6. Enclave → Connector│
                    └───────────────────────┘
```

### Startup Sequence

**Important**: The startup order is critical for proper communication:

1. **VM** must be running first to provide the enclave environment
2. **Enclave** must be started inside the VM before proxy setup
3. **VSOCK Proxy** must be running to handle host-VM communication
4. **Connector** starts last to initiate communication with the enclave

### Communication Roundtrip

1. **Connector → Enclave**: Host application sends request to enclave
2. **Enclave → VSOCK Proxy**: Enclave forwards request through VSOCK
3. **VSOCK Proxy → KMS**: Proxy routes request to LocalStack KMS
4. **KMS → VSOCK Proxy**: KMS processes request and returns response
5. **VSOCK Proxy → Enclave**: Proxy forwards KMS response back to enclave
6. **Enclave → Connector**: Enclave processes response and returns to host

### Components

- **QEMU VM**: Simulates the Nitro Enclave environment
- **Enclave**: Your secure application running inside the VM
- **Connector**: Host application that communicates with the enclave
- **VSOCK Proxy**: Handles communication between host and VM
- **LocalStack**: Local AWS services (KMS) for development

## 🎯 Usage

### 1. Boot the VM

```bash
make setup-vm
```

**⚠️ IMPORTANT**: Wait for the VM to fully boot before proceeding to the next step. You'll see a login prompt when the VM is ready. To exit QEMU and continue with the next commands, press `Ctrl+A`, then `X`.

This boots the QEMU VM with:

- Cloud-init for automatic setup
- VSOCK support for enclave communication
- SSH access on port 2222
- Network forwarding for development

### 2. Start the Enclave

```bash
make start-enclave
```

This:

- Builds the enclave application
- Copies it to the VM
- Starts it as a background process

### 3. Start the VSOCK Proxy Environment

```bash
make start-vsock-proxy
```

This command:

- Starts LocalStack (local AWS services)
- Sets up KMS with test keys
- Starts the VSOCK proxy for host-VM communication

### 4. Start the Connector

```bash
make start-connector
```

This builds and starts the connector application that will communicate with the enclave.

### 5. Monitor and Debug

#### SSH into the VM

```bash
make ssh-vm
```

#### View Enclave Logs in Real-time

```bash
make view-logs
```

#### Copy Logs to Host

```bash
make get-logs
```

## 🔧 Development Workflow

### Building Applications

```bash
# Build all applications
make build-all

# Build specific applications
make build-enclave
make build-connector
make build-vsock-proxy
```

### Debugging

#### Check VM Status

```bash
# SSH into VM and check processes
make ssh-vm
ps aux | grep enclave
```

#### View Application Logs

```bash
# Real-time log viewing
make view-logs

# Copy logs to host for analysis
make get-logs
ls -la vm-logs/
```

#### Check Network Connectivity

```bash
# From host
netstat -tlnp | grep :9000

# From VM (after SSH)
netstat -tlnp
```

### Troubleshooting

#### Startup Order Issues

If you encounter communication problems, ensure the correct startup order:

```bash
# 1. Always start VM first
make setup-vm
# ⚠️  Wait for VM to fully boot (you'll see login prompt), then press Ctrl+A, X to exit

# 2. Start enclave inside VM
make start-enclave

# 3. Start VSOCK proxy environment
make start-vsock-proxy

# 4. Start connector last
make start-connector
```

#### Port Conflicts

If you get port conflicts:

```bash
# Kill all development processes
make kill-all

# Check what's using the ports
lsof -i :2222 -i :9000
```

#### VM Issues

```bash
# Force kill all QEMU processes
pkill -9 -f qemu-system-x86_64

# Rebuild VM
make clean
make setup-vm
```

#### Docker Issues

```bash
# Restart Docker services
docker-compose down
docker-compose up -d
```

## 📁 Project Structure

```
nitro-dev-qemu/
├── cmd/
│   ├── enclave/          # Enclave application
│   ├── connector/        # Host connector application
│   └── vsock-proxy/      # VSOCK proxy for communication
├── cloud-init.yaml       # VM initialization configuration
├── docker-compose.yaml   # LocalStack and VSOCK proxy services
├── kms-test-policy.json  # KMS policy for development
├── Makefile             # Development automation
└── README.md            # This file
```

## 🔒 Security Notes

⚠️ **Important**: This is a development environment for learning and testing. It does not provide the same security guarantees as real AWS Nitro Enclaves.

- The VM is not isolated like real enclaves
- KMS keys are stored locally
- Network communication is simulated
- Use only for development and testing

## 🧪 Experimentation Ideas

1. **Basic Enclave Communication**: Modify the enclave and connector to exchange encrypted messages
2. **KMS Integration**: Use the local KMS to encrypt/decrypt data
3. **Attestation Simulation**: Implement basic attestation protocols
4. **Multi-Enclave Setup**: Run multiple enclaves in the same VM
5. **Custom VSOCK Protocols**: Implement custom communication protocols

## 🛠️ Customization

### VM Configuration

Edit the configuration variables in the Makefile:

```makefile
VM_MEM=1024        # VM memory in MB
VM_CPUS=2          # Number of CPU cores
VSOCK_PORT=9000    # VSOCK communication port
SSH_PORT=2222      # SSH access port
```

### Application Development

- Modify `cmd/enclave/` for enclave application logic
- Modify `cmd/connector/` for host application logic
- Modify `cmd/vsock-proxy/` for communication protocols

## 📚 Additional Resources

- [AWS Nitro Enclaves Documentation](https://docs.aws.amazon.com/enclaves/)
- [QEMU Documentation](https://qemu.readthedocs.io/)
- [LocalStack Documentation](https://docs.localstack.cloud/)
- [Go Programming Language](https://golang.org/)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📄 License

[Add your license information here]

---

**Happy Enclave Development! 🚀**
