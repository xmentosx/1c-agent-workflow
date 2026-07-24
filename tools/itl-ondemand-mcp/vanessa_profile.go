package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const vanessaProfileResultMarker = "ITL_VANESSA_PROFILE_RESULT="

type vanessaProfileResult struct {
	SchemaVersion      int    `json:"schemaVersion"`
	Status             string `json:"status"`
	InstanceID         string `json:"instanceId"`
	ManagerPID         int    `json:"managerPid"`
	ManagerPort        int    `json:"managerPort"`
	TestClientPID      int    `json:"testClientPid"`
	TestClientPort     int    `json:"testClientPort"`
	TestClientState    string `json:"testClientState"`
	TestClientReused   bool   `json:"testClientReused"`
	FeaturePath        string `json:"featurePath"`
	ScenarioWasStarted bool   `json:"scenarioWasStarted"`
}

func runVanessaProfileStart(args []string) error {
	flags := flag.NewFlagSet("vanessa-profile-start", flag.ContinueOnError)
	projectRoot := flags.String("project-root", "", "absolute ITL development worktree")
	catalogPath := flags.String("catalog", "", "verified Vanessa compatibility catalog")
	helperPath := flags.String("helper", "", "agent-1c.ps1 path")
	instanceID := flags.String("instance-id", "", "stable branch-local runtime instance id")
	featurePath := flags.String("feature", "", "absolute .feature path to open without running")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *projectRoot == "" || *catalogPath == "" || *helperPath == "" || *instanceID == "" || *featurePath == "" {
		return fmt.Errorf("--project-root, --catalog, --helper, --instance-id, and --feature are required")
	}
	if !regexp.MustCompile(`^[a-f0-9]{32}$`).MatchString(*instanceID) {
		return fmt.Errorf("--instance-id must contain exactly 32 lowercase hexadecimal characters")
	}
	root, err := filepath.Abs(*projectRoot)
	if err != nil || !filepath.IsAbs(root) {
		return fmt.Errorf("--project-root must be absolute")
	}
	feature, err := filepath.Abs(*featurePath)
	if err != nil || !filepath.IsAbs(feature) || filepath.Ext(feature) != ".feature" {
		return fmt.Errorf("--feature must be an absolute .feature file")
	}
	if info, statErr := os.Stat(feature); statErr != nil || info.IsDir() {
		return fmt.Errorf("--feature was not found: %s", feature)
	}
	catalog, err := loadCatalog(*catalogPath, "vanessa-ui")
	if err != nil {
		return err
	}
	rt := &runtime{
		catalog: catalog,
		broker: &powershellBroker{
			HelperPath: *helperPath, ProjectRoot: root, Family: "vanessa-ui",
			InstanceID: *instanceID, CatalogHash: catalog.SHA256,
		},
		projectRoot: root, family: "vanessa-ui", instanceID: *instanceID,
		idle: time.Hour, catalogWait: 30 * time.Second,
		logger:             slog.New(slog.NewJSONHandler(os.Stderr, nil)),
		progress:           make(map[string]*mcp.ServerSession),
		vanessaConnectWait: time.Minute,
		suppressEvidence:   true,
	}
	result, err := startInteractiveVanessaProfile(context.Background(), rt, feature)
	if err != nil {
		return err
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("encode Vanessa profile result: %w", err)
	}
	fmt.Printf("%s%s\n", vanessaProfileResultMarker, encoded)
	return nil
}

func startInteractiveVanessaProfile(ctx context.Context, rt *runtime, featurePath string) (*vanessaProfileResult, error) {
	request := &mcp.CallToolRequest{Params: &mcp.CallToolParamsRaw{}}
	connectResult, err := rt.callNamed(ctx, request, "connect_test_client", map[string]any{
		"profileName": "itl-ondemand",
	})
	if err != nil {
		return nil, fmt.Errorf("connect managed TestClient: %w", err)
	}
	if connectResult == nil || connectResult.IsError {
		return nil, fmt.Errorf("connect managed TestClient: code=%s detail=%s", toolResultCode(connectResult), resultText(connectResult))
	}
	openResult, err := rt.callNamed(ctx, request, "open_feature_file", map[string]any{
		"filePath": featurePath,
	})
	if err != nil {
		return nil, fmt.Errorf("open Vanessa feature: %w", err)
	}
	if openResult == nil || openResult.IsError {
		return nil, fmt.Errorf("open Vanessa feature: code=%s detail=%s", toolResultCode(openResult), resultText(openResult))
	}

	rt.mu.Lock()
	defer rt.mu.Unlock()
	if rt.backend == nil || rt.backend.PID <= 0 || rt.backend.TestClientPID <= 0 ||
		rt.testClientState != testClientManagerConnected {
		return nil, fmt.Errorf("ITL_VANESSA_TESTCLIENT_CONNECTION_STATE_UNAVAILABLE: interactive manager connection was not positively proven")
	}
	return &vanessaProfileResult{
		SchemaVersion: 1, Status: "running", InstanceID: rt.instanceID,
		ManagerPID: rt.backend.PID, ManagerPort: rt.backend.Port,
		TestClientPID: rt.backend.TestClientPID, TestClientPort: rt.backend.TestClientPort,
		TestClientState: rt.testClientState, TestClientReused: rt.backend.TestClientReused,
		FeaturePath: featurePath, ScenarioWasStarted: false,
	}, nil
}
