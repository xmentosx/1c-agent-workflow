package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	goruntime "runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

func projectTestsRequestFixture(t *testing.T) (*designerAgentRequest, projectTestsClaims) {
	t.Helper()
	projectRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	optIn, protection := true, true
	request := &designerAgentRequest{Host: "127.0.0.1", Port: 1543, HostPublicKey: "fixture-key"}
	claims := projectTestsClaims{SchemaVersion: 1, Operation: "project-tests-safe-mode", ProjectRoot: projectRoot, HelperRoot: projectRoot,
		RegisteredName: "ТестыPM5Канбан", ExtensionName: "ТестыPM5Канбан", OptIn: &optIn,
		SourceFingerprint: strings.Repeat("a", 64), RuntimeContentHash: "opaque-native-content-hash", UnsafeActionProtection: &protection,
		Base:     databaseConnection{Kind: "file", Path: filepath.Join(t.TempDir(), "База с пробелом")},
		Designer: profileProcessIdentity{PID: os.Getpid(), Started: "0000000000000001", Executable: executable},
		Port:     request.Port, HostPublicKeySHA256: projectTestsTextSHA256(request.HostPublicKey),
		ExecutionContextSHA256: projectTestsTextSHA256(os.Getenv("ITL_EXECUTION_CONTEXT")),
		GuardRoot:              filepath.Join(t.TempDir(), "guard root"),
		GuardRuntimeRoot:       filepath.Join(projectRoot, ".agents", "skills", "itl-remote-runner", "scripts")}
	return request, claims
}

func signProjectTestsFixture(t *testing.T, request *designerAgentRequest, claims projectTestsClaims) {
	t.Helper()
	payload, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	signProjectTestsPayloadFixture(t, request, payload)
}

func signProjectTestsPayloadFixture(t *testing.T, request *designerAgentRequest, payload []byte) {
	t.Helper()
	key, err := base64.URLEncoding.DecodeString(os.Getenv("ITL_EXECUTION_CONTEXT_KEY"))
	if err != nil {
		t.Fatal(err)
	}
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte("ITL_PROJECT_TESTS_SAFE_MODE_V1\x00"))
	_, _ = mac.Write(payload)
	request.ProjectTestsCapability = &projectTestsCapability{
		PayloadBase64: base64.StdEncoding.EncodeToString(payload), Signature: hex.EncodeToString(mac.Sum(nil))}
}

func TestProjectTestsCapabilityGeneratesOnlyTheRegisteredUnicodeSafeModeSequence(t *testing.T) {
	t.Setenv("ITL_EXECUTION_CONTEXT", "fixture-context")
	t.Setenv("ITL_EXECUTION_CONTEXT_KEY", base64.URLEncoding.EncodeToString([]byte(strings.Repeat("k", 32))))
	for _, name := range []string{"tests", "ТестыPM5Канбан"} {
		request, claims := projectTestsRequestFixture(t)
		// Master-runtime helpers may legitimately operate a branch worktree.
		claims.ProjectRoot = filepath.Join(t.TempDir(), "Рабочая ветка с пробелом")
		claims.ExtensionName, claims.RegisteredName = name, name
		signProjectTestsFixture(t, request, claims)
		if err := validateDesignerAgentRequest(request); err != nil {
			t.Fatal(err)
		}
		want := []string{"common connect-ib", "config extensions properties set --extension " + name + " --safe-mode no",
			"config extensions properties get --extension " + name, "common disconnect-ib", "common shutdown"}
		if !equalDesignerCommands(request.Commands, want) {
			t.Fatalf("unexpected commands: %#v", request.Commands)
		}
		if strings.Contains(strings.Join(request.Commands, "\n"), "unsafe-action-protection") {
			t.Fatal("project capability modified unsafe-action protection")
		}
		get := want[2]
		if !designerRequestAcceptsTerminalType(request, get, "extension-properties") ||
			designerRequestAcceptsTerminalType(request, get, "success") ||
			designerRequestAcceptsTerminalType(request, want[1], "extension-properties") {
			t.Fatal("terminal type was not correlated to the exact project properties get")
		}
	}
}

