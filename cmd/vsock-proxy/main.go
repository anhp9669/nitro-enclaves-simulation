// vsock-proxy/main.go
package main

import (
	"bytes"
	"encoding/base64"
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

type KMSListKeysResponse struct {
	Keys []struct {
		KeyId string `json:"KeyId"`
	} `json:"Keys"`
}

type KMSListAliasesResponse struct {
	Aliases []struct {
		AliasName   string `json:"AliasName"`
		TargetKeyId string `json:"TargetKeyId"`
	} `json:"Aliases"`
}

func main() {
	log.Println("[vsock-proxy] Starting vsock proxy for KMS encryption...")

	target := os.Getenv("KMS_TARGET")
	if target == "" {
		target = "http://localhost:4566"
	}
	log.Printf("[vsock-proxy] KMS target: %s", target)

	// Check KMS keys and aliases on startup
	log.Println("[vsock-proxy] Checking KMS configuration...")
	if err := checkKMSConfiguration(target); err != nil {
		log.Printf("[vsock-proxy] Warning: KMS configuration check failed: %v", err)
	} else {
		log.Println("[vsock-proxy] KMS configuration verified successfully")
	}

	// Create vsock listener on CID 2, port 9000 (use VSOCK_PORT from env or default)
	vsockPort := 9000
	if port := os.Getenv("VSOCK_PORT"); port != "" {
		if p, err := fmt.Sscanf(port, "%d", &vsockPort); err != nil || p != 1 {
			log.Printf("[vsock-proxy] Invalid VSOCK_PORT %s, using default 9000", port)
			vsockPort = 9000
		}
	}

	addr := &unix.SockaddrVM{
		CID:  2,
		Port: uint32(vsockPort),
	}

	log.Printf("[vsock-proxy] Creating vsock socket for CID=%d, Port=%d", addr.CID, addr.Port)

	// Create vsock socket
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		log.Fatalf("[vsock-proxy] Failed to create vsock socket: %v", err)
	}
	log.Printf("[vsock-proxy] Created vsock socket with fd: %d", fd)
	defer unix.Close(fd)

	// Bind to vsock address with retry logic
	log.Printf("[vsock-proxy] Binding to vsock address...")
	maxRetries := 5
	for i := 0; i < maxRetries; i++ {
		if err := unix.Bind(fd, addr); err != nil {
			if i < maxRetries-1 {
				log.Printf("[vsock-proxy] Bind failed (attempt %d/%d): %v, retrying in 2 seconds...", i+1, maxRetries, err)
				unix.Close(fd)
				time.Sleep(2 * time.Second)

				// Recreate socket
				fd, err = unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
				if err != nil {
					log.Fatalf("[vsock-proxy] Failed to recreate vsock socket: %v", err)
				}
				continue
			} else {
				log.Fatalf("[vsock-proxy] Failed to bind vsock socket after %d attempts: %v", maxRetries, err)
			}
		}
		break
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

func checkKMSConfiguration(kmsTarget string) error {
	// List available keys
	keysURL := fmt.Sprintf("%s/kms", kmsTarget)
	keysReq, err := http.NewRequest("POST", keysURL, bytes.NewBuffer([]byte(`{}`)))
	if err != nil {
		return fmt.Errorf("failed to create keys request: %v", err)
	}
	keysReq.Header.Set("Content-Type", "application/x-amz-json-1.1")
	keysReq.Header.Set("X-Amz-Target", "TrentService.ListKeys")

	client := &http.Client{Timeout: 5 * time.Second}
	keysResp, err := client.Do(keysReq)
	if err != nil {
		return fmt.Errorf("failed to list keys: %v", err)
	}
	defer keysResp.Body.Close()

	keysBody, err := io.ReadAll(keysResp.Body)
	if err != nil {
		return fmt.Errorf("failed to read keys response: %v", err)
	}

	if keysResp.StatusCode == http.StatusOK {
		var keys KMSListKeysResponse
		if err := json.Unmarshal(keysBody, &keys); err != nil {
			log.Printf("[vsock-proxy] Warning: Failed to parse keys response: %v", err)
		} else {
			log.Printf("[vsock-proxy] Available KMS keys: %d", len(keys.Keys))
			for i, key := range keys.Keys {
				log.Printf("[vsock-proxy] Key %d: %s", i+1, key.KeyId)
			}
		}
	} else {
		log.Printf("[vsock-proxy] Warning: Failed to list keys (status %d): %s", keysResp.StatusCode, string(keysBody))
	}

	// List aliases
	aliasesReq, err := http.NewRequest("POST", keysURL, bytes.NewBuffer([]byte(`{}`)))
	if err != nil {
		return fmt.Errorf("failed to create aliases request: %v", err)
	}
	aliasesReq.Header.Set("Content-Type", "application/x-amz-json-1.1")
	aliasesReq.Header.Set("X-Amz-Target", "TrentService.ListAliases")

	aliasesResp, err := client.Do(aliasesReq)
	if err != nil {
		return fmt.Errorf("failed to list aliases: %v", err)
	}
	defer aliasesResp.Body.Close()

	aliasesBody, err := io.ReadAll(aliasesResp.Body)
	if err != nil {
		return fmt.Errorf("failed to read aliases response: %v", err)
	}

	if aliasesResp.StatusCode == http.StatusOK {
		var aliases KMSListAliasesResponse
		if err := json.Unmarshal(aliasesBody, &aliases); err != nil {
			log.Printf("[vsock-proxy] Warning: Failed to parse aliases response: %v", err)
		} else {
			log.Printf("[vsock-proxy] Available KMS aliases: %d", len(aliases.Aliases))
			for i, alias := range aliases.Aliases {
				log.Printf("[vsock-proxy] Alias %d: %s -> %s", i+1, alias.AliasName, alias.TargetKeyId)
			}
		}
	} else {
		log.Printf("[vsock-proxy] Warning: Failed to list aliases (status %d): %s", aliasesResp.StatusCode, string(aliasesBody))
	}

	return nil
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
	log.Printf("[vsock-proxy:%d] Received %d bytes in %v", connID, n, readTime)
	log.Printf("[vsock-proxy:%d] PLAINTEXT: %q", connID, plaintext)
	log.Printf("[vsock-proxy:%d] Plaintext length: %d characters", connID, len(plaintext))
	log.Printf("[vsock-proxy:%d] Plaintext bytes: %v", connID, []byte(plaintext))

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
	log.Printf("[vsock-proxy:%d] ENCRYPTED RESULT: %q", connID, encrypted)
	log.Printf("[vsock-proxy:%d] Encrypted length: %d characters", connID, len(encrypted))
	log.Printf("[vsock-proxy:%d] Encryption ratio: %.2f (encrypted/plaintext)", connID, float64(len(encrypted))/float64(len(plaintext)))
}

func encryptWithKMS(plaintext, kmsTarget string) (string, error) {
	// Base64 encode the plaintext as required by AWS KMS API
	plaintextBase64 := base64.StdEncoding.EncodeToString([]byte(plaintext))
	log.Printf("[vsock-proxy] Plaintext base64: %q", plaintextBase64)

	// Create KMS encrypt request
	req := KMSEncryptRequest{
		KeyId:     "alias/dev-key",
		Plaintext: plaintextBase64,
	}

	reqBody, err := json.Marshal(req)
	if err != nil {
		return "", fmt.Errorf("failed to marshal request: %v", err)
	}

	log.Printf("[vsock-proxy] KMS request JSON: %s", string(reqBody))

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

	log.Printf("[vsock-proxy] KMS response JSON: %s", string(respBody))

	// Parse KMS response
	var kmsResp KMSEncryptResponse
	if err := json.Unmarshal(respBody, &kmsResp); err != nil {
		return "", fmt.Errorf("failed to parse KMS response: %v", err)
	}

	log.Printf("[vsock-proxy] KMS KeyId used: %s", kmsResp.KeyId)
	log.Printf("[vsock-proxy] KMS CiphertextBlob: %q", kmsResp.CiphertextBlob)

	return kmsResp.CiphertextBlob, nil
}
