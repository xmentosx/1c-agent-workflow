//go:build !windows

package main

import "fmt"

type profileOwnerLock struct{}

func profileControlSharingViolation(error) bool { return false }

func (*profileOwnerLock) Close() error { return nil }
func acquireProfileOwnerLock(string) (*profileOwnerLock, error) {
	return nil, fmt.Errorf("ITL_PROFILE_OWNER_WINDOWS_REQUIRED")
}
func readProfileProcessIdentity(int) (profileProcessIdentity, error) {
	return profileProcessIdentity{}, fmt.Errorf("ITL_PROFILE_OWNER_WINDOWS_REQUIRED")
}