func TestProjectTestsCapabilityRejectsTamperingAndMalformedScopeBeforeExecution(t *testing.T) {
	t.Setenv("ITL_EXECUTION_CONTEXT", "fixture-context")
	t.Setenv("ITL_EXECUTION_CONTEXT_KEY", base64.URLEncoding.EncodeToString([]byte(strings.Repeat("k", 32))))
	cases := []struct {
		name, code string
		change     func(*designerAgentRequest, *projectTestsClaims)
	}{
		{"opt-out", "SCOPE_INVALID", func(_ *designerAgentRequest, c *projectTestsClaims) { *c.OptIn = false }},
		{"missing-opt-in", "SCOPE_INVALID", func(_ *designerAgentRequest, c *projectTestsClaims) { c.OptIn = nil }},
		{"missing-protection", "SCOPE_INVALID", func(_ *designerAgentRequest, c *projectTestsClaims) { c.UnsafeActionProtection = nil }},
		{"different-registration", "NAME_INVALID", func(_ *designerAgentRequest, c *projectTestsClaims) { c.RegisteredName = "ЧужиеТесты" }},
		{"wildcard", "NAME_INVALID", func(_ *designerAgentRequest, c *projectTestsClaims) {
			c.ExtensionName, c.RegisteredName = "Тесты*", "Тесты*"
		}},
		{"command-injection", "NAME_INVALID", func(_ *designerAgentRequest, c *projectTestsClaims) {
			c.ExtensionName, c.RegisteredName = "tests --unsafe-action-protection no", "tests --unsafe-action-protection no"
		}},
		{"reserved-role", "NAME_INVALID", func(_ *designerAgentRequest, c *projectTestsClaims) {
			c.ExtensionName, c.RegisteredName = "yaxunit", "yaxunit"
		}},
		{"missing-content", "CONTENT_PROOF_REQUIRED", func(_ *designerAgentRequest, c *projectTestsClaims) { c.RuntimeContentHash = "" }},
		{"foreign-helper", "GUARD_TARGET_INVALID", func(_ *designerAgentRequest, c *projectTestsClaims) {
			c.GuardRuntimeRoot = filepath.Join(t.TempDir(), "foreign")
		}},
		{"wrong-port", "OWNER_PROOF_INVALID", func(_ *designerAgentRequest, c *projectTestsClaims) { c.Port++ }},
		{"wrong-key", "OWNER_PROOF_INVALID", func(_ *designerAgentRequest, c *projectTestsClaims) { c.HostPublicKeySHA256 = strings.Repeat("b", 64) }},
		{"wrong-context", "OWNER_PROOF_INVALID", func(_ *designerAgentRequest, c *projectTestsClaims) {
			c.ExecutionContextSHA256 = strings.Repeat("b", 64)
		}},
		{"caller-commands", "COMMANDS_FORBIDDEN", func(r *designerAgentRequest, _ *projectTestsClaims) { r.Commands = []string{"common connect-ib"} }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			request, claims := projectTestsRequestFixture(t)
			test.change(request, &claims)
			signProjectTestsFixture(t, request, claims)
			if err := validateDesignerAgentRequest(request); err == nil || !strings.Contains(err.Error(), test.code) {
				t.Fatalf("wanted %s, got %v", test.code, err)
			}
		})
	}
	request, claims := projectTestsRequestFixture(t)
	signProjectTestsFixture(t, request, claims)
	request.ProjectTestsCapability.PayloadBase64 = base64.StdEncoding.EncodeToString([]byte(`{"optIn":true}`))
	if err := validateDesignerAgentRequest(request); err == nil || !strings.Contains(err.Error(), "SIGNATURE_INVALID") {
		t.Fatalf("tampered payload accepted: %v", err)
	}
	for _, payload := range []string{`{"commands":["common shutdown"]}`, `{} {}`, string([]byte{0xff})} {
		request, _ := projectTestsRequestFixture(t)
		signProjectTestsPayloadFixture(t, request, []byte(payload))
		if err := validateDesignerAgentRequest(request); err == nil || !strings.Contains(err.Error(), "PAYLOAD_INVALID") {
			t.Fatalf("malformed signed payload accepted: %v", err)
		}
	}
}

