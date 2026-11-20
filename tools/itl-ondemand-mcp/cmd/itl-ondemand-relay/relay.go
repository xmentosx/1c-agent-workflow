package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/xmentosx/1c-agent-workflow/tools/itl-ondemand-mcp/internal/childprocess"
)

const (
	codeFacadeUnavailable = "ITL_ONDEMAND_RELAY_FACADE_UNAVAILABLE"
	codeRestartLimit      = "ITL_ONDEMAND_RELAY_RESTART_LIMIT"
	codeFacadeKept        = "ITL_ONDEMAND_RELAY_FACADE_KEPT"
	codeFacadeReplaced    = "ITL_ONDEMAND_FACADE_REPLACED"
	codeFacadeRestarted   = "ITL_ONDEMAND_FACADE_RESTARTED"
	codeFacadeExited      = "ITL_ONDEMAND_FACADE_EXITED"
	updateContinuation    = "repeat update-workflow to install the facade the project selects"
)

// descriptor is written by the workflow (agent-1c.ondemand-mcp.ps1), which
// alone resolves the facade, hotfixes, overrides and catalogs.
type descriptor struct {
	SchemaVersion int      `json:"schemaVersion"`
	Server        string   `json:"server"`
	Family        string   `json:"family"`
	FacadePath    string   `json:"facadePath"`
	FacadeSha256  string   `json:"facadeSha256"`
	FacadeVersion string   `json:"facadeVersion"`
	Args          []string `json:"args"`
}

type relayConfig struct {
	descriptorPath string
	evidenceRoot   string
	server         string
	startTimeout   time.Duration
	stopMargin     time.Duration
	restartLimit   int
	restartWindow  time.Duration
}

type facadeChild struct {
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	desc     descriptor
	hash     string
	done     chan struct{}
	stopping atomic.Bool
	writeMu  sync.Mutex
}

type relayFailure struct {
	code    string
	message string
}

// relay forwards newline-delimited JSON-RPC between the MCP client and one
// facade child. Only the client loop starts or stops children; the child
// reader goroutine only forwards output and reports an unexpected exit.
type relay struct {
	cfg   relayConfig
	out   io.Writer
	outMu sync.Mutex

	mu           sync.Mutex
	child        *facadeChild
	inflight     map[string]string // raw request id -> method
	initParams   json.RawMessage
	initialized  bool
	exits        []time.Time
	pendingNote  string
	keptHash     string
	lastHash     string // descriptor of the last started facade
	handshakeID  string
	handshake    chan []byte
	serial       int
	evidenceMu   sync.Mutex
	evidenceFile string
}

func newRelay(cfg relayConfig) *relay {
	return &relay{cfg: cfg, inflight: map[string]string{}}
}

type envelope struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
}

func idKey(id json.RawMessage) string {
	text := string(bytes.TrimSpace(id))
	if text == "null" {
		return ""
	}
	return text
}

func (r *relay) run(in io.Reader, out io.Writer) error {
	r.out = out
	if desc, _, err := r.readDescriptor(); err == nil {
		r.evidence("relay-started", &desc, nil)
	}
	reader := bufio.NewReaderSize(in, 1<<20)
	for {
		line, err := reader.ReadBytes('\n')
		if len(bytes.TrimSpace(line)) > 0 {
			r.handleClient(line)
		}
		if err != nil {
			break
		}
	}
	r.mu.Lock()
	child := r.child
	r.child = nil
	r.mu.Unlock()
	if child != nil {
		r.stopChild(child)
	}
	return nil
}

