package main

import (
	"os/exec"
	"syscall"
)

func hideExecutionGuardHost(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
}