func TestProjectTestsCapabilityUsesTheLiveParentGuardAndPinnedSSHWithoutReleasingTheParent(t *testing.T) {
	if goruntime.GOOS != "windows" {
		t.Skip("native PID/start/EXE proof is Windows-only")
	}
	python, runtimeRoot, admission := executionGuardFixture(t)
	parent, err := acquireExecutionGuard(context.Background(), python, runtimeRoot, admission, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer parent.Close()
	t.Setenv("ITL_EXECUTION_CONTEXT", parent.Proof.Encoded)
	t.Setenv("ITL_EXECUTION_CONTEXT_KEY", parent.Proof.Key)
	address, key, received, stop := startDesignerAgentTestServer(t, "ib-user", "ib-password")
	defer stop()
	_, portText, _ := net.SplitHostPort(address)
	port, _ := strconv.Atoi(portText)
	request, claims := projectTestsRequestFixture(t)
	request.Port, request.HostPublicKey, request.Username, request.Password = port, key, "ib-user", "ib-password"
	claims.Port, claims.HostPublicKeySHA256 = port, projectTestsTextSHA256(strings.TrimSpace(key))
	claims.GuardRoot, claims.GuardRuntimeRoot, claims.GuardPython, claims.Base = admission.Root, runtimeRoot, python, admission.Bases[0]
	claims.Designer, err = readProfileProcessIdentity(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	signProjectTestsFixture(t, request, claims)
	if err := validateDesignerAgentRequest(request); err != nil {
		t.Fatal(err)
	}
	if _, err := executeDesignerAgentRequest(context.Background(), request); err != nil {
		t.Fatal(err)
	}
	for _, command := range request.Commands {
		if actual := <-received; actual != command {
			t.Fatalf("unexpected SSH command: %q", actual)
		}
	}
	contender := admission
	contender.ExecutionID, contender.Timeout = strings.Repeat("c", 32), 0.1
	blocked, err := acquireExecutionGuard(context.Background(), python, runtimeRoot, contender, nil)
	if err == nil {
		_ = blocked.Close()
		t.Fatal("project child released its parent's infobase guard")
	}
	if err := parent.Release(context.Background(), "succeeded", ""); err != nil {
		t.Fatal(err)
	}
	contender.ExecutionID, contender.Timeout = strings.Repeat("d", 32), 2
	next, err := acquireExecutionGuard(context.Background(), python, runtimeRoot, contender, nil)
	if err != nil {
		t.Fatalf("parent could not release its own guard: %v", err)
	}
	_ = next.Close()
}

func TestProjectTestsCapabilityRejectsForeignTargetExpiredParentAndChangedDesignerBeforeSSH(t *testing.T) {
	if goruntime.GOOS != "windows" {
		t.Skip("native process identity is Windows-only")
	}
	python, runtimeRoot, admission := executionGuardFixture(t)
	parent, err := acquireExecutionGuard(context.Background(), python, runtimeRoot, admission, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer parent.Close()
	t.Setenv("ITL_EXECUTION_CONTEXT", parent.Proof.Encoded)
	t.Setenv("ITL_EXECUTION_CONTEXT_KEY", parent.Proof.Key)
	for _, test := range []struct {
		name, code string
		change     func(*projectTestsClaims)
	}{
		{"foreign-base", "EXECUTION_CONTEXT_INVALID", func(c *projectTestsClaims) { c.Base.Path += " foreign" }},
		{"wrong-pid", "DESIGNER_OWNER_UNVERIFIED", func(c *projectTestsClaims) { c.Designer.PID = 2000000000 }},
		{"wrong-start", "DESIGNER_OWNER_CHANGED", func(c *projectTestsClaims) { c.Designer.Started = "0000000000000001" }},
		{"wrong-exe", "DESIGNER_OWNER_CHANGED", func(c *projectTestsClaims) { c.Designer.Executable += ".foreign.exe" }},
	} {
		t.Run(test.name, func(t *testing.T) {
			request, claims := projectTestsRequestFixture(t)
			claims.GuardRoot, claims.GuardRuntimeRoot, claims.GuardPython, claims.Base = admission.Root, runtimeRoot, python, admission.Bases[0]
			claims.Designer, err = readProfileProcessIdentity(os.Getpid())
			if err != nil {
				t.Fatal(err)
			}
			test.change(&claims)
			signProjectTestsFixture(t, request, claims)
			if err := validateDesignerAgentRequest(request); err != nil {
				t.Fatal(err)
			}
			if _, err := executeDesignerAgentRequest(context.Background(), request); err == nil || !strings.Contains(err.Error(), test.code) {
				t.Fatalf("expected %s before SSH, got %v", test.code, err)
			}
		})
	}
	request, claims := projectTestsRequestFixture(t)
	claims.GuardRoot, claims.GuardRuntimeRoot, claims.GuardPython, claims.Base = admission.Root, runtimeRoot, python, admission.Bases[0]
	claims.Designer, err = readProfileProcessIdentity(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	signProjectTestsFixture(t, request, claims)
	if err := validateDesignerAgentRequest(request); err != nil {
		t.Fatal(err)
	}
	if err := parent.Release(context.Background(), "succeeded", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := executeDesignerAgentRequest(context.Background(), request); err == nil || !strings.Contains(err.Error(), "EXECUTION_CONTEXT_INVALID") {
		t.Fatalf("expired parent must not become a new admission: %v", err)
	}
	// The private authorization cannot be reused without its live environment.
	t.Setenv("ITL_EXECUTION_CONTEXT", "")
	if _, err := executeDesignerAgentRequest(context.Background(), request); err == nil || !strings.Contains(err.Error(), "EXECUTION_CONTEXT_REQUIRED") {
		t.Fatalf("missing parent context accepted: %v", err)
	}
}

func TestProjectTestsCapabilityPowerShell51FactoryUnicodeRoundTrip(t *testing.T) {
	if goruntime.GOOS != "windows" {
		t.Skip("PowerShell 5.1 factory is Windows-only")
	}
	t.Setenv("ITL_EXECUTION_CONTEXT", "cross-language-parent-context")
	t.Setenv("ITL_EXECUTION_CONTEXT_KEY", base64.URLEncoding.EncodeToString([]byte(strings.Repeat("k", 32))))
	request, claims := projectTestsRequestFixture(t)
	projectRoot := filepath.Join(t.TempDir(), "Проект с пробелом")
	testsPath := filepath.Join(projectRoot, "tests", "yaxunit")
	if err := os.MkdirAll(testsPath, 0700); err != nil {
		t.Fatal(err)
	}
	metadata := `<MetaDataObject><Configuration><Properties><Name>ТестыPM5Канбан</Name></Properties></Configuration></MetaDataObject>`
	if err := os.WriteFile(filepath.Join(testsPath, "Configuration.xml"), []byte(metadata), 0600); err != nil {
		t.Fatal(err)
	}
	fixture := map[string]any{"projectRoot": projectRoot, "base": claims.Base, "fingerprint": claims.SourceFingerprint,
		"guardRoot": claims.GuardRoot, "python": "python", "hostPublicKey": request.HostPublicKey, "port": request.Port}
	fixtureBytes, err := json.Marshal(fixture)
	if err != nil {
		t.Fatal(err)
	}
	fixturePath, resultPath, scriptPath := filepath.Join(projectRoot, "fixture.json"), filepath.Join(projectRoot, "result.json"), filepath.Join(projectRoot, "Подпись capability.ps1")
	if err := os.WriteFile(fixturePath, fixtureBytes, 0600); err != nil {
		t.Fatal(err)
	}
	script := `param([string]$RepoRoot,[string]$FixturePath,[string]$ResultPath)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -ProjectRoot $RepoRoot -Action help *> $null
$script:factoryFixture=Get-Content -LiteralPath $FixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:ProjectRoot=$script:factoryFixture.projectRoot
$script:Config='{"yaxunit":{"testsDisableSafeMode":true,"testsExtensionName":"ТестыPM5Канбан","testsPath":"tests/yaxunit"}}' | ConvertFrom-Json
function Get-ConfigSourceFingerprint { [pscustomobject]@{fingerprint=$script:factoryFixture.fingerprint} }
function Get-OneCExecutionGuardSettings { [pscustomobject]@{root=$script:factoryFixture.guardRoot;python=$script:factoryFixture.python} }
$state=[pscustomobject]@{infoBaseKind=$script:factoryFixture.base.kind;devBranchInfoBasePath=$script:factoryFixture.base.path}
$proof=[pscustomobject]@{sourceFingerprint=$script:factoryFixture.fingerprint;runtimeContentHash='native-Хэш';unsafeActionProtection=$true;executionContextSha256=(Get-StringSha256 $env:ITL_EXECUTION_CONTEXT)}
$process=[Diagnostics.Process]::GetCurrentProcess()
$cap=New-ProjectTestsDesignerCapability -State $state -InfoBaseKind $state.infoBaseKind -InfoBasePath $state.devBranchInfoBasePath -ExtensionName 'ТестыPM5Канбан' -ContentProof $proof -Process $process -Port $script:factoryFixture.port -HostPublicKey $script:factoryFixture.hostPublicKey
[IO.File]::WriteAllText($ResultPath,($cap | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
`
	if err := os.WriteFile(scriptPath, append([]byte{0xef, 0xbb, 0xbf}, []byte(script)...), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", scriptPath, "-RepoRoot", claims.HelperRoot, "-FixturePath", fixturePath, "-ResultPath", resultPath)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("factory failed: %v: %s", err, output)
	}
	result, err := os.ReadFile(resultPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(result, &request.ProjectTestsCapability); err != nil {
		t.Fatal(err)
	}
	if err := validateDesignerAgentRequest(request); err != nil {
		t.Fatalf("PS5 UTF8 HMAC rejected: %v", err)
	}
	actual := request.authorizedProjectTests
	if actual.ProjectRoot != projectRoot || actual.HelperRoot != claims.HelperRoot || actual.ExtensionName != "ТестыPM5Канбан" || actual.RuntimeContentHash != "native-Хэш" || !*actual.UnsafeActionProtection {
		t.Fatalf("cross-language scope changed: %+v", actual)
	}
}
