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
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"text/template"
	"time"
)

// -------------------- Config --------------------

type Config struct {
	QBin   string            `json:"q_bin"`   // e.g. "q"
	QArgs  []string          `json:"q_args"`  // e.g. ["ask"]
	MCPEng map[string]string `json:"mcp_env"` // optional env vars for MCP bridge/server
}

func loadConfig(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, err
	}
	if c.QBin == "" {
		c.QBin = "q"
	}
	if len(c.QArgs) == 0 {
		c.QArgs = []string{"ask"}
	}
	return &c, nil
}

type ValidationIssue struct {
	Field   string `json:"field"`
	Message string `json:"message"`
}

type ValidationReport struct {
	OK     bool              `json:"ok"`
	Issues []ValidationIssue `json:"issues,omitempty"`
	Notes  []string          `json:"notes,omitempty"`
}

func validateConfig(c *Config) ValidationReport {
	var rep ValidationReport
	// MCP env hints
	if len(c.MCPEng) == 0 {
		rep.Notes = append(rep.Notes, "mcp_env is empty; ensure Q can discover your MCP server via other means.")
	} else {
		// show which keys exist (values redacted in response later)
	}
	rep.OK = len(rep.Issues) == 0
	return rep
}

// -------------------- SOP --------------------

type SOP struct {
	ID             string            `json:"id"`
	Title          string            `json:"title"`
	Description    string            `json:"description"`
	RequiredParams []string          `json:"required_params"`
	Defaults       map[string]string `json:"defaults"`
	Template       string            `json:"template"`
	ExpectedSource string            `json:"expected_source,omitempty"` // e.g. "mcp:victoriametrics", "mcp:cloudwatch", "mcp:elasticsearch"
}

type SOPStore struct {
	byID    map[string]*SOP // key: incident_key
	bySOPID map[string]*SOP // key: sop_id (文件名)
	mu      sync.RWMutex
	dir     string
	mapping map[string]string // sop_id -> incident_key 映射
}

