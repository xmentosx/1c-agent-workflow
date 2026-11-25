package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

const projectTestsSafeModeOperation = "project-tests-safe-mode"
const projectTestsCapabilityDomain = "ITL_PROJECT_TESTS_SAFE_MODE_V1\x00"

var projectTestsNamePattern = regexp.MustCompile(`^[\p{L}_][\p{L}\p{M}\p{Nd}_]*$`)
var projectTestsSHA256Pattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
var projectTestsProcessStartPattern = regexp.MustCompile(`^[a-f0-9]{16}$`)

// A transient helper attestation, bound to the existing live execution context.
// It grants no arbitrary Designer commands and creates no authorization registry.
type projectTestsCapability struct {
	PayloadBase64 string `json:"payloadBase64"`
	Signature     string `json:"signature"`
}

type projectTestsClaims struct {
	SchemaVersion          int                    `json:"schemaVersion"`
	Operation              string                 `json:"operation"`
	ProjectRoot            string                 `json:"projectRoot"`
	HelperRoot             string                 `json:"helperRoot"`
	RegisteredName         string                 `json:"registeredName"`
	ExtensionName          string                 `json:"extensionName"`
	OptIn                  *bool                  `json:"optIn"`
	SourceFingerprint      string                 `json:"sourceFingerprint"`
	RuntimeContentHash     string                 `json:"runtimeContentHash"`
	UnsafeActionProtection *bool                  `json:"unsafeActionProtection"`
	Base                   databaseConnection     `json:"base"`
	Designer               profileProcessIdentity `json:"designer"`
	Port                   int                    `json:"port"`
	HostPublicKeySHA256    string                 `json:"hostPublicKeySha256"`
	ExecutionContextSHA256 string                 `json:"executionContextSha256"`
	GuardRoot              string                 `json:"guardRoot"`
	GuardRuntimeRoot       string                 `json:"guardRuntimeRoot"`
	GuardPython            string                 `json:"guardPython"`
}

func projectTestsCommands(name string) []string {
	return []string{
		"common connect-ib",
		"config extensions properties set --extension " + name + " --safe-mode no",
		"config extensions properties get --extension " + name,
		"common disconnect-ib",
		"common shutdown",
	}
}

func projectTestsTextSHA256(value string) string {
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:])
}