func (r *relay) handleClient(line []byte) {
	var env envelope
	if json.Unmarshal(line, &env) != nil {
		r.forward(line)
		return
	}
	id := idKey(env.ID)
	switch {
	case env.Method == "initialize" && id != "":
		r.mu.Lock()
		running := r.child != nil
		r.mu.Unlock()
		if !running {
			desc, hash, err := r.readDescriptor()
			if err == nil {
				err = verifyFacade(desc)
			}
			if err == nil {
				err = r.startChild(desc, hash, "")
			}
			if err != nil {
				r.reply(id, env.Method, &relayFailure{codeFacadeUnavailable, err.Error() + "; " + updateContinuation})
				return
			}
		}
		r.mu.Lock()
		r.initParams = append(json.RawMessage(nil), env.Params...)
		r.inflight[id] = env.Method
		r.mu.Unlock()
		r.forward(line)
	case env.Method == "notifications/initialized":
		r.mu.Lock()
		r.initialized = true
		r.mu.Unlock()
		r.forward(line)
	case env.Method != "" && id != "":
		if failure := r.prepare(); failure != nil {
			r.reply(id, env.Method, failure)
			return
		}
		r.mu.Lock()
		r.inflight[id] = env.Method
		r.mu.Unlock()
		r.forward(line)
	default:
		r.forward(line)
	}
}

// prepare makes the described facade current before a request is forwarded.
// A replacement happens only while nothing is in flight.
func (r *relay) prepare() *relayFailure {
	desc, hash, readErr := r.readDescriptor()
	r.mu.Lock()
	child := r.child
	busy := len(r.inflight) > 0
	r.mu.Unlock()
	if readErr != nil {
		if child != nil {
			return nil
		}
		return &relayFailure{codeFacadeUnavailable, readErr.Error() + "; " + updateContinuation}
	}
	if child != nil && (child.hash == hash || busy) {
		return nil
	}
	if err := verifyFacade(desc); err != nil {
		if child != nil {
			r.mu.Lock()
			if r.keptHash != hash {
				r.keptHash = hash
				r.pendingNote = fmt.Sprintf("%s: the project selects facade %s, but %v; this call ran on facade %s. Please %s.", codeFacadeKept, desc.FacadeVersion, err, child.desc.FacadeVersion, updateContinuation)
			}
			r.mu.Unlock()
			r.evidence("facade-kept", &desc, map[string]any{"reason": err.Error(), "currentFacadeVersion": child.desc.FacadeVersion})
			return nil
		}
		return &relayFailure{codeFacadeUnavailable, err.Error() + "; " + updateContinuation}
	}
	var note string
	if child != nil {
		r.stopChild(child)
		r.mu.Lock()
		r.exits = nil
		r.mu.Unlock()
		note = fmt.Sprintf("%s: the project selected facade %s; the relay replaced facade %s before this call, so forms and sessions opened by earlier calls are gone.", codeFacadeReplaced, desc.FacadeVersion, child.desc.FacadeVersion)
	} else {
		r.mu.Lock()
		restarted := r.lastHash != ""
		if hash != r.lastHash {
			// A new selection is a new facade, not a restart of the failing one.
			r.exits = nil
		}
		cutoff := time.Now().Add(-r.cfg.restartWindow)
		kept := r.exits[:0]
		for _, at := range r.exits {
			if at.After(cutoff) {
				kept = append(kept, at)
			}
		}
		r.exits = kept
		exits := len(r.exits)
		r.mu.Unlock()
		if exits > r.cfg.restartLimit {
			r.evidence("restart-limit", &desc, map[string]any{"exits": exits})
			return &relayFailure{codeRestartLimit, fmt.Sprintf("the facade exited %d times within %s; the relay does not start it again in this window. Inspect .agent-1c/mcp/ondemand/%s/relay-%s.jsonl and the facade evidence, then repeat the call after the window or %s", exits, r.cfg.restartWindow, desc.Family, r.cfg.server, updateContinuation)}
		}
		if restarted {
			note = fmt.Sprintf("%s: the facade process exited unexpectedly; the relay started facade %s again before this call, so forms and sessions opened by earlier calls are gone.", codeFacadeRestarted, desc.FacadeVersion)
		}
	}
	event := "facade-started"
	if child != nil {
		event = "facade-replaced"
	}
	if err := r.startChild(desc, hash, event); err != nil {
		return &relayFailure{codeFacadeUnavailable, err.Error() + "; " + updateContinuation}
	}
	if note != "" {
		r.mu.Lock()
		r.pendingNote = note
		r.mu.Unlock()
	}
	return nil
}

