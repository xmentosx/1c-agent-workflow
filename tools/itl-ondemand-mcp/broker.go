package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

const brokerMarker = "ITL_ONDEMAND_RESULT="

type backendInfo struct {
	SchemaVersion           int    `json:"schemaVersion"`
	Status                  string `json:"status"`
	Family                  string `json:"family"`
	InstanceID              string `json:"instanceId"`
	PID                     int    `json:"pid"`
	ProcessStartedAt        string `json:"processStartTime"`
	Port                    int    `json:"port"`
	URL                     string `json:"url"`
	BackendVersion          string `json:"backendVersion"`
	CatalogSHA256           string `json:"catalogSha256"`
	LogPath                 string `json:"logPath"`
	TestClientProfile       string `json:"testClientProfile"`
	TestClientPID           int    `json:"testClientPid"`
	TestClientPort          int    `json:"testClientPort"`
	TestClientState         string `json:"testClientState"`
	TestClientReused        bool   `json:"testClientReused"`
	PreviousTestClientPID   int    `json:"previousTestClientPid"`
	PreviousTestClientState string `json:"previousTestClientState"`
}

type backendBroker interface {
	Ensure(context.Context) (*backendInfo, error)
	EnsureTestClient(context.Context) (*backendInfo, error)
	Recover(context.Context, *backendInfo, string) (*backendInfo, error)
	Stop(context.Context) error
}

type powershellBroker struct {
	PowerShell  string
	HelperPath  string
	ProjectRoot string
	Family      string
	InstanceID  string
	CatalogHash string
	Timeout     time.Duration
}

func (b *powershellBroker) Ensure(ctx context.Context) (*backendInfo, error) {
	info, err := b.invoke(ctx, "ensure", nil)
	if err == nil && (info.Status != "running" || info.PID <= 0 || info.URL == "" || info.InstanceID != b.InstanceID || info.Family != b.Family) {
		err = fmt.Errorf("backend broker returned an invalid running instance")
	}
	if err != nil {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		_, _ = b.invoke(cleanupCtx, "stop", nil)
		return nil, err
	}
	return info, nil
}

func (b *powershellBroker) EnsureTestClient(ctx context.Context) (*backendInfo, error) {
	info, err := b.invoke(ctx, "ensure-test-client", nil)
	if err == nil && (info.Status != "running" || info.PID <= 0 || info.URL == "" ||
		info.InstanceID != b.InstanceID || info.Family != "vanessa-ui" ||
		info.TestClientPID <= 0 || info.TestClientPort <= 0 || info.TestClientState != testClientPortReady) {
		err = fmt.Errorf("backend broker returned an invalid ready TestClient")
	}
	if err != nil {
		return nil, err
	}
	return info, nil
}

func (b *powershellBroker) Recover(ctx context.Context, previous *backendInfo, replacementInstanceID string) (*backendInfo, error) {
	if previous == nil || previous.InstanceID != b.InstanceID || previous.PID <= 0 || previous.Port <= 0 {
		return nil, fmt.Errorf("backend recovery requires the registered instance PID and port")
	}
	info, err := b.invoke(ctx, "recover", []string{
		"-InternalOnDemandReplacementInstanceId", replacementInstanceID,
		"-InternalOnDemandExpectedPid", fmt.Sprint(previous.PID),
		"-InternalOnDemandExpectedPort", fmt.Sprint(previous.Port),
	})
	if err == nil && (info.Status != "running" || info.PID <= 0 || info.Port <= 0 || info.URL == "" || info.InstanceID != replacementInstanceID || info.Family != b.Family) {
		err = fmt.Errorf("backend broker returned an invalid recovered instance")
	}
	if err != nil {
		return nil, err
	}
	b.InstanceID = replacementInstanceID
	return info, nil
}

func (b *powershellBroker) Stop(ctx context.Context) error {
	_, err := b.invoke(ctx, "stop", nil)
	return err
}

func (b *powershellBroker) invoke(ctx context.Context, operation string, extra []string) (*backendInfo, error) {
	timeout := b.Timeout
	if timeout == 0 {
		timeout = 5 * time.Minute
	}
	callCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	command := b.PowerShell
	if command == "" {
		command = "powershell.exe"
	}
	args := []string{
		"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", b.HelperPath,
		"-ProjectRoot", b.ProjectRoot,
		"-InternalOnDemandOperation", operation,
		"-InternalOnDemandFamily", b.Family,
		"-InternalOnDemandInstanceId", b.InstanceID,
		"-InternalOnDemandCatalogSha256", b.CatalogHash,
	}
	args = append(args, extra...)
	cmd := exec.CommandContext(callCtx, command, args...)
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	err := cmd.Run()
	info, parseErr := parseBrokerOutput(output.String())
	if err != nil {
		if parseErr == nil && info != nil && info.Status == "failed" {
			return nil, fmt.Errorf("backend broker failed; log=%s", info.LogPath)
		}
		return nil, fmt.Errorf("backend broker %s failed: %w: %s", operation, err, strings.TrimSpace(output.String()))
	}
	if parseErr != nil {
		return nil, parseErr
	}
	return info, nil
}

func parseBrokerOutput(output string) (*backendInfo, error) {
	index := strings.LastIndex(output, brokerMarker)
	if index < 0 {
		return nil, fmt.Errorf("backend broker did not emit %s", brokerMarker)
	}
	line := output[index+len(brokerMarker):]
	if end := strings.IndexAny(line, "\r\n"); end >= 0 {
		line = line[:end]
	}
	var info backendInfo
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &info); err != nil {
		return nil, fmt.Errorf("decode backend broker result: %w", err)
	}
	return &info, nil
}
