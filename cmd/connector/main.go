// connector/main.go
package main

import (
	"bufio"
	"fmt"
	"log"
	"os"
	"time"

	"golang.org/x/sys/unix"
)

func main() {
	log.Println("[connector] Starting vsock connector client...")
	log.Printf("[connector] Target: CID 3, Port 9000")

	reader := bufio.NewReader(os.Stdin)
	for {
		fmt.Print("Enter text to encrypt (or type exit): ")
		text, _ := reader.ReadString('\n')
		if text == "exit\n" {
			log.Println("[connector] Exiting...")
			break
		}

		log.Printf("[connector] Attempting to connect to enclave...")
		startTime := time.Now()

		// Create vsock socket
		fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
		if err != nil {
			log.Printf("[connector] Error creating vsock socket: %v", err)
			continue
		}
		log.Printf("[connector] Created vsock socket with fd: %d", fd)

		// Connect to enclave on CID 3, port 9000
		addr := &unix.SockaddrVM{
			CID:  3,
			Port: 9000,
		}

		log.Printf("[connector] Connecting to vsock address: CID=%d, Port=%d", addr.CID, addr.Port)
		if err := unix.Connect(fd, addr); err != nil {
			log.Printf("[connector] Error connecting to enclave: %v", err)
			unix.Close(fd)
			continue
		}

		connectTime := time.Since(startTime)
		log.Printf("[connector] Successfully connected to enclave in %v", connectTime)

		// Send data
		log.Printf("[connector] Sending %d bytes: %q", len(text), text[:len(text)-1]) // Remove newline from log
		sendStart := time.Now()
		_, err = unix.Write(fd, []byte(text))
		if err != nil {
			log.Printf("[connector] Write error: %v", err)
			unix.Close(fd)
			continue
		}
		sendTime := time.Since(sendStart)
		log.Printf("[connector] Data sent successfully in %v", sendTime)

		// Read response
		log.Printf("[connector] Waiting for encrypted response...")
		readStart := time.Now()
		reply := make([]byte, 4096)
		n, err := unix.Read(fd, reply)
		if err != nil {
			log.Printf("[connector] Read error: %v", err)
			unix.Close(fd)
			continue
		}
		readTime := time.Since(readStart)

		totalTime := time.Since(startTime)
		log.Printf("[connector] Received %d bytes in %v (total round-trip: %v)", n, readTime, totalTime)

		encryptedResult := string(reply[:n])
		log.Printf("[connector] Raw encrypted result: %q", encryptedResult)
		fmt.Println("Encrypted result:", encryptedResult)

		unix.Close(fd)
		log.Printf("[connector] Connection closed")
	}
}
