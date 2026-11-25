package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The test binary doubles as a fake facade: `fake-facade <version> [args...]`.
func TestMain(m *testing.M) {
	if len(os.Args) > 2 && os.Args[1] == "fake-facade" {
		runFakeFacade(os.Args[2], os.Args[3:])
		return
	}
	os.Exit(m.Run())
}

func runFakeFacade(facadeVersion string, args []string) {
	reader := bufio.NewReader(os.Stdin)
	initialized := false
	write := func(value any) {
		line, _ := json.Marshal(value)
		os.Stdout.Write(append(line, '\n'))
	}
	for {
		line, err := reader.ReadBytes('\n')
		if len(strings.TrimSpace(string(line))) > 0 {
			var message struct {
				ID     json.RawMessage `json:"id"`
				Method string          `json:"method"`
				Params struct {
					Name string `json:"name"`
				} `json:"params"`
			}
			_ = json.Unmarshal(line, &message)
			switch message.Method {
			case "initialize":
				write(map[string]any{"jsonrpc": "2.0", "id": message.ID, "result": map[string]any{
					"protocolVersion": "2025-06-18", "capabilities": map[string]any{"tools": map[string]any{}},
					"serverInfo": map[string]any{"name": "fake", "version": facadeVersion}}})
			case "notifications/initialized":
				initialized = true
			case "tools/call":
				switch message.Params.Name {
				case "crash":
					os.Exit(3)
				case "slow":
					os.Stdout.Write([]byte(`{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"slow","progress":0}}` + "\n"))
					time.Sleep(400 * time.Millisecond)
				case "progress":
					os.Stdout.Write([]byte(`{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"p-1","progress":1,"message":"шаг 1"}}` + "\n"))
				}
				text := fmt.Sprintf("version=%s relay=%s initialized=%v args=%s", facadeVersion, os.Getenv("ITL_ONDEMAND_RELAY"), initialized, strings.Join(args, "|"))
				write(map[string]any{"jsonrpc": "2.0", "id": message.ID, "result": map[string]any{
					"content": []any{map[string]any{"type": "text", "text": text}}}})
			}
		}
		if err != nil {
			return
		}
	}
}

type relayHarness struct {
	t        *testing.T
	root     string
	server   string
	clientIn *io.PipeWriter
	lines    chan string
	nextID   int
	done     chan struct{}
}

func testExecutable(t *testing.T) (string, string) {
	t.Helper()
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(raw)
	return path, hex.EncodeToString(sum[:])
}

func (h *relayHarness) writeDescriptor(facadePath, sha, facadeVersion string, extra ...string) {
	h.t.Helper()
	args := append([]string{"fake-facade", facadeVersion}, extra...)
	raw, _ := json.Marshal(descriptor{SchemaVersion: 1, Server: h.server, Family: "vanessa-ui", FacadePath: facadePath, FacadeSha256: sha, FacadeVersion: facadeVersion, Args: args})
	path := launchDescriptorPath(h.root, h.server)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		h.t.Fatal(err)
	}
}

func newHarness(t *testing.T) *relayHarness {
	t.Helper()
	root := filepath.Join(t.TempDir(), "проект с пробелом")
	h := &relayHarness{t: t, root: root, server: "itl-vanessa-ui", lines: make(chan string, 64), done: make(chan struct{})}
	return h
}

func (h *relayHarness) start() {
	clientInR, clientInW := io.Pipe()
	clientOutR, clientOutW := io.Pipe()
	h.clientIn = clientInW
	r := newRelay(relayConfig{
		descriptorPath: launchDescriptorPath(h.root, h.server),
		evidenceRoot:   filepath.Join(h.root, ".agent-1c", "mcp", "ondemand"),
		server:         h.server, startTimeout: 10 * time.Second, stopMargin: 5 * time.Second,
		restartLimit: 3, restartWindow: 5 * time.Minute,
	})
	go func() {
		_ = r.run(clientInR, clientOutW)
		clientOutW.Close()
		close(h.done)
	}()
	go func() {
		scanner := bufio.NewScanner(clientOutR)
		scanner.Buffer(make([]byte, 1<<20), 1<<20)
		for scanner.Scan() {
			h.lines <- scanner.Text()
		}
		close(h.lines)
	}()
	h.t.Cleanup(func() {
		h.clientIn.Close()
		select {
		case <-h.done:
		case <-time.After(20 * time.Second):
			h.t.Error("relay did not stop after client EOF")
		}
	})
}

func (h *relayHarness) send(raw string) {
	h.t.Helper()
	if _, err := h.clientIn.Write([]byte(raw + "\n")); err != nil {
		h.t.Fatal(err)
	}
}

