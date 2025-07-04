// vsock-proxy/main.go
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	"golang.org/x/sys/unix"
)

type KMSEncryptRequest struct {
	KeyId     string `json:"KeyId"`
	Plaintext string `json:"Plaintext"`
}

type KMSEncryptResponse struct {
	CiphertextBlob string `json:"CiphertextBlob"`
	KeyId          string `json:"KeyId"`
}

func main() {
	log.Println("[vsock-proxy] Starting vsock proxy for KMS encryption...")

	target := os.Getenv("KMS_TARGET")
	if target == "" {
		target = "http://localstack:4566"
	}
	log.Printf("[vsock-proxy] KMS target: %s", target)

	// Create vsock listener on CID 2, port 8000
	addr := &unix.SockaddrVM{
		CID:  2,
		Port: 8000,
	}

	log.Printf("[vsock-proxy] Creating vsock socket for CID=%d, Port=%d", addr.CID, addr.Port)

	// Create vsock socket
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		log.Fatalf("[vsock-proxy] Failed to create vsock socket: %v", err)
	}
	log.Printf("[vsock-proxy] Created vsock socket with fd: %d", fd)
	defer unix.Close(fd)

	// Bind to vsock address
	log.Printf("[vsock-proxy] Binding to vsock address...")
	if err := unix.Bind(fd, addr); err != nil {
		log.Fatalf("[vsock-proxy] Failed to bind vsock socket: %v", err)
	}
	log.Printf("[vsock-proxy] Successfully bound to vsock address")

	// Listen for connections
	log.Printf("[vsock-proxy] Starting to listen for connections...")
	if err := unix.Listen(fd, 128); err != nil {
		log.Fatalf("[vsock-proxy] Failed to listen on vsock: %v", err)
	}

	log.Printf("[vsock-proxy] Listening on vsock CID %d, port %d", addr.CID, addr.Port)
	log.Printf("[vsock-proxy] Ready to accept connections...")

	connectionCount := 0
	for {
		// Accept connection
		log.Printf("[vsock-proxy] Waiting for new connection...")
		nfd, sa, err := unix.Accept(fd)
		if err != nil {
			log.Printf("[vsock-proxy] Accept failed: %v", err)
			continue
		}

		connectionCount++
		log.Printf("[vsock-proxy] Accepted connection #%d with fd: %d", connectionCount, nfd)

		// Log client address if available
		if vmAddr, ok := sa.(*unix.SockaddrVM); ok {
			log.Printf("[vsock-proxy] Client connected from CID: %d, Port: %d", vmAddr.CID, vmAddr.Port)
		}

		// Handle connection in goroutine
		go handleVsockConnection(nfd, sa, connectionCount, target)
	}
}

func handleVsockConnection(fd int, sa unix.Sockaddr, connID int, kmsTarget string) {
	startTime := time.Now()
	log.Printf("[vsock-proxy:%d] Starting connection handler", connID)
	defer func() {
		unix.Close(fd)
		duration := time.Since(startTime)
		log.Printf("[vsock-proxy:%d] Connection closed after %v", connID, duration)
	}()

	// Read data from vsock
	log.Printf("[vsock-proxy:%d] Reading data from client...", connID)
	readStart := time.Now()
	buffer := make([]byte, 4096)
	n, err := unix.Read(fd, buffer)
	if err != nil {
		log.Printf("[vsock-proxy:%d] Read error: %v", connID, err)
		return
	}
	readTime := time.Since(readStart)

	plaintext := string(buffer[:n])
	log.Printf("[vsock-proxy:%d] Received %d bytes in %v: %q", connID, n, readTime, plaintext)

	// Encrypt using KMS
	log.Printf("[vsock-proxy:%d] Sending encryption request to KMS...", connID)
	encryptStart := time.Now()
	encrypted, err := encryptWithKMS(plaintext, kmsTarget)
	if err != nil {
		log.Printf("[vsock-proxy:%d] KMS encryption failed: %v", connID, err)
		return
	}
	encryptTime := time.Since(encryptStart)
	log.Printf("[vsock-proxy:%d] KMS encryption completed in %v", connID, encryptTime)

	// Send encrypted result back
	log.Printf("[vsock-proxy:%d] Sending encrypted result (%d bytes)...", connID, len(encrypted))
	sendStart := time.Now()
	_, err = unix.Write(fd, []byte(encrypted))
	if err != nil {
		log.Printf("[vsock-proxy:%d] Write error: %v", connID, err)
		return
	}
	sendTime := time.Since(sendStart)

	totalTime := time.Since(startTime)
	log.Printf("[vsock-proxy:%d] Response sent in %v (total processing: %v)", connID, sendTime, totalTime)
	log.Printf("[vsock-proxy:%d] Encrypted result: %q", connID, encrypted)
}

func encryptWithKMS(plaintext, kmsTarget string) (string, error) {
	// Create KMS encrypt request
	req := KMSEncryptRequest{
		KeyId:     "alias/dev-key",
		Plaintext: plaintext,
	}

	reqBody, err := json.Marshal(req)
	if err != nil {
		return "", fmt.Errorf("failed to marshal request: %v", err)
	}

	// Create HTTP request to KMS
	kmsURL := fmt.Sprintf("%s/kms", kmsTarget)
	httpReq, err := http.NewRequest("POST", kmsURL, bytes.NewBuffer(reqBody))
	if err != nil {
		return "", fmt.Errorf("failed to create HTTP request: %v", err)
	}

	httpReq.Header.Set("Content-Type", "application/x-amz-json-1.1")
	httpReq.Header.Set("X-Amz-Target", "TrentService.Encrypt")

	// Send request to KMS
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(httpReq)
	if err != nil {
		return "", fmt.Errorf("failed to send request to KMS: %v", err)
	}
	defer resp.Body.Close()

	// Read response
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read KMS response: %v", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("KMS request failed with status %d: %s", resp.StatusCode, string(respBody))
	}

	// Parse KMS response
	var kmsResp KMSEncryptResponse
	if err := json.Unmarshal(respBody, &kmsResp); err != nil {
		return "", fmt.Errorf("failed to parse KMS response: %v", err)
	}

	return kmsResp.CiphertextBlob, nil
}
