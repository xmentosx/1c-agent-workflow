package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func TestDesignerAgentSafeModeUsesPinnedLocalSSHAndFixedCommands(t *testing.T) {
	address, publicKey, received, stop := startDesignerAgentTestServer(t, "ib-user", "ib-password")
	defer stop()
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatal(err)
	}
	port, err := net.LookupPort("tcp", portText)
	if err != nil {
		t.Fatal(err)
	}
	request := &designerAgentRequest{
		Host: host, Port: port, Username: "ib-user", Password: "ib-password",
		HostPublicKey: publicKey, Commands: append([]string(nil), designerSafeModeCommands...),
		ConnectTimeoutSeconds: 5, CommandTimeoutSeconds: 5,
	}
	response, err := executeDesignerAgentRequest(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if !response.Success || len(response.Commands) != len(designerSafeModeCommands) {
		t.Fatalf("unexpected response: %#v", response)
	}
	for index, want := range designerSafeModeCommands {
		select {
		case got := <-received:
			if got != want {
				t.Fatalf("command %d=%q, want %q", index+1, got, want)
			}
		case <-time.After(time.Second):
			t.Fatalf("command %d was not received", index+1)
		}
	}
	for _, result := range response.Commands {
		if strings.Contains(result.Command, "unsafe-action-protection") {
			t.Fatalf("unsafe action protection was changed: %q", result.Command)
		}
	}
}

func TestDesignerAgentSafeModeRejectsAnyOtherCommandOrHost(t *testing.T) {
	request := &designerAgentRequest{
		Host: "192.0.2.1", Port: 1543, HostPublicKey: "key",
		Commands: append([]string(nil), designerSafeModeCommands...),
	}
	if err := validateDesignerAgentRequest(request); err == nil || !strings.Contains(err.Error(), "HOST_INVALID") {
		t.Fatalf("unexpected host validation error: %v", err)
	}
	request.Host = "127.0.0.1"
	request.Commands[1] = "config extensions properties set --all-extensions --safe-mode no"
	if err := validateDesignerAgentRequest(request); err == nil || !strings.Contains(err.Error(), "COMMANDS_INVALID") {
		t.Fatalf("unexpected command validation error: %v", err)
	}
}

func TestDesignerAgentSafeModeRejectsHostKeyMismatch(t *testing.T) {
	address, _, _, stop := startDesignerAgentTestServer(t, "", "")
	defer stop()
	otherPrivate, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	otherSigner, err := ssh.NewSignerFromKey(otherPrivate)
	if err != nil {
		t.Fatal(err)
	}
	_, portText, _ := net.SplitHostPort(address)
	port, _ := net.LookupPort("tcp", portText)
	request := &designerAgentRequest{
		Host: "127.0.0.1", Port: port, HostPublicKey: string(ssh.MarshalAuthorizedKey(otherSigner.PublicKey())),
		Commands: append([]string(nil), designerSafeModeCommands...), ConnectTimeoutSeconds: 5, CommandTimeoutSeconds: 5,
	}
	_, err = executeDesignerAgentRequest(context.Background(), request)
	if err == nil || !strings.Contains(err.Error(), "host key mismatch") {
		t.Fatalf("unexpected mismatch result: %v", err)
	}
}

func TestDesignerAgentSafeModeRejectsCanceledResult(t *testing.T) {
	if !designerMessageRejectsCommand(designerAgentMessage{Type: "canceled"}) {
		t.Fatal("Designer Agent canceled result was not rejected")
	}
}

func startDesignerAgentTestServer(t *testing.T, user, password string) (string, string, <-chan string, func()) {
	t.Helper()
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	config := &ssh.ServerConfig{PasswordCallback: func(metadata ssh.ConnMetadata, value []byte) (*ssh.Permissions, error) {
		if metadata.User() != user || string(value) != password {
			return nil, fmt.Errorf("invalid credentials")
		}
		return nil, nil
	}}
	config.AddHostKey(signer)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	received := make(chan string, len(designerSafeModeCommands))
	done := make(chan struct{})
	go func() {
		defer close(done)
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		defer connection.Close()
		_, channels, requests, err := ssh.NewServerConn(connection, config)
		if err != nil {
			return
		}
		go ssh.DiscardRequests(requests)
		for newChannel := range channels {
			if newChannel.ChannelType() != "session" {
				_ = newChannel.Reject(ssh.UnknownChannelType, "session required")
				continue
			}
			channel, channelRequests, err := newChannel.Accept()
			if err != nil {
				return
			}
			for request := range channelRequests {
				switch request.Type {
				case "pty-req":
					request.Reply(false, nil)
				case "shell":
					request.Reply(true, nil)
					_, _ = channel.Write([]byte("1C Designer Shell\r\ndesigner>"))
					scanner := newCRLFScanner(channel)
					for scanner.Scan() {
						command := strings.TrimSpace(scanner.Text())
						if command == "" {
							continue
						}
						if command == "options set --output-format=json" {
							_, _ = channel.Write([]byte("[{\"type\":\"success\",\"message\":\"\"}]\r\ndesigner>"))
							continue
						}
						received <- command
						body := ""
						if strings.Contains(command, "properties get") {
							body = ",\"body\":{\"safeMode\":false}"
						}
						_, _ = channel.Write([]byte("[{\"type\":\"success\"" + body + ",\"message\":\"\"}]\r\n"))
						if command == "common shutdown" {
							_ = channel.Close()
							return
						}
						_, _ = channel.Write([]byte("designer>"))
					}
				default:
					request.Reply(false, nil)
				}
			}
		}
	}()
	stop := func() {
		_ = listener.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
		}
	}
	return listener.Addr().String(), string(ssh.MarshalAuthorizedKey(signer.PublicKey())), received, stop
}

func newCRLFScanner(reader io.Reader) *bufio.Scanner {
	scanner := bufio.NewScanner(reader)
	scanner.Split(bufio.ScanLines)
	return scanner
}
