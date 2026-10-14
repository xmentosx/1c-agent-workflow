package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type privateIdleFixture struct {
	*executionFixtureBroker
	idleStops int
}

func TestPrivateIdleEnvironmentCannotInheritOrExpandDatabaseAuthority(t *testing.T) {
	t.Setenv("ITL_EXECUTION_CONTEXT", "foreign")
	t.Setenv("ITL_EXECUTION_CONTEXT_KEY", "foreign-key")
	value := &ownedIdleInvocation{SchemaVersion: 3, Kind: "owned-idle-stop", ProjectRoot: t.TempDir(), InstanceID: strings.Repeat("a", 32)}
	ctx := context.WithValue(context.Background(), ownedIdleInvocationKey{}, value)
	env, err := executionBrokerEnvironment(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range env {
		if strings.HasPrefix(line, "ITL_EXECUTION_CONTEXT=") || strings.HasPrefix(line, "ITL_EXECUTION_CONTEXT_KEY=") {
			t.Fatal("private stop inherited a foreign guard")
		}
	}
	signed := withExecutionInvocation(ctx, executionContextProof{Encoded: "signed", Key: "key"}, &facadeExecutionPlan{SchemaVersion: 2})
	if _, err := executionBrokerEnvironment(signed); err == nil {
		t.Fatal("mixed cleanup authority accepted")
	}
}

func TestPrivateStopAndChildCloseKeepDistinctBrokerAuthority(t *testing.T) {
	for _, mode := range []string{"idle", "close"} {
		t.Run(mode, func(t *testing.T) {
			body := `$v=$env:ITL_EXECUTION_INVOCATION | ConvertFrom-Json
if($InternalOnDemandOperation -eq 'stop') {
 if($v.schemaVersion -ne 3 -or $v.kind -cne 'owned-idle-stop' -or $env:ITL_EXECUTION_CONTEXT -or $env:ITL_EXECUTION_CONTEXT_KEY){throw 'expanded idle authority'}
 $status='stopped'
} elseif($InternalOnDemandOperation -eq 'complete-test-client-close') {
 if($v.schemaVersion -ne 2 -or $env:ITL_EXECUTION_CONTEXT -cne 'original' -or $v.expectedBackend.pid -ne 101){throw 'lost original close owner'}
 $status='test-client-closed'
} else {throw 'unexpected operation'}
Write-Output ('ITL_ONDEMAND_RESULT='+(@{status=$status}|ConvertTo-Json -Compress))
`
			broker := &powershellBroker{privateRuntime: true, HelperPath: writeBrokerFixture(t, body), ProjectRoot: t.TempDir(), Family: "vanessa-ui", InstanceID: strings.Repeat("a", 32)}
			info := &backendInfo{PID: 101, Port: 9874, InstanceID: broker.InstanceID, NativeLaunchProof: json.RawMessage(`{"schemaVersion":4}`)}
			var err error
			if mode == "idle" {
				err = broker.StopOwnedIdle(context.Background(), info)
			} else {
				ctx := withExecutionInvocation(context.Background(), executionContextProof{Encoded: "original", Key: "key"}, &facadeExecutionPlan{SchemaVersion: 2})
				err = broker.CompleteTestClientClose(ctx, info)
			}
			if err != nil {
				t.Fatal(err)
			}
		})
	}
}

type closeReceiptFixture struct {
	*fakeBroker
	closeCalls int
	closeError error
}

func (b *closeReceiptFixture) CompleteTestClientClose(ctx context.Context, expected *backendInfo) error {
	b.closeCalls++
	if ctx.Value(executionInvocationKey{}) == nil || expected == nil {
		return errors.New("lost close proof")
	}
	return b.closeError
}

func TestCloseToolCannotReturnSuccessBeforeNativePostcondition(t *testing.T) {
	for _, failure := range []bool{false, true} {
		t.Run(map[bool]string{false: "confirmed", true: "unconfirmed"}[failure], func(t *testing.T) {
			calls := 0
			tools := []*mcp.Tool{{Name: "close_test_client", InputSchema: map[string]any{"type": "object"}}}
			_, httpServer := newBackendWithObserver(t, tools, false, func(string) { calls++ })
			client := mcp.NewClient(&mcp.Implementation{Name: "close-test", Version: "1"}, nil)
			session, err := client.Connect(context.Background(), &mcp.StreamableClientTransport{Endpoint: httpServer.URL}, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer session.Close()
			broker := &closeReceiptFixture{fakeBroker: &fakeBroker{}}
			if failure {
				broker.closeError = errors.New("native close unconfirmed")
			}
			rt := &runtime{family: "vanessa-ui", broker: broker, backend: &backendInfo{PID: 101}}
			ctx := withExecutionInvocation(context.Background(), executionContextProof{Encoded: "original", Key: "key"}, &facadeExecutionPlan{})
			result, err := rt.callUpstream(ctx, session, &mcp.CallToolParams{Name: "close_test_client", Arguments: map[string]any{}})
			if calls != 1 || broker.closeCalls != 1 {
				t.Fatal("close replayed or bypassed native owner")
			}
			if failure && (err == nil || result != nil) {
				t.Fatal("unconfirmed close reported success")
			}
			if !failure && (err != nil || result == nil || result.IsError) {
				t.Fatalf("confirmed close failed: %v", err)
			}
		})
	}
}

func (b *privateIdleFixture) PrivateRuntime() bool { return true }
func (b *privateIdleFixture) StopOwnedIdle(_ context.Context, _ *backendInfo) error {
	b.idleStops++
	return nil
}

func TestPrivateIdleEOFStopsWithoutContendersDatabaseGuard(t *testing.T) {
	rt, original := newExecutionRuntimeFixture(t)
	broker := &privateIdleFixture{executionFixtureBroker: original}
	rt.broker = broker
	rt.backend = &backendInfo{PID: 101, InstanceID: rt.instanceID}
	contender, _ := newExecutionRuntimeFixture(t)
	contenderBroker := contender.broker.(*executionFixtureBroker)
	contenderBroker.plan = original.plan
	contenderBroker.runtimeRoot = original.runtimeRoot
	_, finish, err := contender.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer finish("succeeded", "")
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	if err := rt.stop(ctx); err != nil {
		t.Fatalf("private idle stop waited for foreign guard: %v", err)
	}
	if broker.idleStops != 1 || broker.planCalls != 0 || rt.backend != nil || rt.executionOwner != nil {
		t.Fatalf("idle stop acquired database authority or lost cleanup: idle=%d plans=%d", broker.idleStops, broker.planCalls)
	}
	if contender.executionOwner == nil {
		t.Fatal("idle stop released contender's owner")
	}
}

type observedIdleWaitContext struct {
	context.Context
	observed chan struct{}
	once     sync.Once
}

func (c *observedIdleWaitContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.observed) })
	return c.Context.Done()
}

