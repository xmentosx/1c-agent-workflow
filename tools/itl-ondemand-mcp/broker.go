package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const brokerMarker = "ITL_ONDEMAND_RESULT="

type backendInfo struct {
	DatabaseAccess          *facadeDatabasePlan `json:"databaseAccess,omitempty"`
	SchemaVersion           int                 `json:"schemaVersion"`
	Status                  string              `json:"status"`
	Family                  string              `json:"family"`
	InstanceID              string              `json:"instanceId"`
	PID                     int                 `json:"pid"`
	ProcessStartedAt        string              `json:"processStartTime"`
	Port                    int                 `json:"port"`
	URL                     string              `json:"url"`
	BackendVersion          string              `json:"backendVersion"`
	CatalogSHA256           string              `json:"catalogSha256"`
	LogPath                 string              `json:"logPath"`
	TestClientProfile       string              `json:"testClientProfile"`
	TestClientPID           int                 `json:"testClientPid"`
	TestClientPort          int                 `json:"testClientPort"`
	TestClientState         string              `json:"testClientState"`
	TestClientReused        bool                `json:"testClientReused"`
	PreviousTestClientPID   int                 `json:"previousTestClientPid"`
	PreviousTestClientState string              `json:"previousTestClientState"`
}

type facadeDatabasePlan struct {
	SchemaVersion      int                  `json:"schemaVersion"`
	Family             string               `json:"family"`
	ProjectRoot        string               `json:"projectRoot"`
	InstanceID         string               `json:"instanceId"`
	Coordinator        string               `json:"coordinator"`
	Scope              string               `json:"scope"`
	WaitTimeoutSeconds float64              `json:"waitTimeoutSeconds"`
	Python             string               `json:"python"`
	Bases              []databaseConnection `json:"bases"`
	PrimaryBase        *databaseConnection  `json:"primaryBase"`
	TargetBase         databaseConnection   `json:"targetBase"`
	ServicePlan        json.RawMessage      `json:"servicePlan"`
	AuxiliaryContour   string               `json:"auxiliaryContour"`
	RuntimePresent     bool                 `json:"runtimePresent"`
}

type databaseInvocationKey struct{}
type databaseInvocation struct {
	SchemaVersion   int                  `json:"schemaVersion"`
	Proof           *databaseAccessProof `json:"proof"`
	Plan            *facadeDatabasePlan  `json:"plan"`
	ExpectedBackend *backendInfo         `json:"expectedBackend,omitempty"`
}

func withDatabaseInvocation(ctx context.Context, proof *databaseAccessProof, plan *facadeDatabasePlan) context.Context {
	return context.WithValue(ctx, databaseInvocationKey{}, &databaseInvocation{SchemaVersion: 1, Proof: proof, Plan: plan})
}

func preserveDatabaseInvocation(from, to context.Context) context.Context {
	if value, ok := from.Value(databaseInvocationKey{}).(*databaseInvocation); ok {
		return context.WithValue(to, databaseInvocationKey{}, value)
	}
	return to
}

func databaseBrokerEnvironment(ctx context.Context) ([]string, error) {
	result := []string{}
	for _, value := range os.Environ() {
		key, _, _ := strings.Cut(value, "=")
		if !strings.EqualFold(key, "ITL_DATABASE_ACCESS_CONTEXT") && !strings.EqualFold(key, "ITL_INFOBASE_ACCESS_LEASE") {
			result = append(result, value)
		}
	}
	if value, ok := ctx.Value(databaseInvocationKey{}).(*databaseInvocation); ok {
		encoded, err := json.Marshal(value)
		if err != nil {
			return nil, fmt.Errorf("ITL_ONDEMAND_DATABASE_CONTEXT_INVALID")
		}
		proof, err := json.Marshal(value.Proof)
		if err != nil {
			return nil, fmt.Errorf("ITL_ONDEMAND_DATABASE_CONTEXT_INVALID")
		}
		result = append(result, "ITL_DATABASE_ACCESS_CONTEXT="+string(encoded), "ITL_INFOBASE_ACCESS_LEASE="+string(proof))
	}
	return result, nil
}

type backendBroker interface {
	Ensure(context.Context) (*backendInfo, error)
	EnsureTestClient(context.Context) (*backendInfo, error)
	Recover(context.Context, *backendInfo, string) (*backendInfo, error)
	MarkRunning(context.Context, *backendInfo) (*backendInfo, error)
	Stop(context.Context) error
}

type powershellBroker struct {
	PowerShell        string
	HelperPath        string
	ProjectRoot       string
	Family            string
	InstanceID        string
	CatalogHash       string
	Timeout           time.Duration
	lastBackend       *backendInfo
	cleanupConfirmed  bool
	recoveryCandidate string
}

func (b *powershellBroker) Ensure(ctx context.Context) (*backendInfo, error) {
	b.cleanupConfirmed = false
	info, err := b.invoke(ctx, "ensure", nil)
	if err == nil && ((info.Status != "readiness" && info.Status != "running") || info.PID <= 0 || info.Port <= 0 || info.URL == "" || info.InstanceID != b.InstanceID || info.Family != b.Family) {
		err = fmt.Errorf("backend broker returned an invalid running instance")
	}
	if err != nil {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		_ = b.Stop(preserveDatabaseInvocation(ctx, cleanupCtx))
		return nil, err
	}
	b.lastBackend = info
	return info, nil
}

func (b *powershellBroker) DatabaseRuntimeRoot() string {
	return filepath.Clean(filepath.Join(filepath.Dir(b.HelperPath), "..", "..", "itl-remote-runner", "scripts"))
}

