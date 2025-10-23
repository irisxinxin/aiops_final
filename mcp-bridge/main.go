package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type Config struct {
	Servers map[string]SrvSpec `json:"mcpServers"`
}
type SrvSpec struct {
	Command       string            `json:"command,omitempty"`
	Args          []string          `json:"args,omitempty"`
	Env           map[string]string `json:"env,omitempty"`
	TransportType string            `json:"transportType,omitempty"`
	Type          string            `json:"type,omitempty"`
	Disabled      bool              `json:"disabled,omitempty"`
	URL           string            `json:"url,omitempty"`
	Headers       map[string]string `json:"headers,omitempty"`
}
type rpcReq struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}
type rpcResp struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcErr         `json:"error,omitempty"`
}
type rpcErr struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}
type ToolItem struct {
	Name        string         `json:"name"`
	Description string         `json:"description,omitempty"`
	InputSchema map[string]any `json:"inputSchema,omitempty"`
}

var (
	cfgPath      = getenv("MCP_CONFIG", "./mcp.json")
	bindAddr     = getenv("BIND_ADDR", "0.0.0.0")
	bindPort     = getenv("BIND_PORT", "7011")
	timeout      = getenvDur("BACKEND_TIMEOUT", 45*time.Second)
	initRetry    = getenvInt("INIT_RETRY", 8)
	sensitiveKey = regexp.MustCompile(`(?i)(pass|password|token|secret|key|bearer)`)
)

func getenv(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}
func getenvInt(k string, def int) int {
	v := strings.TrimSpace(os.Getenv(k))
	if v == "" {
		return def
	}
	if n, err := strconv.Atoi(v); err == nil {
		return n
	}
	return def
}
func getenvDur(k string, def time.Duration) time.Duration {
	v := strings.TrimSpace(os.Getenv(k))
	if v == "" {
		return def
	}
	if d, err := time.ParseDuration(v); err == nil {
		return d
	}
	if n, err := strconv.Atoi(v); err == nil {
		return time.Duration(n) * time.Second
	}
	return def
}
func sanitizeName(s string) string {
	var b strings.Builder
	u := false
	for _, r := range s {
		ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')
		if !ok {
			if u {
				continue
			}
			b.WriteByte('_')
			u = true
			continue
		}
		b.WriteRune(r)
		u = false
	}
	out := strings.Trim(b.String(), " _")
	if out == "" {
		return "srv"
	}
	return out
}
func redactArgs(a []string) []string {
	o := append([]string(nil), a...)
	for i := 0; i < len(o); i++ {
		x := o[i]
		if x == "-e" && i+1 < len(o) {
			kvs := o[i+1]
			if eq := strings.IndexByte(kvs, '='); eq > 0 {
				name := kvs[:eq]
				if sensitiveKey.MatchString(name) {
					o[i+1] = name + "=***"
				}
			} else {
				if sensitiveKey.MatchString(kvs) {
					o[i+1] = kvs + "=***"
				}
			}
			i++
			continue
		}
		if eq := strings.IndexByte(x, '='); eq > 0 {
			name := x[:eq]
			if sensitiveKey.MatchString(name) {
				o[i] = name + "=***"
			}
		}
	}
	return o
}

type Backend interface {
	Name() string
	Initialize(context.Context) error
	ListTools(context.Context) ([]ToolItem, error)
	CallTool(context.Context, string, map[string]any) (map[string]any, error)
	Close() error
}
type stdioBackend struct {
	name    string
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	stdout  io.ReadCloser
	reader  *bufio.Reader
	closed  chan struct{}
	pending map[string]chan map[string]any
	pm      sync.Mutex
	rpcMu   sync.Mutex
	seq     int64
	sm      sync.Mutex
}

