// enclave/main.go
package main

import (
	"log"
	"time"

	"golang.org/x/sys/unix"
)

func main() {
	log.Println("[enclave] Starting vsock encryption proxy...")
	log.Println("[enclave] Acting as intermediary between connector and vsock-proxy")

	// Create vsock listener on CID 3, port 9000 (for connector connections)
	addr := &unix.SockaddrVM{
		CID:  3,
		Port: 9000,
	}

	log.Printf("[enclave] Creating vsock socket for CID=%d, Port=%d", addr.CID, addr.Port)

	// Create vsock socket
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		log.Fatalf("[enclave] Failed to create vsock socket: %v", err)
	}
	log.Printf("[enclave] Created vsock socket with fd: %d", fd)
	defer unix.Close(fd)

	// Bind to vsock address
	log.Printf("[enclave] Binding to vsock address...")
	if err := unix.Bind(fd, addr); err != nil {
		log.Fatalf("[enclave] Failed to bind vsock socket: %v", err)
	}
	log.Printf("[enclave] Successfully bound to vsock address")

	// Listen for connections
	log.Printf("[enclave] Starting to listen for connections...")
	if err := unix.Listen(fd, 128); err != nil {
		log.Fatalf("[enclave] Failed to listen on vsock: %v", err)
	}

	log.Printf("[enclave] Listening on vsock CID %d, port %d", addr.CID, addr.Port)
	log.Printf("[enclave] Ready to accept connections from connector...")

	connectionCount := 0
	for {
		// Accept connection
		log.Printf("[enclave] Waiting for new connection...")
		nfd, sa, err := unix.Accept(fd)
		if err != nil {
			log.Printf("[enclave] Accept failed: %v", err)
			continue
		}

		connectionCount++
		log.Printf("[enclave] Accepted connection #%d with fd: %d", connectionCount, nfd)

		// Log client address if available
		if vmAddr, ok := sa.(*unix.SockaddrVM); ok {
			log.Printf("[enclave] Client connected from CID: %d, Port: %d", vmAddr.CID, vmAddr.Port)
		}

		// Handle connection in goroutine
		go handleVsockConnection(nfd, sa, connectionCount)
	}
}

func handleVsockConnection(fd int, sa unix.Sockaddr, connID int) {
	startTime := time.Now()
	log.Printf("[enclave:%d] Starting connection handler", connID)
	defer func() {
		unix.Close(fd)
		duration := time.Since(startTime)
		log.Printf("[enclave:%d] Connection closed after %v", connID, duration)
	}()

	// Read data from connector
	log.Printf("[enclave:%d] Reading data from connector...", connID)
	readStart := time.Now()
	buffer := make([]byte, 4096)
	n, err := unix.Read(fd, buffer)
	if err != nil {
		log.Printf("[enclave:%d] Read error: %v", connID, err)
		return
	}
	readTime := time.Since(readStart)

	plaintext := string(buffer[:n])
	log.Printf("[enclave:%d] Received %d bytes in %v: %q", connID, n, readTime, plaintext)

	// Forward to vsock-proxy for KMS encryption
	log.Printf("[enclave:%d] Forwarding to vsock-proxy for KMS encryption...", connID)
	proxyStart := time.Now()
	encrypted, err := forwardToVsockProxy(plaintext)
	if err != nil {
		log.Printf("[enclave:%d] Vsock-proxy encryption failed: %v", connID, err)
		return
	}
	proxyTime := time.Since(proxyStart)
	log.Printf("[enclave:%d] Vsock-proxy encryption completed in %v", connID, proxyTime)

	// Send encrypted result back to connector
	log.Printf("[enclave:%d] Sending encrypted result (%d bytes) to connector...", connID, len(encrypted))
	sendStart := time.Now()
	_, err = unix.Write(fd, []byte(encrypted))
	if err != nil {
		log.Printf("[enclave:%d] Write error: %v", connID, err)
		return
	}
	sendTime := time.Since(sendStart)

	totalTime := time.Since(startTime)
	log.Printf("[enclave:%d] Response sent in %v (total processing: %v)", connID, sendTime, totalTime)
	log.Printf("[enclave:%d] Encrypted result: %q", connID, encrypted)
}

func forwardToVsockProxy(plaintext string) (string, error) {
	// Create vsock connection to vsock-proxy (CID 2, Port 8000)
	proxyAddr := &unix.SockaddrVM{
		CID:  2,
		Port: 8000,
	}

	log.Printf("[enclave] Connecting to vsock-proxy at CID=%d, Port=%d", proxyAddr.CID, proxyAddr.Port)

	// Create vsock socket for proxy connection
	proxyFd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		return "", err
	}
	defer unix.Close(proxyFd)

	// Connect to vsock-proxy
	if err := unix.Connect(proxyFd, proxyAddr); err != nil {
		return "", err
	}
	log.Printf("[enclave] Connected to vsock-proxy")

	// Send plaintext to vsock-proxy
	_, err = unix.Write(proxyFd, []byte(plaintext))
	if err != nil {
		return "", err
	}
	log.Printf("[enclave] Sent plaintext to vsock-proxy")

	// Read encrypted result from vsock-proxy
	reply := make([]byte, 4096)
	n, err := unix.Read(proxyFd, reply)
	if err != nil {
		return "", err
	}
	log.Printf("[enclave] Received encrypted result from vsock-proxy")

	return string(reply[:n]), nil
}