func NewSOPStore(dir string) (*SOPStore, error) {
	s := &SOPStore{
		byID:    make(map[string]*SOP),
		bySOPID: make(map[string]*SOP),
		dir:     dir,
		mapping: make(map[string]string),
	}
	if err := s.Reload(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *SOPStore) Reload() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return err
	}
	byID := make(map[string]*SOP)      // incident_key -> SOP
	bySOPID := make(map[string]*SOP)   // sop_id -> SOP
	mapping := make(map[string]string) // sop_id -> incident_key

	// 首先加载映射文件
	mappingPath := filepath.Join(s.dir, "sop_mapping.json")
	if b, err := os.ReadFile(mappingPath); err == nil {
		json.Unmarshal(b, &mapping)
	}

	loadSOP := func(sop *SOP, sopID string, src string) error {
		if sop.ID == "" {
			return fmt.Errorf("sop %s missing id", src)
		}
		if sop.Template == "" {
			return fmt.Errorf("sop %s missing template", src)
		}
		// infer expected source if empty
		if sop.ExpectedSource == "" {
			low := strings.ToLower(sop.Template + " " + sop.Title + " " + sop.Description)
			switch {
			case strings.Contains(low, "victoriametrics") || strings.Contains(low, "up 指标") || strings.Contains(low, "vmendpoint"):
				sop.ExpectedSource = "mcp:victoriametrics"
			case strings.Contains(low, "cloudwatch") || strings.Contains(low, "aws/ec2"):
				sop.ExpectedSource = "mcp:cloudwatch"
			case strings.Contains(low, "elasticsearch") || strings.Contains(low, "es "):
				sop.ExpectedSource = "mcp:elasticsearch"
			default:
				sop.ExpectedSource = "mcp:unknown"
			}
		}
		byID[sop.ID] = sop   // 按incident_key索引
		bySOPID[sopID] = sop // 按sop_id索引
		return nil
	}

	for _, e := range entries {
		name := e.Name()
		if e.IsDir() {
			continue
		}
		if strings.HasPrefix(name, "._") {
			continue
		}
		if name == "sop_mapping.json" {
			continue // 跳过映射文件
		}
		low := strings.ToLower(name)
		path := filepath.Join(s.dir, name)

		switch {
		case strings.HasSuffix(low, ".json"):
			b, err := os.ReadFile(path)
			if err != nil {
				return fmt.Errorf("read %s: %w", path, err)
			}
			var sop SOP
			if err := json.Unmarshal(b, &sop); err != nil {
				return fmt.Errorf("unmarshal %s: %w", path, err)
			}
			// 文件名格式：sop_xxxx.json，去掉扩展名得到sop_id
			if strings.HasPrefix(name, "sop_") {
				sopID := strings.TrimSuffix(name, ".json")
				if err := loadSOP(&sop, sopID, path); err != nil {
					return err
				}
			}
		case strings.HasSuffix(low, ".jsonl"):
			f, err := os.Open(path)
			if err != nil {
				return fmt.Errorf("open %s: %w", path, err)
			}
			sc := bufio.NewScanner(f)
			ln := 0
			for sc.Scan() {
				ln++
				line := strings.TrimSpace(sc.Text())
				if line == "" {
					continue
				}
				var sop SOP
				if err := json.Unmarshal([]byte(line), &sop); err != nil {
					_ = f.Close()
					return fmt.Errorf("unmarshal %s:%d: %w", path, ln, err)
				}
				sopID := fmt.Sprintf("%s_%d", strings.TrimSuffix(name, ".jsonl"), ln)
				if err := loadSOP(&sop, sopID, fmt.Sprintf("%s:%d", path, ln)); err != nil {
					_ = f.Close()
					return err
				}
			}
			if err := sc.Err(); err != nil {
				_ = f.Close()
				return fmt.Errorf("scan %s: %w", path, err)
			}
			_ = f.Close()
		default:
			continue
		}
	}
	s.byID = byID
	s.bySOPID = bySOPID
	s.mapping = mapping
	return nil
}

func (s *SOPStore) Get(id string) (*SOP, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.byID[id]
	return v, ok
}

func (s *SOPStore) GetBySOPID(sopID string) (*SOP, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.bySOPID[sopID]
	return v, ok
}

// 从incident_key生成sop_id的辅助函数
func generateSOPIDFromIncidentKey(incidentKey string) string {
	// 从incident_key生成sop_xxxxxx格式的sop_id (6位数字)
	// incident_key格式：env|region|title|service|group_id
	// 例如：dev|dev-nbu-aps1|sdn5 container CPU usage is too high|sdn5|sdn5_critical -> sop_511470
	// 使用hash生成6位数字ID
	hash := 0
	for _, c := range incidentKey {
		hash = hash*31 + int(c)
	}
	// 取绝对值并格式化为6位数字
	if hash < 0 {
		hash = -hash
	}
	return fmt.Sprintf("sop_%06d", hash%1000000)
}

func (s *SOPStore) List() []*SOP {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]*SOP, 0, len(s.byID))
	for _, v := range s.byID {
		out = append(out, v)
	}
	return out
}

// -------------------- Runner --------------------

type RunRequest struct {
	SOPID  string            `json:"sop_id"`
	Params map[string]string `json:"params"`
	Reset  bool              `json:"reset,omitempty"` // if true, clears the resume dir for this sop_id
}

type QValidation struct {
	PromptAppended bool           `json:"prompt_appended"`
	ExpectedSource string         `json:"expected_source"`
	FoundJSON      bool           `json:"found_json"`
	Parsed         map[string]any `json:"parsed,omitempty"`
	OK             bool           `json:"ok"`
	FailReason     string         `json:"fail_reason,omitempty"`
}