func (r *relay) startChild(desc descriptor, hash, event string) error {
	cmd := childprocess.Command(desc.FacadePath, desc.Args...)
	cmd.Env = append(os.Environ(), "ITL_ONDEMAND_RELAY=1")
	cmd.Stderr = os.Stderr
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start facade %s: %w", desc.FacadePath, err)
	}
	child := &facadeChild{cmd: cmd, stdin: stdin, desc: desc, hash: hash, done: make(chan struct{})}
	r.mu.Lock()
	r.child = child
	r.lastHash = hash
	r.keptHash = ""
	params := r.initParams
	initialized := r.initialized
	r.mu.Unlock()
	go r.readChild(child, stdout)

	if params != nil {
		// The client initialized the previous facade; replay its handshake.
		r.mu.Lock()
		r.serial++
		id := fmt.Sprintf(`"itl-relay-init-%d"`, r.serial)
		response := make(chan []byte, 1)
		r.handshakeID, r.handshake = id, response
		r.mu.Unlock()
		request := fmt.Sprintf(`{"jsonrpc":"2.0","id":%s,"method":"initialize","params":%s}`, id, string(params))
		if err := child.write([]byte(request + "\n")); err != nil {
			r.abandonChild(child)
			return fmt.Errorf("replay initialize: %w", err)
		}
		select {
		case line, ok := <-response:
			if !ok {
				r.abandonChild(child)
				return errors.New("facade exited during initialize")
			}
			var reply struct {
				Error json.RawMessage `json:"error"`
			}
			if json.Unmarshal(line, &reply) == nil && len(reply.Error) > 0 && string(reply.Error) != "null" {
				r.abandonChild(child)
				return fmt.Errorf("facade rejected initialize: %s", string(reply.Error))
			}
		case <-time.After(r.cfg.startTimeout):
			r.abandonChild(child)
			return fmt.Errorf("facade did not answer initialize within %s", r.cfg.startTimeout)
		}
		if initialized {
			if err := child.write([]byte(`{"jsonrpc":"2.0","method":"notifications/initialized"}` + "\n")); err != nil {
				r.abandonChild(child)
				return fmt.Errorf("replay initialized: %w", err)
			}
		}
		r.writeClient([]byte(`{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}` + "\n"))
	}
	if event == "" {
		event = "facade-started"
	}
	r.evidence(event, &desc, map[string]any{"pid": cmd.Process.Pid})
	return nil
}

func (c *facadeChild) write(line []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_, err := c.stdin.Write(line)
	return err
}

func (r *relay) abandonChild(child *facadeChild) {
	r.mu.Lock()
	if r.child == child {
		r.child = nil
	}
	r.handshakeID, r.handshake = "", nil
	r.mu.Unlock()
	r.stopChild(child)
}

// stopChild closes the facade's input so it runs its own owned backend
// cleanup, and kills it only after that budget plus a margin.
func (r *relay) stopChild(child *facadeChild) {
	child.stopping.Store(true)
	_ = child.stdin.Close()
	select {
	case <-child.done:
	case <-time.After(cleanupBudget(child.desc.Args) + r.cfg.stopMargin):
		_ = child.cmd.Process.Kill()
		<-child.done
	}
	r.evidence("facade-stopped", &child.desc, map[string]any{"pid": child.cmd.Process.Pid})
}

func cleanupBudget(args []string) time.Duration {
	budget := time.Minute
	for index, arg := range args {
		value := ""
		switch {
		case strings.HasPrefix(arg, "--cleanup-timeout="):
			value = strings.TrimPrefix(arg, "--cleanup-timeout=")
		case arg == "--cleanup-timeout" && index+1 < len(args):
			value = args[index+1]
		}
		if parsed, err := time.ParseDuration(value); value != "" && err == nil && parsed > 0 {
			budget = parsed
		}
	}
	return budget
}

