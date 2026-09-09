package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestDatabaseBrokerPlansThroughPublicHelper(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Проект с пробелом")
	stateRoot := filepath.Join(root, ".agent-1c", "dev-branches")
	if err := os.MkdirAll(stateRoot, 0700); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"-C", root, "init", "--initial-branch=itldev/test"},
		{"-C", root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture"},
	} {
		if output, err := exec.Command("git", args...).CombinedOutput(); err != nil {
			t.Fatalf("fixture Git: %v: %s", err, output)
		}
	}
	target := filepath.Join(root, "целевая база")
	state, _ := json.Marshal(map[string]any{"devBranchName": "test", "infoBaseKind": "file", "devBranchInfoBasePath": target})
	if err := os.WriteFile(filepath.Join(stateRoot, "test.json"), state, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".agent-1c", "project.json"), []byte(`{"aiRules":{"tools":["codex"]}}`), 0600); err != nil {
		t.Fatal(err)
	}
	helper, err := filepath.Abs("../../.agents/skills/1c-workflow/scripts/agent-1c.ps1")
	if err != nil {
		t.Fatal(err)
	}
	broker := &powershellBroker{HelperPath: helper, ProjectRoot: root, Family: "roctup", InstanceID: strings.Repeat("a", 32)}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	plan, err := broker.DatabaseAccessPlan(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if plan.TargetBase.Path != target || len(plan.Bases) != 1 || plan.Bases[0].Path != target || plan.Family != "roctup" {
		t.Fatal("public helper did not preserve the exact Unicode target")
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatal("planning created the database")
	}
}