type RunResponse struct {
	OK               bool              `json:"ok"`
	Error            string            `json:"error,omitempty"`
	SOPID            string            `json:"sop_id,omitempty"`
	Prompt           string            `json:"prompt,omitempty"`
	QStdout          string            `json:"q_stdout,omitempty"`
	QStderr          string            `json:"q_stderr,omitempty"`
	ResumeDir        string            `json:"resume_dir,omitempty"`
	Required         []string          `json:"required_params,omitempty"`
	UsedParams       map[string]string `json:"used_params,omitempty"`
	DurationMs       int64             `json:"duration_ms,omitempty"`
	ParamValidation  ValidationReport  `json:"param_validation"`
	ConfigValidation ValidationReport  `json:"config_validation"`
	QValidation      QValidation       `json:"q_validation"`
	MCPEngineKeys    []string          `json:"mcp_engine_keys,omitempty"`
}

type TemplateData struct {
	Params map[string]string
	Now    string
}

type Server struct {
	cfg       *Config
	sops      *SOPStore
	resumeTop string
	logger    *log.Logger
}

func NewServer(cfg *Config, sops *SOPStore, resumeTop string) *Server {
	l := log.New(os.Stdout, "[qproxy] ", log.LstdFlags|log.Lmicroseconds)
	return &Server{cfg: cfg, sops: sops, resumeTop: resumeTop, logger: l}
}

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// (duplicate removed) writeJSON

func (s *Server) handleRun(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	var req RunRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, RunResponse{OK: false, Error: "invalid JSON body"})
		return
	}
	if req.SOPID == "" {
		writeJSON(w, http.StatusBadRequest, RunResponse{OK: false, Error: "missing sop_id"})
		return
	}
	sop, ok := s.sops.GetBySOPID(req.SOPID)
	if !ok {
		writeJSON(w, http.StatusNotFound, RunResponse{OK: false, Error: "unknown sop_id"})
		return
	}
	params := map[string]string{}
	// merge defaults
	for k, v := range sop.Defaults {
		params[k] = v
	}
	// overlay request params
	for k, v := range req.Params {
		params[k] = v
	}

	// validate required
	var missing []string
	for _, k := range sop.RequiredParams {
		if strings.TrimSpace(params[k]) == "" {
			missing = append(missing, k)
		}
	}
	if len(missing) > 0 {
		writeJSON(w, http.StatusBadRequest, RunResponse{
			OK: false, Error: "missing required params", Required: sop.RequiredParams, UsedParams: params, SOPID: sop.ID,
		})
		return
	}

	// param validation using sdn5_cpu as baseline
	pv := s.validateParams(sop, params)

	// config validation
	cv := validateConfig(s.cfg)

	// render template
	tmpl, err := template.New(sop.ID).Option("missingkey=error").Parse(sop.Template)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, RunResponse{OK: false, Error: "bad sop template: " + err.Error()})
		return
	}
	data := TemplateData{
		Params: params,
		Now:    time.Now().Format(time.RFC3339),
	}
	var promptBuf bytes.Buffer
	if err := tmpl.Execute(&promptBuf, data); err != nil {
		writeJSON(w, http.StatusInternalServerError, RunResponse{OK: false, Error: "template exec error: " + err.Error()})
		return
	}
	prompt := promptBuf.String()

	// append validation block instruction
	validationSuffix := buildValidationSuffix(sop.ExpectedSource)
	promptAppended := false
	if !strings.Contains(strings.ToLower(prompt), "\"verdict\"") {
		prompt = prompt + "\n\n" + validationSuffix
		promptAppended = true
	}

	// resume dir per sop_id
	resumeDir := filepath.Join(s.resumeTop, req.SOPID)
	if req.Reset {
		_ = os.RemoveAll(resumeDir)
	}
	if err := os.MkdirAll(resumeDir, 0o755); err != nil {
		writeJSON(w, http.StatusInternalServerError, RunResponse{OK: false, Error: "resume dir create: " + err.Error()})
		return
	}

	// audit / history
	if err := appendHistory(resumeDir, prompt); err != nil {
		s.logger.Printf("append history error: %v", err)
	}

	// invoke Q CLI
	stdout, stderr, err := s.runQ(r.Context(), resumeDir, prompt)

	// parse Q validation block
	qv := parseQValidation(stdout, sop.ExpectedSource, promptAppended)

	resp := RunResponse{
		OK:               err == nil && qv.OK && pv.OK && cv.OK,
		Error:            "",
		SOPID:            sop.ID,
		Prompt:           prompt,
		QStdout:          stdout,
		QStderr:          stderr,
		ResumeDir:        resumeDir,
		UsedParams:       params,
		DurationMs:       time.Since(start).Milliseconds(),
		ParamValidation:  pv,
		ConfigValidation: cv,
		QValidation:      qv,
	}
	// expose MCP env keys used (values not exposed)
	for k := range s.cfg.MCPEng {
		resp.MCPEngineKeys = append(resp.MCPEngineKeys, k)
	}
	if err != nil {
		resp.Error = err.Error()
	}
	writeJSON(w, http.StatusOK, resp)
}

