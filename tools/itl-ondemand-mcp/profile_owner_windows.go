//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows"
)

type profileOwnerLock struct{ handle windows.Handle }

func profileControlSharingViolation(err error) bool {
	// Windows can report ACCESS_DENIED while a replaced file is delete-pending.
	// A permanent denial still fails after the bounded control-file retry.
	return errors.Is(err, windows.ERROR_SHARING_VIOLATION) || errors.Is(err, windows.ERROR_LOCK_VIOLATION) || errors.Is(err, windows.ERROR_ACCESS_DENIED)
}

func (lock *profileOwnerLock) Close() error { return windows.CloseHandle(lock.handle) }

func acquireProfileOwnerLock(path string) (*profileOwnerLock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	ptr, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(ptr, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, fmt.Errorf("ITL_PROFILE_OWNER_LOCK_BUSY: %w", err)
	}
	return &profileOwnerLock{handle: handle}, nil
}

func readProfileProcessIdentity(pid int) (profileProcessIdentity, error) {
	value := profileProcessIdentity{PID: pid}
	var handle windows.Handle
	var err error
	deadline := time.Now().Add(2 * time.Second)
	for {
		handle, err = windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE, false, uint32(pid))
		if !errors.Is(err, windows.ERROR_ACCESS_DENIED) || !time.Now().Before(deadline) {
			break
		}
		// A process can become temporarily uninspectable during exit. Never
		// turn a denial itself into proof that the recorded owner is gone.
		time.Sleep(10 * time.Millisecond)
	}
	if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
		return value, os.ErrNotExist
	}
	if err != nil {
		return value, err
	}
	defer windows.CloseHandle(handle)
	status, err := windows.WaitForSingleObject(handle, 0)
	if err != nil {
		return value, err
	}
	if status == windows.WAIT_OBJECT_0 {
		return value, os.ErrNotExist
	}
	var created, exited, kernel, user windows.Filetime
	if err := windows.GetProcessTimes(handle, &created, &exited, &kernel, &user); err != nil {
		return value, err
	}
	value.Started = fmt.Sprintf("%08x%08x", created.HighDateTime, created.LowDateTime)
	buffer := make([]uint16, 32768)
	size := uint32(len(buffer))
	if err := windows.QueryFullProcessImageName(handle, 0, &buffer[0], &size); err != nil {
		return value, err
	}
	value.Executable = windows.UTF16ToString(buffer[:size])
	return value, nil
}
