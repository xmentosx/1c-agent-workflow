package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

const designerAgentInputLimit = 1 << 20

var designerSafeModeCommands = []string{
	"common connect-ib",
	"config extensions properties set --extension client_mcp --safe-mode no",
	"config extensions properties get --extension client_mcp",
	"config extensions properties set --extension VAExtension --safe-mode no",
	"config extensions properties get --extension VAExtension",
	"common disconnect-ib",
	"common shutdown",
}

type designerAgentRequest struct {
	Host                  string   `json:"host"`
	Port                  int      `json:"port"`
	Username              string   `json:"username"`
	Password              string   `json:"password"`
	HostPublicKey         string   `json:"hostPublicKey"`
	Commands              []string `json:"commands"`
	ConnectTimeoutSeconds int      `json:"connectTimeoutSeconds,omitempty"`
	CommandTimeoutSeconds int      `json:"commandTimeoutSeconds,omitempty"`
}

type designerAgentMessage struct {
	Type    string          `json:"type"`
	Message string          `json:"message,omitempty"`
	Body    json.RawMessage `json:"body,omitempty"`
}

type designerAgentCommandResult struct {
	Command  string                 `json:"command"`
	Messages []designerAgentMessage `json:"messages"`
}

type designerAgentResponse struct {
	Success  bool                         `json:"success"`
	Commands []designerAgentCommandResult `json:"commands"`
}

func runDesignerAgentSafeMode(input io.Reader, output io.Writer) error {
	decoder := json.NewDecoder(io.LimitReader(input, designerAgentInputLimit))
	decoder.DisallowUnknownFields()
	var request designerAgentRequest
	if err := decoder.Decode(&request); err != nil {
		return fmt.Errorf("ITL_DESIGNER_AGENT_REQUEST_INVALID: %w", err)
	}
	if err := validateDesignerAgentRequest(&request); err != nil {
		return err
	}
	response, err := executeDesignerAgentRequest(context.Background(), &request)
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(output)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(response)
}

func validateDesignerAgentRequest(request *designerAgentRequest) error {
	if request.Host != "127.0.0.1" {
		return fmt.Errorf("ITL_DESIGNER_AGENT_HOST_INVALID: only 127.0.0.1 is allowed")
	}
	if request.Port < 1 || request.Port > 65535 {
		return fmt.Errorf("ITL_DESIGNER_AGENT_PORT_INVALID: %d", request.Port)
	}
	if strings.TrimSpace(request.HostPublicKey) == "" {
		return fmt.Errorf("ITL_DESIGNER_AGENT_HOST_KEY_MISSING")
	}
	if len(request.Commands) != len(designerSafeModeCommands) {
		return fmt.Errorf("ITL_DESIGNER_AGENT_COMMANDS_INVALID: expected the fixed Vanessa safe-mode command sequence")
	}
	for index := range designerSafeModeCommands {
		if request.Commands[index] != designerSafeModeCommands[index] {
			return fmt.Errorf("ITL_DESIGNER_AGENT_COMMANDS_INVALID: command %d is outside the fixed Vanessa safe-mode contract", index+1)
		}
	}
	if request.ConnectTimeoutSeconds == 0 {
		request.ConnectTimeoutSeconds = 30
	}
	if request.CommandTimeoutSeconds == 0 {
		request.CommandTimeoutSeconds = 120
	}
	if request.ConnectTimeoutSeconds < 1 || request.ConnectTimeoutSeconds > 120 || request.CommandTimeoutSeconds < 1 || request.CommandTimeoutSeconds > 600 {
		return fmt.Errorf("ITL_DESIGNER_AGENT_TIMEOUT_INVALID")
	}
	return nil
}