func (r *relay) readChild(child *facadeChild, stdout io.Reader) {
	reader := bufio.NewReaderSize(stdout, 1<<20)
	for {
		line, err := reader.ReadBytes('\n')
		if len(bytes.TrimSpace(line)) > 0 {
			r.handleChild(child, line)
		}
		if err != nil {
			break
		}
	}
	waitErr := child.cmd.Wait()
	close(child.done)
	if !child.stopping.Load() {
		r.childExited(child, waitErr)
	}
}

func (r *relay) handleChild(child *facadeChild, line []byte) {
	var env envelope
	if json.Unmarshal(line, &env) != nil {
		r.writeClient(line)
		return
	}
	id := idKey(env.ID)
	r.mu.Lock()
	if r.child != child {
		r.mu.Unlock()
		return
	}
	if env.Method == "" && id != "" {
		if id == r.handshakeID {
			response := r.handshake
			r.handshakeID, r.handshake = "", nil
			r.mu.Unlock()
			response <- line
			return
		}
		method, known := r.inflight[id]
		delete(r.inflight, id)
		note := ""
		if known && method == "tools/call" && r.pendingNote != "" {
			note, r.pendingNote = r.pendingNote, ""
		}
		r.mu.Unlock()
		if known && method == "initialize" {
			line = patchInitializeResult(line)
		}
		if note != "" {
			line = appendResultNote(line, note)
		}
		r.writeClient(line)
		return
	}
	r.mu.Unlock()
	r.writeClient(line)
}

// childExited answers every request the facade will never answer; none is
// replayed because its effect is unknown.
func (r *relay) childExited(child *facadeChild, waitErr error) {
	r.mu.Lock()
	if r.child != child {
		r.mu.Unlock()
		return
	}
	r.child = nil
	r.exits = append(r.exits, time.Now())
	pending := r.inflight
	r.inflight = map[string]string{}
	if r.handshake != nil {
		close(r.handshake)
		r.handshakeID, r.handshake = "", nil
	}
	r.mu.Unlock()
	exit := "exited"
	if waitErr != nil {
		exit = waitErr.Error()
	}
	r.evidence("facade-exited", &child.desc, map[string]any{"pid": child.cmd.Process.Pid, "exit": exit, "requestsInFlight": len(pending)})
	for id, method := range pending {
		r.reply(id, method, &relayFailure{codeFacadeExited, "the facade process exited (" + exit + ") before it answered; the outcome of this call is unknown and it was not replayed. Inspect the observable result before repeating it; the next call starts the facade again"})
	}
}

func (r *relay) forward(line []byte) {
	r.mu.Lock()
	child := r.child
	r.mu.Unlock()
	if child != nil {
		_ = child.write(line)
	}
}

func (r *relay) writeClient(line []byte) {
	if !bytes.HasSuffix(line, []byte("\n")) {
		line = append(line, '\n')
	}
	r.outMu.Lock()
	defer r.outMu.Unlock()
	_, _ = r.out.Write(line)
}

// reply answers a request the relay handles itself: a tool call gets a tool
// error in the facade's shape, any other request a JSON-RPC error.
func (r *relay) reply(id, method string, failure *relayFailure) {
	var message []byte
	if method == "tools/call" {
		details := map[string]any{"automaticRetryPerformed": false, "relay": true}
		if failure.code == codeFacadeExited {
			details["callOutcome"] = "unknown"
		} else {
			details["callOutcome"] = "not-started"
		}
		result := map[string]any{
			"isError":           true,
			"content":           []any{map[string]any{"type": "text", "text": failure.code + ": " + failure.message}},
			"structuredContent": map[string]any{"code": failure.code, "message": failure.message, "details": details},
		}
		message, _ = json.Marshal(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(id), "result": result})
	} else {
		message, _ = json.Marshal(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(id),
			"error": map[string]any{"code": -32603, "message": failure.code + ": " + failure.message}})
	}
	r.writeClient(message)
}

