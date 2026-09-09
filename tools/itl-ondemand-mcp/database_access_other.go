//go:build !windows

package main

import "os/exec"

func hideDatabaseHost(command *exec.Cmd) {}
