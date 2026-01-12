package p2p

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"testing"
	"time"

	"github.com/quic-go/quic-go"
)

func TestQUICMinimal(t *testing.T) {
	// Setup TLS (ECDSA like Server)
	tlsConf := generateTestTLS(t)

	// Server
	udpAddr, _ := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	udpConn, _ := net.ListenUDP("udp", udpAddr)

	listener, err := quic.Listen(udpConn, tlsConf, nil)
	if err != nil {
		t.Fatal(err)
	}
	serverAddr := udpConn.LocalAddr().String()
	fmt.Printf("Debug Server listening on %s (UDP)\n", serverAddr)

	go func() {
		conn, err := listener.Accept(context.Background())
		if err != nil {
			fmt.Printf("Accept error: %v\n", err)
			return
		}
		fmt.Printf("Server Accepted Conn from %s\n", conn.RemoteAddr())
		stream, err := conn.AcceptStream(context.Background())
		if err != nil {
			fmt.Printf("AcceptStream error: %v\n", err)
			return
		}
		fmt.Printf("Server Accepted Stream\n")
		// Echo
		buf := make([]byte, 1024)
		n, _ := stream.Read(buf)
		stream.Write(buf[:n])
	}()

	// Client
	fmt.Printf("Debug Client Dialing %s\n", serverAddr)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	clientConf := &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"zelius-p2p"}}
	conn, err := quic.DialAddr(ctx, serverAddr, clientConf, &quic.Config{
		KeepAlivePeriod: 10 * time.Second,
		MaxIdleTimeout:  30 * time.Second,
	})
	if err != nil {
		t.Fatalf("Dial failed: %v", err)
	}
	fmt.Printf("Client Connected\n")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStream failed: %v", err)
	}
	fmt.Printf("Client Opened Stream\n")
	stream.Write([]byte("Hello"))
	stream.Close()
}

func generateTestTLS(t *testing.T) *tls.Config {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now(), NotAfter: time.Now().Add(time.Hour)}
	certDER, _ := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)

	keyBytes, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes})
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})
	tlsCert, _ := tls.X509KeyPair(certPEM, keyPEM)
	return &tls.Config{
		Certificates: []tls.Certificate{tlsCert},
		NextProtos:   []string{"zelius-p2p"},
	}
}