func buildValidationSuffix(expected string) string {
	if expected == "" {
		expected = "mcp:unknown"
	}
	return fmt.Sprintf("请在答案**最后**追加一段用于正确性校验的 JSON，并使用 ```json 代码块包裹，严格如下键名：\n"+
		"```json\n"+
		"{\"verdict\":\"ok|fail\",\"source\":\"%s\",\"evidence_count\": 0}\n"+
		"```\n"+
		"要求：\n"+
		"1) \"verdict\" 只能是 \"ok\" 或 \"fail\"；\n"+
		"2) \"source\" 固定为上面的值，表示使用了对应的 MCP 工具；\n"+
		"3) \"evidence_count\" 为你基于 MCP 结果给出的证据条数（>=0）。", expected)
}

func parseQValidation(stdout string, expected string, appended bool) QValidation {
	qv := QValidation{PromptAppended: appended, ExpectedSource: expected}

	// 首先尝试解析主要的分析JSON（根据真实对话例子）
	mainJSONRe := regexp.MustCompile(`(?s)json\s*\n(\{.*?\})`)
	mainMatches := mainJSONRe.FindAllStringSubmatch(stdout, -1)

	// 然后查找验证JSON块
	validationRe := regexp.MustCompile("(?s)```json\\s*(\\{.*?\\})\\s*```")
	validationMatches := validationRe.FindAllStringSubmatch(stdout, -1)

	// 优先处理验证JSON块
	var blk string
	if len(validationMatches) > 0 {
		blk = validationMatches[len(validationMatches)-1][1]
		qv.FoundJSON = true
	} else if len(mainMatches) > 0 {
		// 如果没有验证块，尝试解析主要JSON
		blk = mainMatches[len(mainMatches)-1][1]
		qv.FoundJSON = true
	} else {
		qv.OK = false
		qv.FailReason = "no json block found"
		return qv
	}

	var parsed map[string]any
	if err := json.Unmarshal([]byte(blk), &parsed); err != nil {
		qv.OK = false
		qv.FailReason = "invalid json block"
		return qv
	}
	qv.Parsed = parsed

	// 检查是否有verdict字段（验证块）
	if verdict, ok := parsed["verdict"].(string); ok {
		source, _ := parsed["source"].(string)
		ec := -1
		switch v := parsed["evidence_count"].(type) {
		case float64:
			ec = int(v)
		case int:
			ec = v
		}
		if verdict != "ok" {
			qv.OK = false
			qv.FailReason = "verdict not ok"
			return qv
		}
		if expected != "" && source != expected {
			qv.OK = false
			qv.FailReason = fmt.Sprintf("unexpected source: want %s got %s", expected, source)
			return qv
		}
		if ec < 0 {
			qv.OK = false
			qv.FailReason = "evidence_count < 0"
			return qv
		}
		qv.OK = true
		return qv
	}

	// 如果没有verdict字段，检查是否是主要分析JSON
	if _, hasToolCalls := parsed["tool_calls"]; hasToolCalls {
		// 这是主要分析JSON，认为验证通过
		qv.OK = true
		return qv
	}

	qv.OK = false
	qv.FailReason = "no valid json structure found"
	return qv
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func (s *Server) validateParams(sop *SOP, params map[string]string) ValidationReport {
	var rep ValidationReport
	add := func(f, m string) { rep.Issues = append(rep.Issues, ValidationIssue{Field: f, Message: m}) }

	// Generic validators
	durationRe := regexp.MustCompile(`^[0-9]+[smhdw]$`)
	if v := params["lookback"]; v != "" && !durationRe.MatchString(v) {
		add("lookback", "must be duration like 5m/1h/2d/1w")
	}
	if v := params["cpu_threshold"]; v != "" {
		// optional param some SOPs may use
		if n, err := strconv.Atoi(v); err != nil || n < 1 || n > 100 {
			add("cpu_threshold", "must be 1..100")
		}
	}
	// EC2 instance id
	if v := params["instance_id"]; v != "" && !regexp.MustCompile(`^i-[0-9a-fA-F]+$`).MatchString(v) {
		add("instance_id", "must look like i-xxxxxxxx")
	}
	// tenant, index, query basic checks
	if v := params["tenant"]; v != "" && !regexp.MustCompile(`^[A-Za-z0-9._-]+$`).MatchString(v) {
		add("tenant", "must be alnum/._-")
	}
	if v := params["index"]; v != "" && strings.ContainsAny(v, " \t\r\n") {
		add("index", "must not contain whitespace")
	}
	if v := params["query"]; v != "" && len(v) > 300 {
		add("query", "too long (>300)")
	}

	rep.OK = len(rep.Issues) == 0
	return rep
}

// -------------------- Server --------------------

// (duplicate removed) Server/NewServer

func (s *Server) runQ(ctx context.Context, resumeDir, prompt string) (string, string, error) {
	args := make([]string, 0, len(s.cfg.QArgs)+6)
	args = append(args, s.cfg.QArgs...)
	args = append(args, "--agent", "remote-mcp", "--no-interactive", "--trust-all-tools", "--resume")

	cmd := exec.CommandContext(ctx, s.cfg.QBin, args...)
	cmd.Env = os.Environ()
	for k, v := range s.cfg.MCPEng {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}

	// 设置工作目录为resumeDir，这样q命令会在正确的会话目录下运行
	cmd.Dir = resumeDir

	cmd.Stdin = strings.NewReader(prompt)
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf

	tctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()

	done := make(chan error, 1)
	go func() { done <- cmd.Run() }()

	select {
	case e := <-done:
		stdout := strings.TrimSpace(outBuf.String())
		stderr := strings.TrimSpace(errBuf.String())
		if e != nil {
			return stdout, stderr, fmt.Errorf("q exec failed: %w", e)
		}
		return stdout, stderr, nil
	case <-tctx.Done():
		_ = cmd.Process.Kill()
		return strings.TrimSpace(outBuf.String()), strings.TrimSpace(errBuf.String()), errors.New("q exec timeout")
	}
}

func appendHistory(dir, prompt string) error {
	hist := filepath.Join(dir, "history.log")
	f, err := os.OpenFile(hist, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	ts := time.Now().Format("2006-01-02 15:04:05")
	_, _ = io.WriteString(f, fmt.Sprintf("\n[%s]\n%s\n", ts, prompt))
	_ = f.Sync()
	_ = os.WriteFile(filepath.Join(dir, "latest_prompt.txt"), []byte(prompt), 0o644)
	return nil
}

// (duplicate removed) handlers

// askJSON: accept alert JSON, extract params, locate SOP by sop_id (optional), and execute
func (s *Server) askJSON(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	// parse arbitrary json
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, RunResponse{OK: false, Error: "invalid JSON body"})
		return
	}
	// determine sop_id
	sopID := ""
	if v, ok := body["sop_id"].(string); ok {
		sopID = v
	}
	if sopID == "" {
		// try alert.sop_id
		if a, ok := body["alert"].(map[string]any); ok {
			if v, ok := a["sop_id"].(string); ok {
				sopID = v
			}
		}
	}
	if sopID == "" {
		// 尝试从incident_key生成sop_id
		if incidentKey, ok := body["incident_key"].(string); ok {
			sopID = generateSOPIDFromIncidentKey(incidentKey)
		}
	}
	if sopID == "" {
		// if only one SOP exists, use it; else error
		list := s.sops.List()
		if len(list) == 1 {
			// 从映射中获取sop_id
			for sopIDFromMapping := range s.sops.mapping {
				sopID = sopIDFromMapping
				break
			}
		}
	}
	if sopID == "" {
		writeJSON(w, http.StatusBadRequest, RunResponse{OK: false, Error: "missing sop_id and multiple SOPs present"})
		return
	}
	sop, ok := s.sops.GetBySOPID(sopID)
	if !ok {
		writeJSON(w, http.StatusNotFound, RunResponse{OK: false, Error: "unknown sop_id"})
		return
	}
	// build params from alert payload
	params := map[string]string{}

	// 设置sop_id参数
	params["sop_id"] = sopID

	// 从请求体中提取告警参数
	var incidentKey string

	// 优先从alert对象中提取参数
	if alert, ok := body["alert"].(map[string]any); ok {
		// 构建incident_key: env|region|title|service|group_id
		env, _ := alert["env"].(string)
		region, _ := alert["region"].(string)
		title, _ := alert["title"].(string)
		service, _ := alert["service"].(string)
		groupID, _ := alert["group_id"].(string)

		if env != "" && region != "" && title != "" && service != "" && groupID != "" {
			incidentKey = fmt.Sprintf("%s|%s|%s|%s|%s", env, region, title, service, groupID)
		}

		// 提取其他参数
		if status, ok := alert["status"].(string); ok {
			params["status"] = status
		}
		if category, ok := alert["category"].(string); ok {
			params["category"] = category
		}
		if threshold, ok := alert["threshold"].(float64); ok {
			params["threshold"] = fmt.Sprintf("%.1f", threshold)
		}
		if window, ok := alert["window"].(string); ok {
			params["window"] = window
		}

		// 从metadata中提取current_value
		if metadata, ok := alert["metadata"].(map[string]any); ok {
			if currentValue, ok := metadata["current_value"].(float64); ok {
				params["current_value"] = fmt.Sprintf("%.2f", currentValue)
			}
		}
	}

	// 如果从alert中没找到，尝试直接从body中提取
	if incidentKey == "" {
		if v, ok := body["incident_key"].(string); ok {
			incidentKey = v
		}
	}

	params["incident_key"] = incidentKey

	// 兼容旧的alert结构
	if a, ok := body["alert"].(map[string]any); ok {
		if md, ok := a["metadata"].(map[string]any); ok {
			if exp, ok := md["expression"].(string); ok {
				params["expression"] = exp
			}
		}
	}

	// merge defaults
	for k, v := range sop.Defaults {
		if _, exists := params[k]; !exists {
			params[k] = v
		}
	}

	// render template
	tmpl, err := template.New(sop.ID).Option("missingkey=error").Parse(sop.Template)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, RunResponse{OK: false, Error: "bad sop template: " + err.Error()})
		return
	}
	data := TemplateData{Params: params, Now: time.Now().Format(time.RFC3339)}
	var promptBuf bytes.Buffer
	if err := tmpl.Execute(&promptBuf, data); err != nil {
		writeJSON(w, http.StatusInternalServerError, RunResponse{OK: false, Error: "template exec error: " + err.Error()})
		return
	}
	prompt := promptBuf.String()
	validationSuffix := buildValidationSuffix(sop.ExpectedSource)
	if !strings.Contains(strings.ToLower(prompt), "\"verdict\"") {
		prompt = prompt + "\n\n" + validationSuffix
	}
	// resume dir per sop_id
	resumeDir := filepath.Join(s.resumeTop, sopID)
	if err := os.MkdirAll(resumeDir, 0o755); err != nil {
		writeJSON(w, http.StatusInternalServerError, RunResponse{OK: false, Error: "resume dir create: " + err.Error()})
		return
	}
	_ = appendHistory(resumeDir, prompt)
	// DRY-RUN support: if QPROXY_DRY_RUN=1 or query dry=1, skip Q execution and just return prompt
	if isDryRun(r) {
		pv := s.validateParams(sop, params)
		cv := validateConfig(s.cfg)
		resp := RunResponse{
			OK:               pv.OK && cv.OK,
			SOPID:            sop.ID,
			Prompt:           prompt,
			QStdout:          "",
			QStderr:          "",
			ResumeDir:        resumeDir,
			UsedParams:       params,
			DurationMs:       time.Since(start).Milliseconds(),
			ParamValidation:  pv,
			ConfigValidation: cv,
			QValidation:      QValidation{PromptAppended: true, ExpectedSource: sop.ExpectedSource, FoundJSON: false, OK: true, FailReason: "dry-run"},
		}
		writeJSON(w, http.StatusOK, resp)
		return
	}

	stdout, stderr, err := s.runQ(r.Context(), resumeDir, prompt)
	qv := parseQValidation(stdout, sop.ExpectedSource, true)
	// minimal reports
	pv := s.validateParams(sop, params)
	cv := validateConfig(s.cfg)
	resp := RunResponse{
		OK: err == nil && qv.OK && pv.OK && cv.OK,
		Error: func() string {
			if err != nil {
				return err.Error()
			}
			return ""
		}(),
		SOPID:            sop.ID,
		Prompt:           prompt,
		QStdout:          stdout,
		QStderr:          stderr,
		ResumeDir:        resumeDir,
		UsedParams:       params,
		DurationMs:       time.Since(start).Milliseconds(),
		ParamValidation:  pv,
		ConfigValidation: cv,
		QValidation:      qv,
	}
	writeJSON(w, http.StatusOK, resp)
}

