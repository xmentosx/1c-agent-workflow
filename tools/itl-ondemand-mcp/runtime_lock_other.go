//go:build !windows

package main

import "fmt"

type runtimeReadLock struct{}

func acquireRuntimeReadLock(string) (*runtimeReadLock, error) {
	return nil, fmt.Errorf("itl-ondemand-mcp v1 supports Windows only")
}
func (*runtimeReadLock) Close() error { return nil }