func (h *relayHarness) request(method, params string) int {
	h.nextID++
	h.send(fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":"%s","params":%s}`, h.nextID, method, params))
	return h.nextID
}

// await returns the response for id and the other lines seen before it.
func (h *relayHarness) await(id int) (map[string]any, []string) {
	h.t.Helper()
	var others []string
	timeout := time.After(15 * time.Second)
	for {
		select {
		case line, ok := <-h.lines:
			if !ok {
				h.t.Fatalf("relay output closed before response %d", id)
			}
			var message map[string]any
			if err := json.Unmarshal([]byte(line), &message); err != nil {
				h.t.Fatalf("relay wrote invalid JSON: %q", line)
			}
			if fmt.Sprint(message["id"]) == fmt.Sprint(id) {
				return message, others
			}
			others = append(others, line)
		case <-timeout:
			h.t.Fatalf("no response %d", id)
		}
	}
}

func (h *relayHarness) initialize() map[string]any {
	id := h.request("initialize", `{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}`)
	response, _ := h.await(id)
	h.send(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	return response
}

func (h *relayHarness) call(name string) (map[string]any, []string) {
	id := h.request("tools/call", fmt.Sprintf(`{"name":%q,"arguments":{}}`, name))
	return h.await(id)
}

func resultText(t *testing.T, response map[string]any) string {
	t.Helper()
	result, _ := response["result"].(map[string]any)
	if result == nil {
		t.Fatalf("response has no result: %#v", response)
	}
	var parts []string
	for _, item := range result["content"].([]any) {
		parts = append(parts, item.(map[string]any)["text"].(string))
	}
	return strings.Join(parts, "\n")
}

func resultCode(response map[string]any) string {
	result, _ := response["result"].(map[string]any)
	structured, _ := result["structuredContent"].(map[string]any)
	code, _ := structured["code"].(string)
	return code
}

func TestRelayServesTheDescribedFacadeWithExactArguments(t *testing.T) {
	h := newHarness(t)
	exe, sha := testExecutable(t)
	catalog := filepath.Join(h.root, "каталоги", "vanessa ui.json")
	h.writeDescriptor(exe, sha, "1.0", "--project-root", h.root, "--catalog", catalog)
	h.start()
	init := h.initialize()
	tools := init["result"].(map[string]any)["capabilities"].(map[string]any)["tools"].(map[string]any)
	if tools["listChanged"] != true {
		t.Fatalf("initialize result lacks listChanged: %#v", init)
	}
	response, others := h.call("progress")
	text := resultText(t, response)
	if !strings.Contains(text, "version=1.0 relay=1 initialized=true") || !strings.Contains(text, "|"+h.root+"|--catalog|"+catalog) {
		t.Fatalf("facade did not receive the described arguments and relay marker: %s", text)
	}
	want := `{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"p-1","progress":1,"message":"шаг 1"}}`
	if len(others) != 1 || others[0] != want {
		t.Fatalf("progress notification was not forwarded byte-identical: %q", others)
	}
}

func TestRelayReplacesTheFacadeBetweenRequests(t *testing.T) {
	h := newHarness(t)
	exe, sha := testExecutable(t)
	h.writeDescriptor(exe, sha, "1.0")
	h.start()
	h.initialize()
	if response, _ := h.call("echo"); !strings.Contains(resultText(t, response), "version=1.0") {
		t.Fatal("first call was not served by 1.0")
	}
	h.writeDescriptor(exe, sha, "2.0")
	response, others := h.call("echo")
	text := resultText(t, response)
	if !strings.Contains(text, "version=2.0 relay=1 initialized=true") || !strings.Contains(text, codeFacadeReplaced+": the project selected facade 2.0; the relay replaced facade 1.0") {
		t.Fatalf("call after the pin change was not served by a re-initialized 2.0 with a note: %s", text)
	}
	if len(others) != 1 || !strings.Contains(others[0], "notifications/tools/list_changed") {
		t.Fatalf("client did not get tools/list_changed: %q", others)
	}
	if response, _ := h.call("echo"); strings.Contains(resultText(t, response), codeFacadeReplaced) {
		t.Fatal("replacement note was repeated")
	}
}

func TestRelayDefersReplacementWhileARequestIsInFlight(t *testing.T) {
	h := newHarness(t)
	exe, sha := testExecutable(t)
	h.writeDescriptor(exe, sha, "1.0")
	h.start()
	h.initialize()
	slow := h.request("tools/call", `{"name":"slow","arguments":{}}`)
	// The facade's progress proves the slow call is in flight before the pin changes.
	select {
	case line := <-h.lines:
		if !strings.Contains(line, `"progressToken":"slow"`) {
			t.Fatalf("expected the slow call's progress first: %s", line)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("slow call did not start")
	}
	h.writeDescriptor(exe, sha, "2.0")
	second := h.request("tools/call", `{"name":"echo","arguments":{}}`)
	first, _ := h.await(slow)
	if !strings.Contains(resultText(t, first), "version=1.0") {
		t.Fatal("the in-flight call was interrupted")
	}
	response, _ := h.await(second)
	if !strings.Contains(resultText(t, response), "version=1.0") {
		t.Fatalf("a call sent while another was in flight was swapped: %s", resultText(t, response))
	}
	if response, _ := h.call("echo"); !strings.Contains(resultText(t, response), "version=2.0") {
		t.Fatal("replacement did not happen once nothing was in flight")
	}
}

func TestRelayKeepsTheCurrentFacadeWhenTheNewOneIsMissing(t *testing.T) {
	h := newHarness(t)
	exe, sha := testExecutable(t)
	h.writeDescriptor(exe, sha, "1.0")
	h.start()
	h.initialize()
	h.call("echo")
	h.writeDescriptor(filepath.Join(h.root, "нет файла", "facade.exe"), sha, "2.0")
	response, _ := h.call("echo")
	text := resultText(t, response)
	if !strings.Contains(text, "version=1.0") || !strings.Contains(text, codeFacadeKept+": the project selects facade 2.0") || !strings.Contains(text, "update-workflow") {
		t.Fatalf("missing facade did not keep the current one with a note: %s", text)
	}
	h.writeDescriptor(exe, strings.Repeat("0", 64), "3.0")
	if response, _ := h.call("echo"); !strings.Contains(resultText(t, response), "instead of") {
		t.Fatal("SHA mismatch was not reported")
	}
}

func TestRelayWithoutAFacadeRefusesWithTheContinuation(t *testing.T) {
	h := newHarness(t)
	_, sha := testExecutable(t)
	h.writeDescriptor(filepath.Join(h.root, "нет файла", "facade.exe"), sha, "1.0")
	h.start()
	id := h.request("initialize", `{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}`)
	response, _ := h.await(id)
	errorObject, _ := response["error"].(map[string]any)
	if errorObject == nil || !strings.Contains(errorObject["message"].(string), codeFacadeUnavailable) || !strings.Contains(errorObject["message"].(string), "update-workflow") {
		t.Fatalf("initialize without a facade was not refused: %#v", response)
	}
	call, _ := h.call("echo")
	if resultCode(call) != codeFacadeUnavailable {
		t.Fatalf("tool call without a facade did not get a tool error: %#v", call)
	}
}

func TestRelayRestartsACrashedFacadeWithinTheBound(t *testing.T) {
	h := newHarness(t)
	exe, sha := testExecutable(t)
	h.writeDescriptor(exe, sha, "1.0")
	h.start()
	h.initialize()
	for crash := 1; crash <= 4; crash++ {
		response, _ := h.call("crash")
		details := response["result"].(map[string]any)["structuredContent"].(map[string]any)["details"].(map[string]any)
		if resultCode(response) != codeFacadeExited || details["callOutcome"] != "unknown" || details["automaticRetryPerformed"] != false {
			t.Fatalf("crash %d did not report an unknown outcome: %#v", crash, response)
		}
		next, _ := h.call("echo")
		if crash <= 3 {
			text := resultText(t, next)
			if !strings.Contains(text, "version=1.0 relay=1 initialized=true") || !strings.Contains(text, codeFacadeRestarted) {
				t.Fatalf("restart %d was not served with a note: %s", crash, text)
			}
			continue
		}
		if resultCode(next) != codeRestartLimit {
			t.Fatalf("fourth crash within the window did not stop restarts: %#v", next)
		}
	}
	// A new selection is a new facade, so it is started despite the bound.
	h.writeDescriptor(exe, sha, "2.0")
	if response, _ := h.call("echo"); !strings.Contains(resultText(t, response), "version=2.0") {
		t.Fatal("a new selection was not started after the restart limit")
	}
}

func TestRelayEvidenceRecordsLifecycleWithoutPayloads(t *testing.T) {
	h := newHarness(t)
	exe, sha := testExecutable(t)
	h.writeDescriptor(exe, sha, "1.0")
	h.start()
	h.initialize()
	h.call("echo")
	h.writeDescriptor(exe, sha, "2.0")
	h.call("echo")
	path := filepath.Join(h.root, ".agent-1c", "mcp", "ondemand", "vanessa-ui", "relay-itl-vanessa-ui.jsonl")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	for _, event := range []string{`"event":"relay-started"`, `"event":"facade-started"`, `"event":"facade-stopped"`, `"event":"facade-replaced"`} {
		if !strings.Contains(text, event) {
			t.Fatalf("evidence lacks %s: %s", event, text)
		}
	}
	if strings.Contains(text, "version=1.0 relay=") || strings.Contains(text, "clientInfo") {
		t.Fatalf("evidence stored message payloads: %s", text)
	}
}