func isDryRun(r *http.Request) bool {
	if v := strings.ToLower(strings.TrimSpace(os.Getenv("QPROXY_DRY_RUN"))); v != "" && v != "0" && v != "false" {
		return true
	}
	if r != nil {
		d := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("dry")))
		if d == "1" || d == "true" || d == "yes" {
			return true
		}
	}
	return false
}

// -------------------- main --------------------

func main() {
	baseDir, _ := os.Getwd()
	configPath := filepath.Join(baseDir, "config", "config.json")
	if v := os.Getenv("QPROXY_CONFIG"); v != "" {
		configPath = v
	}
	cfg, err := loadConfig(configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	sopsDir := filepath.Join(baseDir, "sops")
	if v := os.Getenv("QPROXY_SOPS_DIR"); v != "" {
		sopsDir = v
	}
	resumeTop := filepath.Join(baseDir, "q-sessions")
	if v := os.Getenv("QPROXY_SESSIONS_DIR"); v != "" {
		resumeTop = v
	}
	if err := os.MkdirAll(resumeTop, 0o755); err != nil {
		log.Fatalf("init sessions dir: %v", err)
	}

	store, err := NewSOPStore(sopsDir)
	if err != nil {
		log.Fatalf("load sops: %v", err)
	}
	srv := NewServer(cfg, store, resumeTop)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.healthz)
	mux.HandleFunc("/ask_json", srv.askJSON)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	addr := ":" + port

	log.Printf("qproxy listening on %s (sessions=%s, sops=%s)", addr, resumeTop, sopsDir)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("listen: %v", err)
	}
}
