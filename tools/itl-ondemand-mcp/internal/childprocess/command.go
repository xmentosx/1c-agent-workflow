// Package childprocess starts noninteractive subprocesses without console windows.
package childprocess

import (
	"context"
	"os/exec"
)

func Command(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	hideConsole(cmd)
	return cmd
}

func CommandContext(ctx context.Context, name string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name, args...)
	hideConsole(cmd)
	return cmd
}
