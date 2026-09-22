package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeBrokerFixture(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "broker fixture.ps1")
	content := append([]byte{0xef, 0xbb, 0xbf}, []byte("param([string]$ProjectRoot,[string]$InternalOnDemandOperation,[string]$InternalOnDemandFamily,[string]$InternalOnDemandInstanceId,[string]$InternalOnDemandCatalogSha256,[int]$InternalOnDemandExpectedPid,[int]$InternalOnDemandExpectedPort)\n"+body)...)
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
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
