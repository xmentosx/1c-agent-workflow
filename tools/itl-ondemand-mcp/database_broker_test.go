package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeBrokerFixture(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "broker fixture.ps1")
	content := append([]byte{0xef, 0xbb, 0xbf}, []byte("param([string]$ProjectRoot,[string]$InternalOnDemandOperation,[string]$InternalOnDemandFamily,[string]$InternalOnDemandInstanceId,[string]$InternalOnDemandCatalogSha256,[int]$InternalOnDemandExpectedPid,[int]$InternalOnDemandExpectedPort,[string]$InternalOnDemandReplacementInstanceId)\n"+body)...)
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestPowerShellBrokerRecoveryPassesRetainedUnicodeLaunchProofInsideTheExistingInvocation(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Проект с пробелом")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	oldID, newID := strings.Repeat("a", 32), strings.Repeat("b", 32)
	script := writeBrokerFixture(t, `$value=$env:ITL_EXECUTION_INVOCATION | ConvertFrom-Json
if ($InternalOnDemandOperation -ne 'recover' -or $value.context.executionContext -ne 'signed-parent' -or $env:ITL_EXECUTION_CONTEXT_KEY -ne 'parent-key') { throw 'lost existing execution context' }
$old=$value.expectedBackend
if ($old.instanceId -ne $InternalOnDemandInstanceId -or $old.pid -ne $InternalOnDemandExpectedPid -or $old.port -ne $InternalOnDemandExpectedPort -or $old.nativeLaunchProof.executablePath -cne 'C:\Платформа с пробелом\1cv8.exe') { throw 'retained launch proof changed' }
$result=@{family=$InternalOnDemandFamily;instanceId=$InternalOnDemandReplacementInstanceId;status='readiness';pid=103;port=41003;url='http://127.0.0.1:41003/mcp'} | ConvertTo-Json -Compress
Write-Output ('ITL_ONDEMAND_RESULT='+$result)
`)
	broker := &powershellBroker{HelperPath: script, ProjectRoot: root, Family: "roctup", InstanceID: oldID}
	previous := &backendInfo{InstanceID: oldID, PID: 101, Port: 41001, NativeLaunchProof: json.RawMessage(`{"executablePath":"C:\\Платформа с пробелом\\1cv8.exe"}`)}
	ctx := withExecutionInvocation(context.Background(), executionContextProof{Encoded: "signed-parent", Key: "parent-key"}, &facadeExecutionPlan{SchemaVersion: 2})
	info, err := broker.Recover(ctx, previous, newID)
	if err != nil || info.InstanceID != newID || broker.InstanceID != newID {
		t.Fatalf("recovery handoff failed: %+v %v", info, err)
	}
	if invocation := ctx.Value(executionInvocationKey{}).(*executionInvocation); invocation.ExpectedBackend != nil {
		t.Fatal("recovery mutated its parent's invocation")
	}
}

func TestPowerShellBrokerReadsExecutionPlanV2(t *testing.T) {
	root := t.TempDir()
	id := "0123456789abcdef0123456789abcdef"
	script := writeBrokerFixture(t, `$base=@{kind='file';path=(Join-Path $ProjectRoot 'База')}
$plan=@{schemaVersion=2;family=$InternalOnDemandFamily;projectRoot=$ProjectRoot;instanceId=$InternalOnDemandInstanceId;guardRoot=(Join-Path $ProjectRoot 'execution-guards-v2');executionHost='localhost';waitTimeoutSeconds=30;python='python';bases=@($base);targetBase=$base;runtimePresent=$false}
$value=@{schemaVersion=1;status='planned';family=$InternalOnDemandFamily;instanceId=$InternalOnDemandInstanceId;executionGuard=$plan}|ConvertTo-Json -Compress -Depth 10
Write-Output ('ITL_ONDEMAND_RESULT='+$value)
`)
	broker := &powershellBroker{HelperPath: script, ProjectRoot: root, Family: "roctup", InstanceID: id}
	plan, err := broker.ExecutionPlan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if plan.SchemaVersion != 2 || plan.GuardRoot == "" || len(plan.Bases) != 1 || plan.TargetBase.Path == "" {
		t.Fatalf("invalid plan: %#v", plan)
	}
}

func TestExecutionBrokerEnvironmentPassesSignedContextWithoutMutatingParent(t *testing.T) {
	t.Setenv("ITL_EXECUTION_CONTEXT", "outer-environment")
	t.Setenv("ITL_EXECUTION_CONTEXT_KEY", "outer-key")
	proof := executionContextProof{Encoded: "signed-context", Key: "private-key", ID: "execution", Resources: []string{"base-one"}}
	plan := &facadeExecutionPlan{SchemaVersion: 2}
	ctx := withExecutionInvocation(context.Background(), proof, plan)
	values, err := executionBrokerEnvironment(ctx)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(values, "\n")
	for _, expected := range []string{"ITL_EXECUTION_CONTEXT=signed-context", "ITL_EXECUTION_CONTEXT_KEY=private-key", "ITL_EXECUTION_INVOCATION="} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("missing %q in environment", expected)
		}
	}
	if os.Getenv("ITL_EXECUTION_CONTEXT") != "outer-environment" || os.Getenv("ITL_EXECUTION_CONTEXT_KEY") != "outer-key" {
		t.Fatal("broker mutated the parent environment")
	}
}

func TestPreservedExecutionInvocationSurvivesCancelledParent(t *testing.T) {
	proof := executionContextProof{Encoded: "signed", Key: "key", ID: "execution", Resources: []string{"base-one"}}
	parent, cancel := context.WithCancel(withExecutionInvocation(context.Background(), proof, &facadeExecutionPlan{SchemaVersion: 2}))
	cancel()
	cleanup := preserveExecutionInvocation(parent, context.Background())
	values, err := executionBrokerEnvironment(cleanup)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(values, "\n"), "ITL_EXECUTION_CONTEXT=signed") {
		t.Fatal("cleanup lost the verified execution context")
	}
}