func verifyProjectTestsCapability(request *designerAgentRequest) (*projectTestsClaims, error) {
	envelope := request.ProjectTestsCapability
	if envelope == nil {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_CAPABILITY_REQUIRED")
	}
	encodedContext, encodedKey := os.Getenv("ITL_EXECUTION_CONTEXT"), os.Getenv("ITL_EXECUTION_CONTEXT_KEY")
	if encodedContext == "" || encodedKey == "" {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_EXECUTION_CONTEXT_REQUIRED")
	}
	key, err := base64.URLEncoding.DecodeString(encodedKey)
	if err != nil || len(key) != 32 {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_EXECUTION_CONTEXT_KEY_INVALID")
	}
	payload, err := base64.StdEncoding.DecodeString(envelope.PayloadBase64)
	if err != nil || len(payload) > designerAgentInputLimit || !utf8.Valid(payload) {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_CAPABILITY_PAYLOAD_INVALID")
	}
	signature, err := hex.DecodeString(envelope.Signature)
	if err != nil || len(signature) != sha256.Size {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_CAPABILITY_SIGNATURE_INVALID")
	}
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(projectTestsCapabilityDomain))
	_, _ = mac.Write(payload)
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_CAPABILITY_SIGNATURE_INVALID")
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	var claims projectTestsClaims
	if err := decoder.Decode(&claims); err != nil {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_CAPABILITY_PAYLOAD_INVALID: %w", err)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_CAPABILITY_PAYLOAD_INVALID: expected one object")
	}
	if claims.SchemaVersion != 1 || claims.Operation != projectTestsSafeModeOperation ||
		claims.OptIn == nil || !*claims.OptIn || claims.UnsafeActionProtection == nil {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_CAPABILITY_SCOPE_INVALID")
	}
	if !projectTestsNamePattern.MatchString(claims.ExtensionName) || claims.RegisteredName != claims.ExtensionName {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_EXTENSION_NAME_INVALID")
	}
	for _, reserved := range []string{"client_mcp", "VAExtension", "YAXUNIT"} {
		if strings.EqualFold(claims.ExtensionName, reserved) {
			return nil, fmt.Errorf("ITL_PROJECT_TESTS_EXTENSION_NAME_INVALID: reserved tooling role")
		}
	}
	if !projectTestsSHA256Pattern.MatchString(claims.SourceFingerprint) || strings.TrimSpace(claims.RuntimeContentHash) == "" {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_CONTENT_PROOF_REQUIRED")
	}
	if !filepath.IsAbs(claims.ProjectRoot) || !filepath.IsAbs(claims.HelperRoot) || !filepath.IsAbs(claims.GuardRoot) ||
		!strings.EqualFold(filepath.Clean(claims.GuardRuntimeRoot), filepath.Join(filepath.Clean(claims.HelperRoot),
			".agents", "skills", "itl-remote-runner", "scripts")) {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_GUARD_TARGET_INVALID")
	}
	if (claims.Base.Kind != "file" && claims.Base.Kind != "server") || strings.TrimSpace(claims.Base.Path) == "" ||
		(claims.Base.Kind == "file" && !filepath.IsAbs(claims.Base.Path)) {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_BASE_INVALID")
	}
	if claims.Designer.PID <= 0 || !projectTestsProcessStartPattern.MatchString(claims.Designer.Started) ||
		!filepath.IsAbs(claims.Designer.Executable) || claims.Port != request.Port ||
		claims.HostPublicKeySHA256 != projectTestsTextSHA256(strings.TrimSpace(request.HostPublicKey)) ||
		claims.ExecutionContextSHA256 != projectTestsTextSHA256(encodedContext) {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_OWNER_PROOF_INVALID")
	}
	return &claims, nil
}

func acquireProjectTestsDesignerGuard(ctx context.Context, request *designerAgentRequest) (*executionGuardOwner, error) {
	claims := request.authorizedProjectTests
	if claims == nil {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_CAPABILITY_REQUIRED")
	}
	// Inheritance is mandatory. This path cannot acquire another resource or
	// turn a missing/expired parent context into a fresh admission.
	encodedContext, encodedKey := os.Getenv("ITL_EXECUTION_CONTEXT"), os.Getenv("ITL_EXECUTION_CONTEXT_KEY")
	if encodedContext == "" || encodedKey == "" || claims.ExecutionContextSHA256 != projectTestsTextSHA256(encodedContext) {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_EXECUTION_CONTEXT_REQUIRED")
	}
	id, err := newExecutionID()
	if err != nil {
		return nil, err
	}
	admissionContext, cancel := context.WithTimeout(ctx, time.Duration(request.ConnectTimeoutSeconds)*time.Second)
	defer cancel()
	owner, err := acquireExecutionGuard(admissionContext, claims.GuardPython, claims.GuardRuntimeRoot, executionGuardRequest{
		SchemaVersion: 1, Root: claims.GuardRoot, Bases: []databaseConnection{claims.Base},
		Operation: projectTestsSafeModeOperation, ExecutionID: id, Timeout: float64(request.ConnectTimeoutSeconds),
		InheritedContext: encodedContext, InheritedContextKey: encodedKey,
	}, nil)
	if err != nil {
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_EXECUTION_CONTEXT_INVALID: %w", err)
	}
	actual, err := readProfileProcessIdentity(claims.Designer.PID)
	if err != nil {
		_ = owner.Close()
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_DESIGNER_OWNER_UNVERIFIED: %w", err)
	}
	if actual.PID != claims.Designer.PID || actual.Started != claims.Designer.Started ||
		!strings.EqualFold(filepath.Clean(actual.Executable), filepath.Clean(claims.Designer.Executable)) {
		_ = owner.Close()
		return nil, fmt.Errorf("ITL_PROJECT_TESTS_DESIGNER_OWNER_CHANGED")
	}
	return owner, nil
}