func executeDesignerAgentRequest(ctx context.Context, request *designerAgentRequest) (*designerAgentResponse, error) {
	expectedKey, _, _, _, err := ssh.ParseAuthorizedKey([]byte(request.HostPublicKey))
	if err != nil {
		return nil, fmt.Errorf("ITL_DESIGNER_AGENT_HOST_KEY_INVALID: %w", err)
	}
	config := &ssh.ClientConfig{
		User: request.Username,
		Auth: []ssh.AuthMethod{ssh.Password(request.Password)},
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			if !bytes.Equal(key.Marshal(), expectedKey.Marshal()) {
				return fmt.Errorf("host key mismatch: expected %s, actual %s", ssh.FingerprintSHA256(expectedKey), ssh.FingerprintSHA256(key))
			}
			return nil
		},
		Timeout: time.Duration(request.ConnectTimeoutSeconds) * time.Second,
	}

	address := net.JoinHostPort(request.Host, strconv.Itoa(request.Port))
	dialer := net.Dialer{Timeout: config.Timeout}
	connection, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return nil, fmt.Errorf("ITL_DESIGNER_AGENT_CONNECT_FAILED: %w", err)
	}
	defer connection.Close()
	clientConnection, channels, requests, err := ssh.NewClientConn(connection, address, config)
	if err != nil {
		return nil, fmt.Errorf("ITL_DESIGNER_AGENT_SSH_FAILED: %w", err)
	}
	client := ssh.NewClient(clientConnection, channels, requests)
	defer client.Close()
	session, err := client.NewSession()
	if err != nil {
		return nil, fmt.Errorf("ITL_DESIGNER_AGENT_SESSION_FAILED: %w", err)
	}
	defer session.Close()
	session.Stderr = io.Discard
	stdin, err := session.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("ITL_DESIGNER_AGENT_SESSION_FAILED: %w", err)
	}
	stdout, err := session.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("ITL_DESIGNER_AGENT_SESSION_FAILED: %w", err)
	}
	if err := session.RequestPty("xterm", 80, 40, ssh.TerminalModes{ssh.ECHO: 0}); err != nil {
		return nil, fmt.Errorf("ITL_DESIGNER_AGENT_SESSION_FAILED: %w", err)
	}
	if err := session.Shell(); err != nil {
		return nil, fmt.Errorf("ITL_DESIGNER_AGENT_SESSION_FAILED: %w", err)
	}
	reader := bufio.NewReader(stdout)
	if err := connection.SetDeadline(time.Now().Add(time.Duration(request.CommandTimeoutSeconds) * time.Second)); err != nil {
		return nil, err
	}
	if _, err := readDesignerPrompt(reader, false); err != nil {
		return nil, fmt.Errorf("ITL_DESIGNER_AGENT_PROMPT_FAILED: %w", err)
	}
	if _, err := io.WriteString(stdin, "options set --output-format=json\r\n"); err != nil {
		return nil, fmt.Errorf("ITL_DESIGNER_AGENT_WRITE_FAILED: %w", err)
	}
	formatOutput, err := readDesignerPrompt(reader, false)
	if err != nil {
		return nil, fmt.Errorf("ITL_DESIGNER_AGENT_FORMAT_FAILED: %w", err)
	}
	if _, err := parseDesignerMessages(formatOutput); err != nil {
		return nil, fmt.Errorf("ITL_DESIGNER_AGENT_FORMAT_FAILED: %w", err)
	}

	response := &designerAgentResponse{Success: true}
	for index, command := range request.Commands {
		if err := connection.SetDeadline(time.Now().Add(time.Duration(request.CommandTimeoutSeconds) * time.Second)); err != nil {
			return nil, err
		}
		if _, err := io.WriteString(stdin, command+"\r\n"); err != nil {
			return nil, fmt.Errorf("ITL_DESIGNER_AGENT_WRITE_FAILED: command %d: %w", index+1, err)
		}
		allowEOF := command == "common shutdown"
		commandOutput, err := readDesignerPrompt(reader, allowEOF)
		if err != nil {
			return nil, fmt.Errorf("ITL_DESIGNER_AGENT_COMMAND_FAILED: command %d: %w", index+1, err)
		}
		messages, err := parseDesignerMessages(commandOutput)
		if err != nil {
			return nil, fmt.Errorf("ITL_DESIGNER_AGENT_COMMAND_FAILED: command %d: %w", index+1, err)
		}
		for _, message := range messages {
			if designerMessageRejectsCommand(message) {
				return nil, fmt.Errorf("ITL_DESIGNER_AGENT_COMMAND_REJECTED: command %d returned %s: %s", index+1, message.Type, message.Message)
			}
		}
		response.Commands = append(response.Commands, designerAgentCommandResult{Command: command, Messages: messages})
	}
	_ = connection.SetDeadline(time.Time{})
	return response, nil
}

func designerMessageRejectsCommand(message designerAgentMessage) bool {
	switch strings.ToLower(message.Type) {
	case "error", "canceled", "question":
		return true
	default:
		return false
	}
}

func readDesignerPrompt(reader *bufio.Reader, allowEOF bool) ([]byte, error) {
	const prompt = "designer>"
	var output bytes.Buffer
	for {
		value, err := reader.ReadByte()
		if err != nil {
			if allowEOF && errors.Is(err, io.EOF) && output.Len() > 0 {
				return output.Bytes(), nil
			}
			return nil, err
		}
		output.WriteByte(value)
		if strings.HasSuffix(strings.TrimSpace(output.String()), prompt) {
			data := output.Bytes()
			return bytes.TrimSpace(data[:len(data)-len(prompt)]), nil
		}
	}
}

func parseDesignerMessages(output []byte) ([]designerAgentMessage, error) {
	start := bytes.IndexByte(output, '[')
	end := bytes.LastIndexByte(output, ']')
	if start < 0 || end < start {
		return nil, fmt.Errorf("Designer Agent returned no JSON result")
	}
	var messages []designerAgentMessage
	if err := json.Unmarshal(output[start:end+1], &messages); err != nil {
		return nil, fmt.Errorf("decode Designer Agent JSON result: %w", err)
	}
	if len(messages) == 0 {
		return nil, fmt.Errorf("Designer Agent returned an empty JSON result")
	}
	if strings.ToLower(messages[len(messages)-1].Type) != "success" {
		return nil, fmt.Errorf("Designer Agent result has no terminal success message")
	}
	return messages, nil
}
