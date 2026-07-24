package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	goruntime "runtime"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const version = "0.4.0"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if goruntime.GOOS != "windows" || goruntime.GOARCH != "amd64" {
		return fmt.Errorf("itl-ondemand-mcp v1 supports Windows x64 only")
	}
	if len(args) == 0 {
		return fmt.Errorf("usage: itl-ondemand-mcp serve|vanessa-profile-start")
	}
	if args[0] == "vanessa-profile-start" {
		return runVanessaProfileStart(args[1:])
	}
	if args[0] != "serve" {
		return fmt.Errorf("usage: itl-ondemand-mcp serve --family roctup|vanessa-ui --project-root PATH --catalog PATH --helper PATH")
	}
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	family := flags.String("family", "", "backend family")
	projectRoot := flags.String("project-root", "", "absolute ITL worktree root")
	catalogPath := flags.String("catalog", "", "compatibility catalog")
	helperPath := flags.String("helper", "", "agent-1c.ps1 path")
	idle := flags.Duration("idle-timeout", 10*time.Minute, "backend idle timeout")
	surface := flags.String("surface", "gateway", "public tool surface: gateway or full")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if *family != "roctup" && *family != "vanessa-ui" {
		return fmt.Errorf("invalid --family %q", *family)
	}
	if *surface != "gateway" && *surface != "full" {
		return fmt.Errorf("invalid --surface %q", *surface)
	}
	root, err := filepath.Abs(*projectRoot)
	if err != nil || !filepath.IsAbs(root) {
		return fmt.Errorf("--project-root must be absolute")
	}
	if _, err := os.Stat(filepath.Join(root, ".git")); err != nil {
		return fmt.Errorf("project root is not a Git worktree: %s", root)
	}
	catalog, err := loadCatalog(*catalogPath, *family)
	if err != nil {
		return err
	}
	instanceID, err := randomID()
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	broker := &powershellBroker{
		HelperPath: *helperPath, ProjectRoot: root, Family: *family,
		InstanceID: instanceID, CatalogHash: catalog.SHA256,
	}
	rt := &runtime{
		catalog: catalog, broker: broker, projectRoot: root, family: *family,
		instanceID: instanceID, idle: *idle, catalogWait: 30 * time.Second, logger: logger,
		vanessaConnectWait: 60 * time.Second,
		progress:           make(map[string]*mcp.ServerSession),
	}
	serverName := "itl-roctup-data"
	if *family == "vanessa-ui" {
		serverName = "itl-vanessa-ui"
	}
	server := mcp.NewServer(&mcp.Implementation{Name: serverName, Version: version}, &mcp.ServerOptions{
		Capabilities: &mcp.ServerCapabilities{Tools: &mcp.ToolCapabilities{ListChanged: false}},
		Logger:       logger,
	})
	if *surface == "gateway" {
		addGatewayTools(server, rt)
	} else {
		for _, definition := range catalog.Data.Tools {
			tool := definition
			server.AddTool(tool, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
				return rt.call(ctx, req)
			})
		}
	}
	err = server.Run(context.Background(), &mcp.StdioTransport{})
	cleanupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cleanupErr := rt.close(cleanupCtx)
	if err != nil {
		return err
	}
	return cleanupErr
}

func randomID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(value[:]), nil
}
