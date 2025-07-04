# Security Warning and Best Practices

⚠️ **IMPORTANT SECURITY NOTICE** ⚠️

This is a **DEVELOPMENT AND TESTING ENVIRONMENT ONLY**. It is **NOT** suitable for production use and does not provide the same security guarantees as real AWS Nitro Enclaves.

## 🚨 Critical Security Warnings

### 1. Script Execution Risk

- **Most scripts are bash scripts** - Run with your own risk management
- **Review all scripts** before execution, especially Makefile targets
- **Never run scripts from untrusted sources** without inspection
- **Use at your own risk** - This is experimental software

### 2. Development Environment Limitations

- **No real security isolation** - This is a QEMU VM simulation
- **Local KMS keys** - Keys are stored locally, not in AWS
- **Network communication is simulated** - Not real VSOCK isolation
- **VM is not encrypted** - Data is stored in plain text on disk

### 3. System Resource Usage

- **High resource consumption** - QEMU VM requires significant CPU/memory
- **Port binding** - Uses multiple ports (2222, 9000, 4566, etc.)
- **Docker containers** - Runs LocalStack and other services
- **File system access** - Creates and modifies files in your workspace

## 🔒 Security Best Practices

### Before Starting

1. **Review all code** - Understand what each component does
2. **Check your environment** - Ensure you're in a safe testing environment
3. **Backup important data** - This environment modifies system state
4. **Use isolated environment** - Consider using a VM or container

### During Development

1. **Monitor resource usage** - Watch CPU, memory, and disk usage
2. **Check network connections** - Verify only expected ports are open
3. **Review logs carefully** - Look for unexpected behavior
4. **Don't use real credentials** - Use only test/dummy data

### After Experimentation

1. **Always run `make kill-all`** - Stop all services and clean up processes
2. **Always run `make clean`** - Remove temporary files and VM artifacts
3. **Check for remaining processes** - Ensure no background processes remain
4. **Verify port cleanup** - Confirm ports are no longer in use
5. **Review file system** - Check for any leftover files

## 🛡️ Security Checklist

### Pre-Execution

- [ ] Read and understood all documentation
- [ ] Reviewed Makefile and scripts
- [ ] Confirmed you're in a safe testing environment
- [ ] Backed up any important data
- [ ] Verified system resources are adequate

### During Execution

- [ ] Monitor system resources
- [ ] Watch for unexpected network activity
- [ ] Review application logs
- [ ] Don't use real/sensitive data
- [ ] Keep track of what's running

### Post-Execution

- [ ] Run `make kill-all`
- [ ] Run `make clean`
- [ ] Verify all processes are stopped
- [ ] Check ports are freed
- [ ] Review any created files
- [ ] Restart system if needed

## 🚫 What NOT to Do

- ❌ **Don't use in production**
- ❌ **Don't use real AWS credentials**
- ❌ **Don't use sensitive data**
- ❌ **Don't run without understanding the code**
- ❌ **Don't skip cleanup steps**
- ❌ **Don't run on shared systems without isolation**
- ❌ **Don't assume this provides real security**

## 🔍 Security Monitoring

### Check for Running Processes

```bash
# Check for QEMU processes
ps aux | grep qemu

# Check for Go applications
ps aux | grep -E "(enclave|connector|vsock-proxy)"

# Check for Docker containers
docker ps

# Check for port usage
netstat -tlnp | grep -E "(2222|9000|4566)"
```

### Verify Cleanup

```bash
# After running make kill-all and make clean
ps aux | grep -E "(qemu|enclave|connector|vsock-proxy)" | grep -v grep
docker ps
netstat -tlnp | grep -E "(2222|9000|4566)"
ls -la *.img *.log vm-logs/ 2>/dev/null
```

## 🆘 Emergency Cleanup

If something goes wrong or you need to force cleanup:

```bash
# Force kill all related processes
sudo pkill -9 -f qemu
sudo pkill -9 -f enclave
sudo pkill -9 -f connector
sudo pkill -9 -f vsock-proxy

# Force kill processes on specific ports
sudo fuser -k 2222/tcp
sudo fuser -k 9000/tcp
sudo fuser -k 4566/tcp

# Stop all Docker containers
docker stop $(docker ps -q)
docker system prune -f

# Remove temporary files
rm -rf *.img *.log vm-logs/ user-data
```

## 📋 System Requirements and Risks

### Minimum Requirements

- **RAM**: 4GB+ available
- **Storage**: 10GB+ free space
- **CPU**: x86_64 with KVM support
- **OS**: Linux (Ubuntu 20.04+ recommended)

### Potential Risks

- **Resource exhaustion** - High CPU/memory usage
- **Port conflicts** - Multiple services use various ports
- **File system changes** - Creates and modifies files
- **Network exposure** - Opens network ports
- **Process proliferation** - Multiple background processes

## 🔐 Data Privacy

- **No data is encrypted** in this development environment
- **All communication is local** but not encrypted
- **Logs may contain sensitive information** - review before sharing
- **VM disk images** contain all data in plain text
- **Clean up thoroughly** to remove any test data

## 📞 Support and Reporting

If you encounter security issues:

1. **Stop all processes immediately**
2. **Document the issue** with logs and steps
3. **Run emergency cleanup**
4. **Report the issue** to the project maintainers
5. **Don't share sensitive information** in bug reports

---

**Remember**: This is a **DEVELOPMENT TOOL ONLY**. Use responsibly and always clean up after yourself.

**Last Updated**: [Current Date]
**Version**: Development Build
**Security Level**: Development/Testing Only