func newStdioBackend(name string, s SrvSpec) (*stdioBackend, error) {
	if s.Command == "" {
		return nil, fmt.Errorf("%s: missing command", name)
	}
	cmd := exec.Command(s.Command, s.Args...)
	cmd.Env = os.Environ()
	for k, v := range s.Env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, _ := cmd.StderrPipe()
	sa := redactArgs(s.Args)
	log.Printf("[%s] spawn stdio: %s %s", name, s.Command, strings.Join(sa, " "))
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	if stderr != nil {
		go func() {
			sc := bufio.NewScanner(stderr)
			for sc.Scan() {
				log.Printf("[%s][stderr] %s", name, sc.Text())
			}
		}()
	}
	return &stdioBackend{name: name, cmd: cmd, stdin: stdin, stdout: stdout, reader: bufio.NewReader(stdout), closed: make(chan struct{}), pending: make(map[string]chan map[string]any)}, nil
}
func (s *stdioBackend) Name() string { return s.name }
func (s *stdioBackend) Initialize(ctx context.Context) error {
	go s.readLoop()
	params := map[string]any{
		"protocolVersion": "2024-11-05",
		"capabilities": map[string]any{
			"tools": map[string]any{},
		},
		"clientInfo": map[string]any{
			"name":    "mcp-bridge",
			"version": "0.3.0",
		},
	}
	_, err := s.rpc(ctx, "initialize", params)
	return err
}
func (s *stdioBackend) ListTools(ctx context.Context) ([]ToolItem, error) {
	res, err := s.rpc(ctx, "tools/list", map[string]any{})
	if err != nil {
		return nil, err
	}
	b, _ := json.Marshal(res["tools"])
	var out []ToolItem
	_ = json.Unmarshal(b, &out)
	return out, nil
}
func (s *stdioBackend) CallTool(ctx context.Context, tool string, args map[string]any) (map[string]any, error) {
	return s.rpc(ctx, "tools/call", map[string]any{"name": tool, "arguments": args})
}
func (s *stdioBackend) Close() error {
	select {
	case <-s.closed:
	default:
		close(s.closed)
	}
	if s.cmd != nil && s.cmd.Process != nil {
		_ = s.cmd.Process.Signal(syscall.SIGTERM)
		done := make(chan struct{})
		go func() { _ = s.cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			_ = s.cmd.Process.Kill()
		}
	}
	return nil
}
func (s *stdioBackend) nextID() string {
	s.sm.Lock()
	defer s.sm.Unlock()
	s.seq++
	return strconv.FormatInt(s.seq, 10)
}
func (s *stdioBackend) rpc(ctx context.Context, method string, params map[string]any) (map[string]any, error) {
	s.rpcMu.Lock()
	defer s.rpcMu.Unlock()
	id := s.nextID()
	req := map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params}
	raw, _ := json.Marshal(req)
	ch := make(chan map[string]any, 1)
	s.pm.Lock()
	s.pending[id] = ch
	s.pm.Unlock()
	if err := s.writeFrame(raw); err != nil {
		s.removePending(id)
		return nil, err
	}
	select {
	case <-ctx.Done():
		s.removePending(id)
		return nil, ctx.Err()
	case <-s.closed:
		s.removePending(id)
		return nil, errors.New("backend closed")
	case resp := <-ch:
		if e, ok := resp["error"].(map[string]any); ok {
			return nil, fmt.Errorf("%v", e["message"])
		}
		if r, ok := resp["result"].(map[string]any); ok {
			return r, nil
		}
		return map[string]any{"result": resp["result"]}, nil
	}
}
func (s *stdioBackend) removePending(id string) { s.pm.Lock(); delete(s.pending, id); s.pm.Unlock() }
func (s *stdioBackend) readLoop() {
	for {
		payload, err := s.readFrame()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("[%s] read error: %v", s.name, err)
			}
			select {
			case <-s.closed:
			default:
				close(s.closed)
			}
			return
		}
		var msg map[string]any
		if err := json.Unmarshal(payload, &msg); err != nil {
			log.Printf("[%s] bad json: %v", s.name, err)
			continue
		}
		id := fmt.Sprint(msg["id"])
		if id == "" {
			continue
		}
		s.pm.Lock()
		ch := s.pending[id]
		if ch != nil {
			ch <- msg
			delete(s.pending, id)
		}
		s.pm.Unlock()
	}
}
func (s *stdioBackend) readFrame() ([]byte, error) {
	cl := 0
	var firstLine string
	headerMode := false

	for {
		line, err := s.reader.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimRight(line, "\r\n")

		if firstLine == "" {
			firstLine = line
			if strings.HasPrefix(line, "{") || strings.HasPrefix(line, "[") {
				return []byte(line), nil
			}
			headerMode = true
		}

		if !headerMode {
			return []byte(line), nil
		}

		if line == "" {
			break
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) == 2 && strings.EqualFold(strings.TrimSpace(parts[0]), "Content-Length") {
			cl, _ = strconv.Atoi(strings.TrimSpace(parts[1]))
		}
	}

	if cl <= 0 {
		return nil, io.EOF
	}
	body := make([]byte, cl)
	if _, err := io.ReadFull(s.reader, body); err != nil {
		return nil, err
	}
	return body, nil
}
func (s *stdioBackend) writeFrame(p []byte) error {
	var b bytes.Buffer
	fmt.Fprintf(&b, "Content-Length: %d\r\n\r\n", len(p))
	b.Write(p)
	_, err := s.stdin.Write(b.Bytes())
	return err
}

