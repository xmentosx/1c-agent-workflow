//go:build !windows

package childprocess

import "os/exec"

func hideConsole(command *exec.Cmd) {}
