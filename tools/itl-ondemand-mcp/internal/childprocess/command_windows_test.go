package childprocess

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func TestChildDoesNotInheritConsoleWindow(t *testing.T) {
	const role = "ITL_TEST_CHILD_CONSOLE_ROLE"
	const input = "C:\\Папка с пробелом\\проверка.ps1"
	testArgs := []string{"-test.run=^TestChildDoesNotInheritConsoleWindow$", "--", input}
	consoleWindow := windows.NewLazySystemDLL("kernel32.dll").NewProc("GetConsoleWindow")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	switch os.Getenv(role) {
	case "child":
		window, _, _ := consoleWindow.Call()
		fmt.Printf("%d:%s", window, os.Args[len(os.Args)-1])
		os.Exit(0)
	case "host":
		window, _, _ := consoleWindow.Call()
		if window == 0 {
			t.Fatal("test host has no console window to inherit")
		}
		cmd := CommandContext(ctx, os.Args[0], testArgs...)
		cmd.Env = append(os.Environ(), role+"=child")
		output, err := cmd.CombinedOutput()
		if err != nil || string(output) != "0:"+input {
			t.Fatalf("expected no console window and exact Unicode output, got %q (%v)", output, err)
		}
	default:
		// Run the assertion from its own hidden console even when the gate
		// worker itself has no console window.
		cmd := exec.CommandContext(ctx, os.Args[0], testArgs...)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NEW_CONSOLE}
		cmd.Env = append(os.Environ(), role+"=host")
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("hidden console fixture failed: %v\n%s", err, output)
		}
	}
}