type httpBackend struct {
	name    string
	url     string
	headers map[string]string
	client  *http.Client
}

func newHTTPBackend(name string, sp SrvSpec) (*httpBackend, error) {
	if sp.URL == "" {
		return nil, fmt.Errorf("%s: http missing url", name)
	}
	return &httpBackend{name: name, url: sp.URL, headers: sp.Headers, client: &http.Client{Timeout: timeout}}, nil
}
func (h *httpBackend) Name() string { return h.name }
func (h *httpBackend) Initialize(ctx context.Context) error {
	params := map[string]any{
		"protocolVersion": "2024-11-05",
		"capabilities": map[string]any{
			"tools": map[string]any{},
		},
		"clientInfo": map[string]any{
			"name":    "mcp-bridge",
			"version": "0.3.0",
		},
	}
	_, err := h.rpc(ctx, "initialize", params)
	return err
}
func (h *httpBackend) ListTools(ctx context.Context) ([]ToolItem, error) {
	res, err := h.rpc(ctx, "tools/list", map[string]any{})
	if err != nil {
		return nil, err
	}
	b, _ := json.Marshal(res["tools"])
	var out []ToolItem
	_ = json.Unmarshal(b, &out)
	return out, nil
}
func (h *httpBackend) CallTool(ctx context.Context, tool string, args map[string]any) (map[string]any, error) {
	return h.rpc(ctx, "tools/call", map[string]any{"name": tool, "arguments": args})
}
func (h *httpBackend) rpc(ctx context.Context, method string, params map[string]any) (map[string]any, error) {
	req := rpcReq{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: method}
	if params != nil {
		b, _ := json.Marshal(params)
		req.Params = b
	}
	body, _ := json.Marshal(req)
	rq, _ := http.NewRequestWithContext(ctx, http.MethodPost, h.url, bytes.NewReader(body))
	rq.Header.Set("Content-Type", "application/json")
	for k, v := range h.headers {
		rq.Header.Set(k, v)
	}
	resp, err := h.client.Do(rq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("http %d: %s", resp.StatusCode, string(b))
	}
	var r rpcResp
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return nil, err
	}
	if r.Error != nil {
		return nil, errors.New(r.Error.Message)
	}
	switch v := r.Result.(type) {
	case map[string]any:
		return v, nil
	default:
		return map[string]any{"result": v}, nil
	}
}
func (h *httpBackend) Close() error { return nil }

type Aggregator struct {
	backends map[string]Backend
	tools    map[string][2]string
	mu       sync.RWMutex
}

func NewAggregator() *Aggregator {
	return &Aggregator{backends: map[string]Backend{}, tools: map[string][2]string{}}
}
func (a *Aggregator) StartFromConfig(c *Config) error {
	if c == nil {
		return fmt.Errorf("config is nil")
	}
	if len(c.Servers) == 0 {
		log.Printf("[bridge] no MCP servers configured, starting with empty aggregator")
		return nil
	}
	for raw, sp := range c.Servers {
		if sp.Disabled {
			log.Printf("[%s] disabled -> skip", raw)
			continue
		}
		kind := strings.ToLower(strings.TrimSpace(sp.TransportType))
		if kind == "" {
			kind = strings.ToLower(strings.TrimSpace(sp.Type))
		}
		if kind == "" {
			kind = "stdio"
		}
		name := sanitizeName(raw)
		var bk Backend
		var err error
		switch kind {
		case "stdio":
			bk, err = newStdioBackend(name, sp)
		case "http":
			bk, err = newHTTPBackend(name, sp)
		default:
			err = fmt.Errorf("unsupported transport: %s", kind)
		}
		if err != nil {
			log.Printf("[%s] backend create failed: %v", raw, err)
			continue
		}
		a.backends[name] = bk
		var initErr error
		for i := 0; i < initRetry; i++ {
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			initErr = bk.Initialize(ctx)
			cancel()
			if initErr == nil {
				break
			}
			time.Sleep(time.Second)
		}
		if initErr != nil {
			log.Printf("[%s] initialize failed after retries: %v", raw, initErr)
			continue
		}
		var tools []ToolItem
		{
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			tl, err := bk.ListTools(ctx)
			cancel()
			if err != nil {
				log.Printf("[%s] tools/list failed: %v", raw, err)
				continue
			}
			tools = tl
		}
		for _, t := range tools {
			exp := name + "." + t.Name
			a.tools[exp] = [2]string{name, t.Name}
		}
		log.Printf("[%s] ready, tools: %d", raw, len(tools))
	}
	return nil
}
func (a *Aggregator) ListExported() []ToolItem {
	a.mu.RLock()
	defer a.mu.RUnlock()
	out := make([]ToolItem, 0, len(a.tools))
	for exp, p := range a.tools {
		out = append(out, ToolItem{Name: exp, Description: fmt.Sprintf("From %s -> %s", p[0], p[1]), InputSchema: map[string]any{"type": "object"}})
	}
	return out
}
func (a *Aggregator) Call(ctx context.Context, name string, args map[string]any) (map[string]any, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	var srv, orig string
	if p, ok := a.tools[name]; ok {
		srv, orig = p[0], p[1]
	} else if !strings.Contains(name, ".") {
		c := make([][2]string, 0, 2)
		for exp, p := range a.tools {
			if strings.HasSuffix(exp, "."+name) {
				c = append(c, p)
			}
		}
		if len(c) == 1 {
			srv, orig = c[0][0], c[0][1]
		} else {
			return nil, fmt.Errorf("unknown or ambiguous tool: %s", name)
		}
	} else {
		return nil, fmt.Errorf("unknown tool: %s", name)
	}
	bk := a.backends[srv]
	if bk == nil {
		return nil, fmt.Errorf("backend missing: %s", srv)
	}
	return bk.CallTool(ctx, orig, args)
}
func (a *Aggregator) Close() {
	for _, bk := range a.backends {
		_ = bk.Close()
	}
}

