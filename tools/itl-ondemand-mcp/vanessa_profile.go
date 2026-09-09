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
	SchemaVersion       int                     `json:"schemaVersion"`
	Status              string                  `json:"status"`
	InstanceID          string                  `json:"instanceId"`
	ManagerPID          int                     `json:"managerPid"`
	ManagerPort         int                     `json:"managerPort"`
	TestClientPID       int                     `json:"testClientPid"`
	TestClientPort      int                     `json:"testClientPort"`
	TestClientState     string                  `json:"testClientState"`
	TestClientReused    bool                    `json:"testClientReused"`
	FeaturePath         string                  `json:"featurePath"`
	ScenarioWasStarted  bool                    `json:"scenarioWasStarted"`
	DatabaseOwnerTicket string                  `json:"databaseOwnerTicket,omitempty"`
	OwnerGeneration     string                  `json:"ownerGeneration,omitempty"`
	OwnerID             string                  `json:"ownerId,omitempty"`
	OwnerProcess        *profileProcessIdentity `json:"ownerProcess,omitempty"`
}

func runVanessaProfileStart(args []string) error {
	flags := flag.NewFlagSet("vanessa-profile-start", flag.ContinueOnError)
	projectRoot := flags.String("project-root", "", "absolute ITL development worktree")
	catalogPath := flags.String("catalog", "", "verified Vanessa compatibility catalog")
	helperPath := flags.String("helper", "", "agent-1c.ps1 path")
	instanceID := flags.String("instance-id", "", "stable branch-local runtime instance id")
	featurePath := flags.String("feature", "", "absolute .feature path to open without running")
	callerID := flags.String("caller-id", "", "interactive session owner; defaults to the current Codex thread")
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
	config := profileOwnerConfig{ProjectRoot: root, InstanceID: *instanceID}
	config.CatalogPath, err = filepath.Abs(*catalogPath)
	if err != nil {
		return err
	}
	config.HelperPath, err = filepath.Abs(*helperPath)
	if err != nil {
		return err
	}
	if os.Getenv("ITL_INFOBASE_ACCESS_LEASE") == "" {
		config.CallerID, err = resolveProfileCaller(*callerID, true)
		if err != nil {
			return err
		}
		config.Generation, err = randomID()
		if err != nil {
			return err
		}
		executable, err := os.Executable()
		if err != nil {
			return err
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Hour)
		defer cancel()
		owner, err := ensureProfileOwner(ctx, config, func(config profileOwnerConfig) (profileProcessIdentity, error) {
			return launchProfileOwner(executable, profileOwnerArguments(config), root)
		})
		if err != nil {
			return err
		}
		response, err := requestProfileOwner(ctx, owner, "open", feature, config.CallerID)
		if err != nil {
			return err
		}
		if response.Status != "running" || response.Result == nil {
			return fmt.Errorf("ITL_VANESSA_PROFILE_START_FAILED: %s", response.Error)
		}
		response.Result.OwnerGeneration = owner.Generation
		response.Result.OwnerID = owner.CallerID
		response.Result.OwnerProcess = &owner.Process
		encoded, err := json.Marshal(response.Result)
		if err != nil {
			return err
		}
		fmt.Printf("%s%s\n", vanessaProfileResultMarker, encoded)
		return nil
	}
	rt, err := newProfileOwnerRuntime(config, true)
	if err != nil {
		return err
	}
	result, err := startInteractiveVanessaProfile(context.Background(), rt, feature)
	if err != nil {
		cleanup, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		if cleanupErr := rt.close(cleanup); cleanupErr != nil {
			return fmt.Errorf("%v; profile cleanup: %w", err, cleanupErr)
		}
		return err
	}
	unlock, err := rt.lockDatabaseCalls(context.Background())
	if err != nil {
		return err
	}
	defer unlock()
	if rt.databaseOwner != nil {
		// Closing this inherited pipe host does not release the caller's lease.
		// Its normal profile cleanup still owns both recorded native sessions.
		if err := rt.databaseOwner.Close(); err != nil {
			return err
		}
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("encode Vanessa profile result: %w", err)
	}
	fmt.Printf("%s%s\n", vanessaProfileResultMarker, encoded)
	return nil
}

func newProfileOwnerRuntime(config profileOwnerConfig, retainInherited bool) (*runtime, error) {
	catalog, err := loadCatalog(config.CatalogPath, "vanessa-ui")
	if err != nil {
		return nil, err
	}
	return &runtime{
		catalog: catalog, broker: &powershellBroker{HelperPath: config.HelperPath, ProjectRoot: config.ProjectRoot, Family: "vanessa-ui", InstanceID: config.InstanceID, CatalogHash: catalog.SHA256},
		projectRoot: config.ProjectRoot, family: "vanessa-ui", instanceID: config.InstanceID,
		// A manual profile has no idle expiry. Its owner observes actual process
		// exit or an explicit stop; outer-owned profiles inherit caller cleanup.
		idle: 0, catalogWait: 30 * time.Second, vanessaConnectWait: time.Minute,
		logger: slog.New(slog.NewJSONHandler(os.Stderr, nil)), progress: make(map[string]*progressRoute), suppressEvidence: true, databaseRetainInherited: retainInherited,
	}, nil
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
	ticket := ""
	if rt.databaseOwner != nil {
		ticket = rt.databaseOwner.Proof.Ticket
	}
	return &vanessaProfileResult{
		SchemaVersion: 1, Status: "running", InstanceID: rt.instanceID,
		DatabaseOwnerTicket: ticket,
		ManagerPID:          rt.backend.PID, ManagerPort: rt.backend.Port,
		TestClientPID: rt.backend.TestClientPID, TestClientPort: rt.backend.TestClientPort,
		TestClientState: rt.testClientState, TestClientReused: rt.backend.TestClientReused,
		FeaturePath: featurePath, ScenarioWasStarted: false,
	}, nil
}
