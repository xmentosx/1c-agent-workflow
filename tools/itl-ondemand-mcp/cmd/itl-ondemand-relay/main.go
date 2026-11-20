// Command itl-ondemand-relay is the stable MCP client command for the ITL
// on-demand facades. It serves the facade that the project's launch
// descriptor names, replaces it between requests when the workflow selects
// another one, and restarts it within a bound after an unexpected exit. Facade
// selection stays with the workflow, which writes the descriptor.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const version = "1.0.0"

func main() {
	flags := flag.NewFlagSet("itl-ondemand-relay", flag.ContinueOnError)
	projectRoot := flags.String("project-root", "", "installed project root")
	server := flags.String("server", "", "on-demand MCP server name")
	showVersion := flags.Bool("version", false, "print the relay version")
	if err := flags.Parse(os.Args[1:]); err != nil {
		os.Exit(2)
	}
	if *showVersion {
		fmt.Println(version)
		return
	}
	if *projectRoot == "" || *server == "" {
		fmt.Fprintln(os.Stderr, "ITL_ONDEMAND_RELAY_ARGUMENTS: --project-root and --server are required")
		os.Exit(2)
	}
	root, err := filepath.Abs(*projectRoot)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ITL_ONDEMAND_RELAY_ARGUMENTS:", err)
		os.Exit(2)
	}
	r := newRelay(relayConfig{
		descriptorPath: launchDescriptorPath(root, *server),
		evidenceRoot:   filepath.Join(root, ".agent-1c", "mcp", "ondemand"),
		server:         *server,
		startTimeout:   20 * time.Second,
		stopMargin:     30 * time.Second,
		restartLimit:   3,
		restartWindow:  5 * time.Minute,
	})
	if err := r.run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// launchDescriptorPath is the one place both the workflow and the relay agree
// on: .agent-1c/mcp/ondemand/launch/<server>.json under the project root.
func launchDescriptorPath(projectRoot, server string) string {
	return filepath.Join(projectRoot, ".agent-1c", "mcp", "ondemand", "launch", server+".json")
}