func patchInitializeResult(line []byte) []byte {
	var message map[string]any
	if json.Unmarshal(line, &message) != nil {
		return line
	}
	result, _ := message["result"].(map[string]any)
	if result == nil {
		return line
	}
	capabilities, _ := result["capabilities"].(map[string]any)
	if capabilities == nil {
		capabilities = map[string]any{}
		result["capabilities"] = capabilities
	}
	tools, _ := capabilities["tools"].(map[string]any)
	if tools == nil {
		tools = map[string]any{}
		capabilities["tools"] = tools
	}
	tools["listChanged"] = true
	patched, err := json.Marshal(message)
	if err != nil {
		return line
	}
	return append(patched, '\n')
}

func appendResultNote(line []byte, note string) []byte {
	var message map[string]any
	if json.Unmarshal(line, &message) != nil {
		return line
	}
	result, _ := message["result"].(map[string]any)
	if result == nil {
		return line
	}
	content, _ := result["content"].([]any)
	result["content"] = append(content, map[string]any{"type": "text", "text": note})
	patched, err := json.Marshal(message)
	if err != nil {
		return line
	}
	return append(patched, '\n')
}

func (r *relay) readDescriptor() (descriptor, string, error) {
	raw, err := os.ReadFile(r.cfg.descriptorPath)
	if err != nil {
		return descriptor{}, "", fmt.Errorf("launch descriptor %s is unavailable: %w", r.cfg.descriptorPath, err)
	}
	var desc descriptor
	if err := json.Unmarshal(raw, &desc); err != nil {
		return descriptor{}, "", fmt.Errorf("launch descriptor %s is invalid: %w", r.cfg.descriptorPath, err)
	}
	if desc.SchemaVersion != 1 || desc.FacadePath == "" || len(desc.FacadeSha256) != 64 {
		return descriptor{}, "", fmt.Errorf("launch descriptor %s has an unsupported schema or misses the facade identity", r.cfg.descriptorPath)
	}
	sum := sha256.Sum256(raw)
	return desc, hex.EncodeToString(sum[:]), nil
}

func verifyFacade(desc descriptor) error {
	file, err := os.Open(desc.FacadePath)
	if err != nil {
		return fmt.Errorf("facade %s is not installed (%v)", desc.FacadeVersion, err)
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return fmt.Errorf("facade %s cannot be read (%v)", desc.FacadeVersion, err)
	}
	if actual := hex.EncodeToString(hash.Sum(nil)); !strings.EqualFold(actual, desc.FacadeSha256) {
		return fmt.Errorf("installed facade %s has SHA-256 %s instead of %s", desc.FacadeVersion, actual, strings.ToLower(desc.FacadeSha256))
	}
	return nil
}

// evidence records lifecycle facts only; message payloads never reach it.
func (r *relay) evidence(event string, desc *descriptor, fields map[string]any) {
	record := map[string]any{"schemaVersion": 1, "recordedAt": time.Now().UTC().Format(time.RFC3339Nano), "event": event, "server": r.cfg.server, "relayVersion": version}
	family := ""
	if desc != nil {
		family = desc.Family
		record["family"], record["facadeVersion"], record["facadeSha256"] = desc.Family, desc.FacadeVersion, strings.ToLower(desc.FacadeSha256)
	}
	for key, value := range fields {
		record[key] = value
	}
	r.evidenceMu.Lock()
	defer r.evidenceMu.Unlock()
	if family != "" {
		r.evidenceFile = filepath.Join(r.cfg.evidenceRoot, family, "relay-"+r.cfg.server+".jsonl")
	}
	if r.evidenceFile == "" {
		return
	}
	line, err := json.Marshal(record)
	if err != nil || os.MkdirAll(filepath.Dir(r.evidenceFile), 0o755) != nil {
		return
	}
	file, err := os.OpenFile(r.evidenceFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer file.Close()
	_, _ = file.Write(append(line, '\n'))
}