func TestDatabaseBrokerPrivateContextsAreIsolatedAcrossNativeCalls(t *testing.T) {
	t.Setenv("ITL_INFOBASE_ACCESS_LEASE", "outer-environment-must-stay-unchanged")
	t.Setenv("ITL_DATABASE_ACCESS_CONTEXT", "outer-context-must-stay-unchanged")
	root := filepath.Join(t.TempDir(), "Приватные вызовы")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	helper := filepath.Join(root, "fixture broker.ps1")
	body := `param($ProjectRoot,$InternalOnDemandOperation,$InternalOnDemandFamily,$InternalOnDemandInstanceId,$InternalOnDemandCatalogSha256)
$context = $env:ITL_DATABASE_ACCESS_CONTEXT | ConvertFrom-Json
$proof = $env:ITL_INFOBASE_ACCESS_LEASE | ConvertFrom-Json
$trace = @{token=$proof.token;contextToken=$context.proof.token;commandLine=[Environment]::CommandLine}
[IO.File]::WriteAllText((Join-Path $ProjectRoot ($InternalOnDemandInstanceId + '.private.json')), ($trace | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
Write-Output ('ITL_ONDEMAND_RESULT=' + (@{schemaVersion=1;status='stopped';family=$InternalOnDemandFamily;instanceId=$InternalOnDemandInstanceId} | ConvertTo-Json -Compress))
`
	if err := os.WriteFile(helper, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	var wait sync.WaitGroup
	results := make(chan error, 2)
	for _, id := range []string{"a", "b"} {
		wait.Add(1)
		go func(id string) {
			defer wait.Done()
			proof := &databaseAccessProof{Coordinator: root, Ticket: strings.Repeat(id, 32), Token: "private-token-" + id}
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			ctx = withDatabaseInvocation(ctx, proof, &facadeDatabasePlan{SchemaVersion: 1})
			broker := &powershellBroker{HelperPath: helper, ProjectRoot: root, Family: "roctup", InstanceID: id}
			results <- broker.Stop(ctx)
		}(id)
	}
	wait.Wait()
	close(results)
	for err := range results {
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range []string{"a", "b"} {
		data, err := os.ReadFile(filepath.Join(root, id+".private.json"))
		if err != nil {
			t.Fatal(err)
		}
		var trace map[string]string
		if err := json.Unmarshal(data, &trace); err != nil {
			t.Fatal(err)
		}
		if trace["token"] != "private-token-"+id || trace["contextToken"] != trace["token"] || strings.Contains(trace["commandLine"], "private-token-") {
			t.Fatal("private native invocation crossed contexts or exposed its token on the command line")
		}
	}
	if os.Getenv("ITL_INFOBASE_ACCESS_LEASE") != "outer-environment-must-stay-unchanged" || os.Getenv("ITL_DATABASE_ACCESS_CONTEXT") != "outer-context-must-stay-unchanged" {
		t.Fatal("broker changed process-global ownership")
	}
}

func TestDatabaseBrokerCleanupPreservesOnlyExplicitOwnershipContext(t *testing.T) {
	proof := &databaseAccessProof{Coordinator: "authority", Ticket: "ticket", Token: "private-cleanup-token"}
	parent, cancel := context.WithCancel(withDatabaseInvocation(context.Background(), proof, &facadeDatabasePlan{SchemaVersion: 1}))
	cancel()
	cleanup, stop := context.WithTimeout(context.Background(), time.Second)
	defer stop()
	cleanup = preserveDatabaseInvocation(parent, cleanup)
	if cleanup.Err() != nil {
		t.Fatal("cleanup inherited an already-cancelled operation")
	}
	values, err := databaseBrokerEnvironment(cleanup)
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, value := range values {
		if strings.HasPrefix(value, "ITL_INFOBASE_ACCESS_LEASE=") {
			count++
			if !strings.Contains(value, proof.Token) {
				t.Fatal("cleanup lost its database ownership")
			}
		}
	}
	if count != 1 {
		t.Fatal("cleanup has missing or ambiguous lease environment")
	}
}

func TestDatabaseBrokerEnsureCrossesRealInheritedAdmissionBoundary(t *testing.T) {
	python, runtimeRoot, request := databaseAccessFixture(t)
	parent := acquireDatabaseFixture(t, python, runtimeRoot, request)
	root := filepath.Dir(request.Coordinator)
	lib, err := filepath.Abs("../../.agents/skills/1c-workflow/scripts/lib")
	if err != nil {
		t.Fatal(err)
	}
	// Only the 1C launch is replaced. Go invokes a native PowerShell broker,
	// whose real middleware starts another Python host and checks the parent's
	// live reservation before the simulated native boundary is reached.
	body := `param($ProjectRoot,$InternalOnDemandOperation,$InternalOnDemandFamily,$InternalOnDemandInstanceId,$InternalOnDemandCatalogSha256)
$ErrorActionPreference='Stop'
$script:ProjectRoot=$ProjectRoot
$lib='@SOURCE_LIB@'
foreach ($name in @('core','runtime-values','lifecycle','roctup-mcp','ondemand-mcp')) { . (Join-Path $lib ('agent-1c.'+$name+'.ps1')) }
function Read-CurrentDevBranchStateForRoctupMcp { [pscustomobject]@{infoBaseKind='file';devBranchInfoBasePath=(Join-Path $ProjectRoot 'целевая база')} }
function Read-ItlOnDemandRuntimeState { $null }
function Get-Setting { param($EnvName,$ConfigName,$Default) $Default }
function Start-ItlOnDemandBackendInstance {
    param($Family,$InstanceId,$CatalogSha256,$AuxiliaryContour,$ServiceAdmissionPlan)
    [IO.File]::WriteAllText((Join-Path $ProjectRoot 'native-boundary.txt'), 'admitted')
    [pscustomobject]@{schemaVersion=1;status='readiness';family=$Family;instanceId=$InstanceId;pid=4242;port=48111;url='http://127.0.0.1:48111/mcp'}
}
function Stop-ItlOnDemandBackendInstance { [pscustomobject]@{status='stopped'} }
Invoke-ItlOnDemandBackendBroker -Operation $InternalOnDemandOperation -Family $InternalOnDemandFamily -InstanceId $InternalOnDemandInstanceId -CatalogSha256 $InternalOnDemandCatalogSha256
`
	body = strings.ReplaceAll(body, "@SOURCE_LIB@", strings.ReplaceAll(lib, "'", "''"))
	helper := filepath.Join(root, "broker с проверкой владения.ps1")
	if err := os.WriteFile(helper, append([]byte{0xef, 0xbb, 0xbf}, []byte(body)...), 0600); err != nil {
		t.Fatal(err)
	}
	plan := &facadeDatabasePlan{SchemaVersion: 1, Family: "roctup", ProjectRoot: root,
		InstanceID: strings.Repeat("a", 32), Coordinator: request.Coordinator, Python: python,
		Bases: request.Bases, PrimaryBase: &request.Bases[0], TargetBase: request.Bases[0]}
	broker := &powershellBroker{HelperPath: helper, ProjectRoot: root, Family: "roctup", InstanceID: plan.InstanceID}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	ctx = withDatabaseInvocation(ctx, parent.Proof, plan)
	if _, err := broker.Ensure(ctx); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(root, "native-boundary.txt")
	if data, err := os.ReadFile(marker); err != nil || string(data) != "admitted" {
		t.Fatal("the admitted broker did not reach its native boundary", err)
	}
	if err := parent.Validate(ctx); err != nil {
		t.Fatal("the broker released its parent's reservation", err)
	}
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	releaseDatabaseFixture(t, parent, nil)
	if _, err := broker.Ensure(ctx); err == nil || !strings.Contains(err.Error(), "INFOBASE_ACCESS_") {
		t.Fatal("broker admitted an ended outer reservation", err)
	} else if strings.Contains(err.Error(), parent.Proof.Token) {
		t.Fatal("broker disclosed the private token")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("stale ownership reached the native boundary")
	}
}