type httpServer struct {
	agg     *Aggregator
	timeout time.Duration
	mux     *http.ServeMux
}

func newHTTP(agg *Aggregator) *httpServer {
	s := &httpServer{agg: agg, timeout: timeout, mux: http.NewServeMux()}
	s.routes()
	return s
}
func (s *httpServer) routes() {
	// 认证跳过中间件
	authSkipMiddleware := func(next http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			// 检查是否来自本机
			clientIP := r.RemoteAddr
			if host, _, err := net.SplitHostPort(clientIP); err == nil {
				clientIP = host
			}

			// 跳过认证的条件：
			// 1. 来自127.0.0.1或::1
			// 2. 带有X-Internal-Call: 1 header
			skipAuth := clientIP == "127.0.0.1" || clientIP == "::1" ||
				r.Header.Get("X-Internal-Call") == "1"

			if skipAuth {
				// 跳过认证，直接处理请求
				next(w, r)
				return
			}

			// 其他情况需要认证（这里可以添加OAuth逻辑）
			next(w, r)
		}
	}

	s.mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "tools": len(s.agg.tools), "ts": time.Now().Unix()})
	})

	s.mux.HandleFunc("/register", authSkipMiddleware(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok","message":"registration successful"}`))
	}))
	s.mux.HandleFunc("/authorize", authSkipMiddleware(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok","message":"auth skipped for localhost"}`))
	}))

	// 添加OAuth相关路径的通配符处理
	s.mux.HandleFunc("/oauth/", authSkipMiddleware(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok","message":"oauth skipped for localhost"}`))
	}))

	s.mux.HandleFunc("/token", authSkipMiddleware(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"access_token":"dummy","token_type":"Bearer"}`))
	}))

	s.mux.HandleFunc("/mcp", func(w http.ResponseWriter, r *http.Request) {
		// --- GET + SSE 探测：必须返回纯文本路径 ---
		if r.Method == http.MethodGet && wantsSSE(r) {
			flusher, ok := beginSSE(w)
			if !ok { 
				return 
			}
			// FIX: endpoint 事件的 data 必须是纯文本 "/mcp"
			sendSSERaw(w, flusher, "endpoint", "/mcp")
			// 心跳可选
			ticker := time.NewTicker(30 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-r.Context().Done():
					return
				case <-ticker.C:
					fmt.Fprint(w, ": ping\n\n")
					flusher.Flush()
				}
			}
		}
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		var req rpcReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			// 按 Accept 协商（SSE/JSON）返回解析错误
			resp := rpcResp{JSONRPC: "2.0", ID: req.ID, Error: &rpcErr{Code: -32700, Message: "Parse error"}}
			if wantsSSE(r) { 
				writeRPCSSE(w, resp)
				return 
			}
			writeRPC(w, resp)
			return
		}
		// --- FIX: JSON-RPC notification（无 id）不得返回 JSON-RPC 响应 ---
		if len(bytes.TrimSpace(req.ID)) == 0 {
			w.WriteHeader(http.StatusNoContent) // 204，无响应体
			return
		}
		switch req.Method {
		case "initialize":
			// 其余保持你原有逻辑；如有 SSE，记得用 writeRPCSSE 返回
			resp := rpcResp{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{
				"protocolVersion": "2025-06-18",
				"capabilities":    map[string]any{"tools": map[string]any{}},
				"serverInfo":      map[string]any{"name": "mcp-http-bridge", "version": "0.3.0"},
			}}
			if wantsSSE(r) { 
				writeRPCSSE(w, resp)
				return 
			}
			writeRPC(w, resp)
			return
		case "tools/list":
			tools := s.agg.ListExported()
			resp := rpcResp{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{"tools": tools}}
			if wantsSSE(r) { 
				writeRPCSSE(w, resp)
				return 
			}
			writeRPC(w, resp)
			return
		case "tools/call":
			var p struct {
				Name      string         `json:"name"`
				Arguments map[string]any `json:"arguments"`
			}
			if len(req.Params) > 0 {
				if err := json.Unmarshal(req.Params, &p); err != nil {
					resp := rpcResp{JSONRPC: "2.0", ID: req.ID, Error: &rpcErr{Code: -32602, Message: "Invalid params"}}
					if wantsSSE(r) { 
						writeRPCSSE(w, resp)
						return 
					}
					writeRPC(w, resp)
					return
				}
			}
			ctx, cancel := context.WithTimeout(r.Context(), s.timeout)
			defer cancel()
			res, err := s.agg.Call(ctx, p.Name, p.Arguments)
			if err != nil {
				resp := rpcResp{JSONRPC: "2.0", ID: req.ID, Error: &rpcErr{Code: -32000, Message: err.Error()}}
				if wantsSSE(r) { 
					writeRPCSSE(w, resp)
					return 
				}
				writeRPC(w, resp)
				return
			}
			resp := rpcResp{JSONRPC: "2.0", ID: req.ID, Result: res}
			if wantsSSE(r) { 
				writeRPCSSE(w, resp)
				return 
			}
			writeRPC(w, resp)
			return
		default:
			resp := rpcResp{JSONRPC: "2.0", ID: req.ID, Error: &rpcErr{Code: -32601, Message: "Method not found"}}
			if wantsSSE(r) { 
				writeRPCSSE(w, resp)
				return 
			}
			writeRPC(w, resp)
			return
		}
	})
}
func writeRPC(w http.ResponseWriter, resp rpcResp) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// --- 新增：发送"原始文本"的 SSE 事件（不做 JSON 编码） ---
func sendSSERaw(w http.ResponseWriter, flusher http.Flusher, event, raw string) {
	if event == "" { 
		event = "message" 
	}
	fmt.Fprintf(w, "event: %s\n", event)
	// 关键：这里直接写纯文本路径，不包引号、不做 JSON
	fmt.Fprintf(w, "data: %s\n\n", strings.TrimRight(raw, "\n"))
	flusher.Flush()
}

// SSE helpers
func wantsSSE(r *http.Request) bool {
	return strings.Contains(strings.ToLower(r.Header.Get("Accept")), "text/event-stream")
}
func beginSSE(w http.ResponseWriter) (http.Flusher, bool) {
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no") // 反代时禁缓冲
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", 500)
		return nil, false
	}
	return flusher, true
}
func writeRPCJSON(w http.ResponseWriter, resp rpcResp) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func writeRPCSSE(w http.ResponseWriter, resp rpcResp) {
	flusher, ok := beginSSE(w)
	if !ok {
		return
	}
	b, _ := json.Marshal(resp)
	// 一条事件承载本次 JSON-RPC 响应，并立刻 flush
	fmt.Fprintf(w, "event: message\n")
	fmt.Fprintf(w, "data: %s\n\n", b)
	flusher.Flush()
}
func (s *httpServer) serve(addr string) error {
	httpSrv := &http.Server{Addr: addr, Handler: s.mux, ReadHeaderTimeout: 5 * time.Second}
	idle := make(chan struct{})
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		_ = httpSrv.Shutdown(context.Background())
		close(idle)
	}()
	log.Printf("[bridge] listening on %s", addr)
	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	<-idle
	return nil
}
func main() {
	abs, _ := filepath.Abs(cfgPath)
	log.Printf("[bridge] loading %s", abs)
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		log.Fatalf("read config: %v", err)
	}
	var c Config
	if err := json.Unmarshal(raw, &c); err != nil {
		log.Fatalf("parse config: %v", err)
	}
	agg := NewAggregator()
	if err := agg.StartFromConfig(&c); err != nil {
		log.Fatalf("start backends: %v", err)
	}
	defer agg.Close()
	srv := newHTTP(agg)
	if err := srv.serve(bindAddr + ":" + bindPort); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
