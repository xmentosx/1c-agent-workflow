//go:build !windows

package main

import "os/exec"

func hideExecutionGuardHost(command *exec.Cmd) {}