func (b *powershellBroker) DatabaseAccessPlan(ctx context.Context) (*facadeDatabasePlan, error) {
	info, err := b.invoke(ctx, "access-plan", nil)
	if err != nil {
		return nil, err
	}
	if info.DatabaseAccess == nil || info.Status != "planned" || info.DatabaseAccess.SchemaVersion != 1 ||
		info.DatabaseAccess.Family != b.Family || info.DatabaseAccess.InstanceID != b.InstanceID ||
		info.DatabaseAccess.Coordinator == "" || len(info.DatabaseAccess.Bases) == 0 {
		return nil, fmt.Errorf("ITL_ONDEMAND_DATABASE_PLAN_INVALID")
	}
	return info.DatabaseAccess, nil
}

func (b *powershellBroker) EnsureTestClient(ctx context.Context) (*backendInfo, error) {
	b.cleanupConfirmed = false
	info, err := b.invoke(ctx, "ensure-test-client", nil)
	if err == nil && (info.Status != "running" || info.PID <= 0 || info.URL == "" ||
		info.InstanceID != b.InstanceID || info.Family != "vanessa-ui" ||
		info.TestClientPID <= 0 || info.TestClientPort <= 0 || info.TestClientState != testClientPortReady) {
		err = fmt.Errorf("backend broker returned an invalid ready TestClient")
	}
	if err != nil {
		return nil, err
	}
	b.lastBackend = info
	return info, nil
}

func (b *powershellBroker) Recover(ctx context.Context, previous *backendInfo, replacementInstanceID string) (*backendInfo, error) {
	if previous == nil || previous.InstanceID != b.InstanceID || previous.PID <= 0 || previous.Port <= 0 {
		return nil, fmt.Errorf("backend recovery requires the registered instance PID and port")
	}
	b.cleanupConfirmed = false
	b.recoveryCandidate = replacementInstanceID
	info, err := b.invoke(ctx, "recover", []string{
		"-InternalOnDemandReplacementInstanceId", replacementInstanceID,
		"-InternalOnDemandExpectedPid", fmt.Sprint(previous.PID),
		"-InternalOnDemandExpectedPort", fmt.Sprint(previous.Port),
	})
	if err == nil && ((info.Status != "readiness" && info.Status != "running") || info.PID <= 0 || info.Port <= 0 || info.URL == "" || info.InstanceID != replacementInstanceID || info.Family != b.Family) {
		err = fmt.Errorf("backend broker returned an invalid recovered instance")
	}
	if err != nil {
		return nil, err
	}
	b.InstanceID = replacementInstanceID
	b.recoveryCandidate = ""
	b.lastBackend = info
	return info, nil
}

func (b *powershellBroker) MarkRunning(ctx context.Context, previous *backendInfo) (*backendInfo, error) {
	if previous == nil || previous.InstanceID != b.InstanceID || previous.PID <= 0 || previous.Port <= 0 {
		return nil, fmt.Errorf("backend readiness confirmation requires the registered instance PID and port")
	}
	info, err := b.invoke(ctx, "mark-running", []string{
		"-InternalOnDemandExpectedPid", fmt.Sprint(previous.PID),
		"-InternalOnDemandExpectedPort", fmt.Sprint(previous.Port),
	})
	if err == nil && (info.Status != "running" || info.PID != previous.PID || info.Port != previous.Port || info.InstanceID != b.InstanceID || info.Family != b.Family) {
		err = fmt.Errorf("backend broker returned an invalid protocol-ready instance")
	}
	if err != nil {
		return nil, err
	}
	b.lastBackend = info
	return info, nil
}

func (b *powershellBroker) Stop(ctx context.Context) error {
	if b.cleanupConfirmed {
		return nil
	}
	ids := []string{b.InstanceID}
	if b.recoveryCandidate != "" && b.recoveryCandidate != b.InstanceID {
		ids = append(ids, b.recoveryCandidate)
	}
	var failures []error
	for _, id := range ids {
		extra := []string{}
		stopCtx := ctx
		if invocation, coordinated := ctx.Value(databaseInvocationKey{}).(*databaseInvocation); coordinated {
			pid, port := -1, 0
			if b.lastBackend != nil && b.lastBackend.InstanceID == id {
				pid, port = b.lastBackend.PID, b.lastBackend.Port
				copy := *invocation
				copy.ExpectedBackend = b.lastBackend
				stopCtx = context.WithValue(ctx, databaseInvocationKey{}, &copy)
			}
			extra = append(extra, "-InternalOnDemandExpectedPid", fmt.Sprint(pid), "-InternalOnDemandExpectedPort", fmt.Sprint(port))
		}
		target := *b
		target.InstanceID = id
		info, err := target.invoke(stopCtx, "stop", extra)
		if err != nil {
			failures = append(failures, err)
			continue
		}
		if info.Status != "stopped" {
			failures = append(failures, fmt.Errorf("ITL_ONDEMAND_STOP_UNCONFIRMED"))
		}
	}
	if len(failures) != 0 {
		return errors.Join(failures...)
	}
	b.cleanupConfirmed, b.lastBackend, b.recoveryCandidate = true, nil, ""
	return nil
}

func (b *powershellBroker) invoke(ctx context.Context, operation string, extra []string) (*backendInfo, error) {
	timeout := brokerCallTimeout(ctx, b.Timeout)
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
	environment, environmentErr := databaseBrokerEnvironment(ctx)
	if environmentErr != nil {
		return nil, environmentErr
	}
	cmd.Env = environment
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