func TestIdleCleanupSupersededWhileWaitingForDatabaseGate(t *testing.T) {
	rt, broker := newExecutionRuntimeFixture(t)
	rt.backend = &backendInfo{Status: "running", PID: os.Getpid(), URL: "http://fixture"}
	_, finish, err := rt.beginDatabaseCall(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := finish("succeeded", ""); err != nil {
			t.Error(err)
		}
	}()
	owner := rt.executionOwner
	planCalls := broker.planCalls
	parent, cancel := context.WithCancel(context.Background())
	defer cancel()
	observed := &observedIdleWaitContext{Context: parent, observed: make(chan struct{})}
	completed := make(chan error, 1)
	go func() { completed <- rt.stopIdle(observed, 0) }()
	select {
	case <-observed.observed:
	case <-time.After(5 * time.Second):
		t.Fatal("idle callback did not reach local database gate")
	}
	// The admitted foreground call now advances the generation while retaining
	// its database gate. The timer that passed its pre-check has become obsolete.
	rt.mu.Lock()
	rt.generation++
	rt.mu.Unlock()
	cancel()
	select {
	case err := <-completed:
		if err != nil {
			t.Fatalf("obsolete idle callback reported local-gate cancellation: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("obsolete callback did not complete")
	}
	if broker.planCalls != planCalls || broker.stops != 0 || rt.executionOwner != owner || rt.backend == nil {
		t.Fatal("obsolete callback changed foreground ownership, admitted work, or stopped native backend")
	}
}
