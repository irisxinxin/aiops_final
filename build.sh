#!/usr/bin/env bash
set -euo pipefail

# 目标输出
BRIDGE_DIR="mcp-bridge"
BRIDGE_ZIP="mcp-bridge-full.zip"
AGENT_DIR="aiops-agent-pack"
AGENT_ZIP="aiops-agent-pack.zip"

rm -rf "$BRIDGE_DIR" "$AGENT_DIR" "$BRIDGE_ZIP" "$AGENT_ZIP"
mkdir -p "$BRIDGE_DIR/systemd" "$AGENT_DIR/.aws/amazonq/cli-agents"

########## Go MCP HTTP Bridge 源码 ##########
cat >"$BRIDGE_DIR/go.mod" <<'EOF'
module mcpbridge

go 1.21
EOF

# 为了更易传输，这份 main.go 做了适度压缩（可直接 go build）
cat >"$BRIDGE_DIR/main.go" <<'EOF'
package main
import("bufio";"bytes";"context";"encoding/json";"errors";"fmt";"io";"log";"net/http";"os";"os/exec";"os/signal";"path/filepath";"regexp";"strconv";"strings";"sync";"syscall";"time")
type Config struct{Servers map[string]SrvSpec`json:"mcpServers"`}
type SrvSpec struct{Command string`json:"command,omitempty"`;Args[]string`json:"args,omitempty"`;Env map[string]string`json:"env,omitempty"`;TransportType string`json:"transportType,omitempty"`;Type string`json:"type,omitempty"`;Disabled bool`json:"disabled,omitempty"`;URL string`json:"url,omitempty"`;Headers map[string]string`json:"headers,omitempty"`}
type rpcReq struct{JSONRPC string`json:"jsonrpc"`;ID json.RawMessage`json:"id,omitempty"`;Method string`json:"method"`;Params json.RawMessage`json:"params,omitempty"`}
type rpcResp struct{JSONRPC string`json:"jsonrpc"`;ID json.RawMessage`json:"id,omitempty"`;Result any`json:"result,omitempty"`;Error *rpcErr`json:"error,omitempty"`}
type rpcErr struct{Code int`json:"code"`;Message string`json:"message"`}
type ToolItem struct{Name string`json:"name"`;Description string`json:"description,omitempty"`;InputSchema map[string]any`json:"inputSchema,omitempty"`}
var(cfgPath=getenv("MCP_CONFIG","./mcp.json");bindAddr=getenv("BIND_ADDR","0.0.0.0");bindPort=getenv("BIND_PORT","7011");timeout=getenvDur("BACKEND_TIMEOUT",45*time.Second);initRetry=getenvInt("INIT_RETRY",8);sensitiveKey=regexp.MustCompile(`(?i)(pass|password|token|secret|key|bearer)`))
func getenv(k,def string)string{if v:=strings.TrimSpace(os.Getenv(k));v!=""{return v};return def}
func getenvInt(k string,def int)int{v:=strings.TrimSpace(os.Getenv(k));if v==""{return def};if n,err:=strconv.Atoi(v);err==nil{return n};return def}
func getenvDur(k string,def time.Duration)time.Duration{v:=strings.TrimSpace(os.Getenv(k));if v==""{return def};if d,err:=time.ParseDuration(v);err==nil{return d};if n,err:=strconv.Atoi(v);err==nil{return time.Duration(n)*time.Second};return def}
func sanitizeName(s string)string{var b strings.Builder;u:=false;for _,r:=range s{ok:=(r>='a'&&r<='z')||(r>='A'&&r<='Z')||(r>='0'&&r<='9');if !ok{if u{continue};b.WriteByte('_');u=true;continue};b.WriteRune(r);u=false};out:=strings.Trim(b.String()," _");if out==""{return "srv"};return out}
func redactArgs(a[]string)[]string{o:=append([]string(nil),a...);for i:=0;i<len(o);i++{x:=o[i];if x=="-e"&&i+1<len(o){kvs:=o[i+1];if eq:=strings.IndexByte(kvs,'=');eq>0{name:=kvs[:eq];if sensitiveKey.MatchString(name){o[i+1]=name+"=***"}}else{if sensitiveKey.MatchString(kvs){o[i+1]=kvs+"=***"}};i++;continue};if eq:=strings.IndexByte(x,'=');eq>0{name:=x[:eq];if sensitiveKey.MatchString(name){o[i]=name+"=***"}}};return o}
type Backend interface{Name()string;Initialize(context.Context)error;ListTools(context.Context)([]ToolItem,error);CallTool(context.Context,string,map[string]any)(map[string]any,error);Close()error}
type stdioBackend struct{name string;cmd *exec.Cmd;stdin io.WriteCloser;stdout io.ReadCloser;reader *bufio.Reader;closed chan struct{};pending map[string]chan map[string]any;pm sync.Mutex;rpcMu sync.Mutex;seq int64;sm sync.Mutex}
func newStdioBackend(name string,s SrvSpec)(*stdioBackend,error){if s.Command==""{return nil,fmt.Errorf("%s: missing command",name)};cmd:=exec.Command(s.Command,s.Args...);cmd.Env=os.Environ();for k,v:=range s.Env{cmd.Env=append(cmd.Env,fmt.Sprintf("%s=%s",k,v))};stdin,err:=cmd.StdinPipe();if err!=nil{return nil,err};stdout,err:=cmd.StdoutPipe();if err!=nil{return nil,err};stderr,_:=cmd.StderrPipe();sa:=redactArgs(s.Args);log.Printf("[%s] spawn stdio: %s %s",name,s.Command,strings.Join(sa," "));if err:=cmd.Start();err!=nil{return nil,err};if stderr!=nil{go func(){sc:=bufio.NewScanner(stderr);for sc.Scan(){log.Printf("[%s][stderr] %s",name,sc.Text())}}()};return &stdioBackend{name:name,cmd:cmd,stdin:stdin,stdout:stdout,reader:bufio.NewReader(stdout),closed:make(chan struct{}),pending:make(map[string]chan map[string]any)},nil}
func (s*stdioBackend)Name()string{return s.name}
func (s*stdioBackend)Initialize(ctx context.Context)error{go s.readLoop();_,err:=s.rpc(ctx,"initialize",map[string]any{});return err}
func (s*stdioBackend)ListTools(ctx context.Context)([]ToolItem,error){res,err:=s.rpc(ctx,"tools/list",map[string]any{});if err!=nil{return nil,err};b,_:=json.Marshal(res["tools"]);var out[]ToolItem;_ = json.Unmarshal(b,&out);return out,nil}
func (s*stdioBackend)CallTool(ctx context.Context,tool string,args map[string]any)(map[string]any,error){return s.rpc(ctx,"tools/call",map[string]any{"name":tool,"arguments":args})}
func (s*stdioBackend)Close()error{select{case<-s.closed:default:close(s.closed)};if s.cmd!=nil&&s.cmd.Process!=nil{_ = s.cmd.Process.Signal(syscall.SIGTERM);done:=make(chan struct{});go func(){_ = s.cmd.Wait();close(done)}();select{case<-done:case<-time.After(3*time.Second):_ = s.cmd.Process.Kill()}};return nil}
func (s*stdioBackend)nextID()string{s.sm.Lock();defer s.sm.Unlock();s.seq++;return strconv.FormatInt(s.seq,10)}
func (s*stdioBackend)rpc(ctx context.Context,method string,params map[string]any)(map[string]any,error){s.rpcMu.Lock();defer s.rpcMu.Unlock();id:=s.nextID();req:=map[string]any{"jsonrpc":"2.0","id":id,"method":method,"params":params};raw,_:=json.Marshal(req);ch:=make(chan map[string]any,1);s.pm.Lock();s.pending[id]=ch;s.pm.Unlock();if err:=s.writeFrame(raw);err!=nil{s.removePending(id);return nil,err};select{case<-ctx.Done():s.removePending(id);return nil,ctx.Err();case<-s.closed:s.removePending(id);return nil,errors.New("backend closed");case resp:=<-ch:if e,ok:=resp["error"].(map[string]any);ok{return nil,fmt.Errorf("%v",e["message"])};if r,ok:=resp["result"].(map[string]any);ok{return r,nil};return map[string]any{"result":resp["result"]},nil}}
func (s*stdioBackend)removePending(id string){s.pm.Lock();delete(s.pending,id);s.pm.Unlock()}
func (s*stdioBackend)readLoop(){for{payload,err:=s.readFrame();if err!=nil{if !errors.Is(err,io.EOF){log.Printf("[%s] read error: %v",s.name,err)};select{case<-s.closed:default:close(s.closed)};return};var msg map[string]any;if err:=json.Unmarshal(payload,&msg);err!=nil{log.Printf("[%s] bad json: %v",s.name,err);continue};id:=fmt.Sprint(msg["id"]);if id==""{continue};s.pm.Lock();ch:=s.pending[id];if ch!=nil{ch<-msg;delete(s.pending,id)};s.pm.Unlock()}}
func (s*stdioBackend)readFrame()([]byte,error){cl:=0;for{line,err:=s.reader.ReadString('\n');if err!=nil{return nil,err};line=strings.TrimRight(line,"\r\n");if line==""{break};parts:=strings.SplitN(line,":",2);if len(parts)==2&&strings.EqualFold(strings.TrimSpace(parts[0]),"Content-Length"){cl,_=strconv.Atoi(strings.TrimSpace(parts[1]))}};if cl<=0{return nil,io.EOF};body:=make([]byte,cl);if _,err:=io.ReadFull(s.reader,body);err!=nil{return nil,err};return body,nil}
func (s*stdioBackend)writeFrame(p[]byte)error{var b bytes.Buffer;fmt.Fprintf(&b,"Content-Length: %d\r\n\r\n",len(p));b.Write(p);_,err:=s.stdin.Write(b.Bytes());return err}
type httpBackend struct{name string;url string;headers map[string]string;client *http.Client}
func newHTTPBackend(name string,sp SrvSpec)(*httpBackend,error){if sp.URL==""{return nil,fmt.Errorf("%s: http missing url",name)};return &httpBackend{name:name,url:sp.URL,headers:sp.Headers,client:&http.Client{Timeout:timeout}},nil}
func (h*httpBackend)Name()string{return h.name}
func (h*httpBackend)Initialize(ctx context.Context)error{_,err:=h.rpc(ctx,"initialize",map[string]any{});return err}
func (h*httpBackend)ListTools(ctx context.Context)([]ToolItem,error){res,err:=h.rpc(ctx,"tools/list",map[string]any{});if err!=nil{return nil,err};b,_:=json.Marshal(res["tools"]);var out[]ToolItem;_ = json.Unmarshal(b,&out);return out,nil}
func (h*httpBackend)CallTool(ctx context.Context,tool string,args map[string]any)(map[string]any,error){return h.rpc(ctx,"tools/call",map[string]any{"name":tool,"arguments":args})}
func (h*httpBackend)rpc(ctx context.Context,method string,params map[string]any)(map[string]any,error){req:=rpcReq{JSONRPC:"2.0",ID:json.RawMessage(`1`),Method:method};if params!=nil{b,_:=json.Marshal(params);req.Params=b};body,_:=json.Marshal(req);rq,_:=http.NewRequestWithContext(ctx,http.MethodPost,h.url,bytes.NewReader(body));rq.Header.Set("Content-Type","application/json");for k,v:=range h.headers{rq.Header.Set(k,v)};resp,err:=h.client.Do(rq);if err!=nil{return nil,err};defer resp.Body.Close();if resp.StatusCode>=400{b,_:=io.ReadAll(resp.Body);return nil,fmt.Errorf("http %d: %s",resp.StatusCode,string(b))};var r rpcResp;if err:=json.NewDecoder(resp.Body).Decode(&r);err!=nil{return nil,err};if r.Error!=nil{return nil,errors.New(r.Error.Message)};switch v:=r.Result.(type){case map[string]any:return v,nil;default:return map[string]any{"result":v},nil}}
func (h*httpBackend)Close()error{return nil}
type Aggregator struct{backends map[string]Backend;tools map[string][2]string;mu sync.RWMutex}
func NewAggregator()*Aggregator{return &Aggregator{backends:map[string]Backend{},tools:map[string][2]string{}}}
func (a*Aggregator)StartFromConfig(c*Config)error{if c==nil||len(c.Servers)==0{return fmt.Errorf("mcp.json missing mcpServers")};for raw,sp:=range c.Servers{if sp.Disabled{log.Printf("[%s] disabled -> skip",raw);continue};kind:=strings.ToLower(strings.TrimSpace(sp.TransportType));if kind==""{kind=strings.ToLower(strings.TrimSpace(sp.Type))};if kind==""{kind="stdio"};name:=sanitizeName(raw);var bk Backend;var err error;switch kind{case "stdio":bk,err=newStdioBackend(name,sp);case "http":bk,err=newHTTPBackend(name,sp);default:err=fmt.Errorf("unsupported transport: %s",kind)};if err!=nil{log.Printf("[%s] backend create failed: %v",raw,err);continue};a.backends[name]=bk;var initErr error;for i:=0;i<initRetry;i++{ctx,cancel:=context.WithTimeout(context.Background(),timeout);initErr=bk.Initialize(ctx);cancel();if initErr==nil{break};time.Sleep(time.Second)};if initErr!=nil{log.Printf("[%s] initialize failed after retries: %v",raw,initErr);continue};var tools []ToolItem;{ctx,cancel:=context.WithTimeout(context.Background(),timeout);tl,err:=bk.ListTools(ctx);cancel();if err!=nil{log.Printf("[%s] tools/list failed: %v",raw,err);continue};tools=tl};for _,t:=range tools{exp:=name+"."+t.Name;a.tools[exp]=[2]string{name,t.Name}};log.Printf("[%s] ready, tools: %d",raw,len(tools))};return nil}
func (a*Aggregator)ListExported()[]ToolItem{a.mu.RLock();defer a.mu.RUnlock();out:=make([]ToolItem,0,len(a.tools));for exp,p:=range a.tools{out=append(out,ToolItem{Name:exp,Description:fmt.Sprintf("From %s -> %s",p[0],p[1]),InputSchema:map[string]any{"type":"object"}})};return out}
func (a*Aggregator)Call(ctx context.Context,name string,args map[string]any)(map[string]any,error){a.mu.RLock();defer a.mu.RUnlock();var srv,orig string;if p,ok:=a.tools[name];ok{srv,orig=p[0],p[1]}else if !strings.Contains(name,"."){c:=make([][2]string,0,2);for exp,p:=range a.tools{if strings.HasSuffix(exp,"."+name){c=append(c,p)}};if len(c)==1{srv,orig=c[0][0],c[0][1]}else{return nil,fmt.Errorf("unknown or ambiguous tool: %s",name)}}else{return nil,fmt.Errorf("unknown tool: %s",name)};bk:=a.backends[srv];if bk==nil{return nil,fmt.Errorf("backend missing: %s",srv)};return bk.CallTool(ctx,orig,args)}
func (a*Aggregator)Close(){for _,bk:=range a.backends{_ = bk.Close()}}
type httpServer struct{agg *Aggregator;timeout time.Duration;mux *http.ServeMux}
func newHTTP(agg *Aggregator)*httpServer{s:=&httpServer{agg:agg,timeout:timeout,mux:http.NewServeMux()};s.routes();return s}
func (s*httpServer)routes(){s.mux.HandleFunc("/healthz",func(w http.ResponseWriter,_ *http.Request){w.Header().Set("Content-Type","application/json");_ = json.NewEncoder(w).Encode(map[string]any{"ok":true,"tools":len(s.agg.tools),"ts":time.Now().Unix()})});s.mux.HandleFunc("/mcp",func(w http.ResponseWriter,r *http.Request){if r.Method!=http.MethodPost{http.Error(w,"POST only",http.StatusMethodNotAllowed);return};var req rpcReq;if err:=json.NewDecoder(r.Body).Decode(&req);err!=nil{writeRPC(w,rpcResp{JSONRPC:"2.0",ID:req.ID,Error:&rpcErr{Code:-32700,Message:"Parse error"}});return};switch req.Method{case "initialize":writeRPC(w,rpcResp{JSONRPC:"2.0",ID:req.ID,Result:map[string]any{"protocolVersion":"2024-11-05","capabilities":map[string]any{"tools":map[string]any{}},"serverInfo":map[string]any{"name":"mcp-http-bridge","version":"0.3.0"}}});case "tools/list":writeRPC(w,rpcResp{JSONRPC:"2.0",ID:req.ID,Result:map[string]any{"tools":s.agg.ListExported()}});case "tools/call":var p struct{Name string`json:"name"`;Arguments map[string]any`json:"arguments"`};if len(req.Params)>0{if err:=json.Unmarshal(req.Params,&p);err!=nil{writeRPC(w,rpcResp{JSONRPC:"2.0",ID:req.ID,Error:&rpcErr{Code:-32602,Message:"Invalid params"}});return}};ctx,cancel:=context.WithTimeout(r.Context(),s.timeout);defer cancel();res,err:=s.agg.Call(ctx,p.Name,p.Arguments);if err!=nil{writeRPC(w,rpcResp{JSONRPC:"2.0",ID:req.ID,Error:&rpcErr{Code:-32000,Message:err.Error()}});return};writeRPC(w,rpcResp{JSONRPC:"2.0",ID:req.ID,Result:res});default:writeRPC(w,rpcResp{JSONRPC:"2.0",ID:req.ID,Error:&rpcErr{Code:-32601,Message:"Method not found"}})}})}
func writeRPC(w http.ResponseWriter,resp rpcResp){w.Header().Set("Content-Type","application/json");_ = json.NewEncoder(w).Encode(resp)}
func (s*httpServer)serve(addr string)error{httpSrv:=&http.Server{Addr:addr,Handler:s.mux,ReadHeaderTimeout:5*time.Second};idle:=make(chan struct{});go func(){sig:=make(chan os.Signal,1);signal.Notify(sig,syscall.SIGINT,syscall.SIGTERM);<-sig;_ = httpSrv.Shutdown(context.Background());close(idle)}();log.Printf("[bridge] listening on %s",addr);if err:=httpSrv.ListenAndServe();err!=nil&&!errors.Is(err,http.ErrServerClosed){return err};<-idle;return nil}
func main(){abs,_:=filepath.Abs(cfgPath);log.Printf("[bridge] loading %s",abs);raw,err:=os.ReadFile(cfgPath);if err!=nil{log.Fatalf("read config: %v",err)};var c Config;if err:=json.Unmarshal(raw,&c);err!=nil{log.Fatalf("parse config: %v",err)};agg:=NewAggregator();if err:=agg.StartFromConfig(&c);err!=nil{log.Fatalf("start backends: %v",err)};defer agg.Close();srv:=newHTTP(agg);if err:=srv.serve(bindAddr+":"+bindPort);err!=nil{log.Fatalf("serve: %v",err)}}
EOF

cat >"$BRIDGE_DIR/README.md" <<'EOF'
# MCP HTTP Bridge
- 监听: `http://127.0.0.1:7011/mcp`
- 预热并聚合 `mcp.json` 里声明的 MCP（支持 stdio / http）
EOF

cat >"$BRIDGE_DIR/systemd/mcp-bridge.service" <<'EOF'
[Unit]
Description=HTTP MCP Bridge (preheated MCP tools)
Wants=network-online.target
After=network-online.target docker.socket

[Service]
Type=simple
EnvironmentFile=-/etc/default/mcp-bridge
ExecStart=/usr/local/bin/mcp-bridge
Restart=on-failure
RestartSec=2s
User=root
Group=root
NoNewPrivileges=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cat >"$BRIDGE_DIR/systemd/mcp-bridge.env" <<'EOF'
MCP_CONFIG=/etc/mcp/mcp.json
BIND_ADDR=127.0.0.1
BIND_PORT=7011
BACKEND_TIMEOUT=45s
INIT_RETRY=8
EOF

cat >"$BRIDGE_DIR/install_bridge.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
WORK=${WORK:-/opt/mcp-bridge}
sudo mkdir -p "$WORK/systemd" /etc/mcp
sudo chown -R "$USER":"$USER" "$WORK"

install -m 0644 ./go.mod "$WORK/go.mod"
install -m 0644 ./main.go "$WORK/main.go"
install -m 0644 ./mcp.json "$WORK/mcp.json"

cd "$WORK"
go build -o mcp-bridge .
sudo install -m 0755 mcp-bridge /usr/local/bin/mcp-bridge
sudo install -m 0644 "$WORK/mcp.json" /etc/mcp/mcp.json

sudo tee /etc/default/mcp-bridge >/dev/null <<'ENV'
MCP_CONFIG=/etc/mcp/mcp.json
BIND_ADDR=127.0.0.1
BIND_PORT=7011
BACKEND_TIMEOUT=45s
INIT_RETRY=8
ENV

sudo tee /etc/systemd/system/mcp-bridge.service >/dev/null <<'UNIT'
[Unit]
Description=HTTP MCP Bridge (preheated MCP tools)
Wants=network-online.target
After=network-online.target docker.socket
[Service]
Type=simple
EnvironmentFile=-/etc/default/mcp-bridge
ExecStart=/usr/local/bin/mcp-bridge
Restart=on-failure
RestartSec=2s
User=root
Group=root
NoNewPrivileges=true
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now mcp-bridge
sudo systemctl status mcp-bridge --no-pager
EOF
chmod +x "$BRIDGE_DIR/install_bridge.sh"

# 用你发的 mcp.json 实值（包含 docker/uvx 工具）
cat >"$BRIDGE_DIR/mcp.json" <<'EOF'
{
  "mcpServers": {
    "victoriametrics": {
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "-e",
        "VM_INSTANCE_ENTRYPOINT",
        "-e",
        "VM_INSTANCE_TYPE",
        "-e",
        "VM_INSTANCE_BEARER_TOKEN",
        "ghcr.io/victoriametrics-community/mcp-victoriametrics"
      ],
      "env": {
        "VM_INSTANCE_ENTRYPOINT": "http://aps1-vm-internal-1.beta.tplinknbu.com/",
        "VM_INSTANCE_TYPE": "cluster",
        "VM_INSTANCE_BEARER_TOKEN": ""
      }
    },
    "elasticsearch-mcp-server": {
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "-e",
        "ES_URL=https://10.53.147.74:9200",
        "-e",
        "ES_USERNAME=elastic",
        "-e",
        "ES_LOGIN=elastic",
        "-e",
        "ES_PASSWORD=NBU_cpavhmbSGadmin2018!",
        "-e",
        "ES_SSL_SKIP_VERIFY",
        "docker.elastic.co/mcp/elasticsearch:0.3.1",
        "stdio"
      ],
      "env": {
        "ES_SSL_SKIP_VERIFY": "true"
      }
    },
    "awslabs.cloudwatch-mcp-server": {
      "autoApprove": [],
      "disabled": false,
      "command": "uvx",
      "args": [
        "awslabs.cloudwatch-mcp-server@latest"
      ],
      "env": {
        "FASTMCP_LOG_LEVEL": "ERROR"
      },
      "transportType": "stdio"
    },
    "alertmanager": {
      "command": "docker",
      "args": [
        "run",
        "--rm",
        "-i",
        "--network=host",
        "-e",
        "ALERTMANAGER_URL=http://aps1-alertmanager-internal.beta.tplinknbu.com",
        "ghcr.io/kaznak/alertmanager-mcp:latest"
      ],
      "env": {}
    },
    "awslabs.eks-mcp-server": {
      "command": "uvx",
      "args": [
        "awslabs.eks-mcp-server@latest"
      ],
      "env": {
        "FASTMCP_LOG_LEVEL": "INFO"
      },
      "autoApprove": [
        "list_k8s_resources",
        "get_pod_logs",
        "get_k8s_events",
        "get_cloudwatch_logs",
        "get_cloudwatch_metrics",
        "get_policies_for_role",
        "search_eks_troubleshoot_guide",
        "list_api_versions"
      ]
    }
  }
}
EOF

########## aiops agent 包 ##########
cat >"$AGENT_DIR/.aws/amazonq/cli-agents/aiops.json" <<'EOF'
{
  "name": "aiops",
  "description": "AIOps RCA agent wired to HTTP MCP Bridge",
  "prompt": "You are an AIOps root cause analysis assistant. Keep outputs concise and actionable.",
  "model": "claude-sonnet-4",
  "mcpServers": {
    "bridge": { "type": "http", "url": "http://127.0.0.1:7011/mcp", "timeout": 45000 }
  },
  "tools": ["@bridge"]
}
EOF

cat >"$AGENT_DIR/README.md" <<'EOF'
# aiops agent
把本目录下 `.aws/amazonq/cli-agents/aiops.json` 拷到 `~/.aws/amazonq/cli-agents/aiops.json`
调用示例：
q chat --agent aiops --no-interactive --resume --trust-all-tools "Analyze this alert ..."
EOF

cat >"$AGENT_DIR/run-example.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
q chat --agent aiops --no-interactive --resume --trust-all-tools "$@"
EOF
chmod +x "$AGENT_DIR/run-example.sh"

########## 打包 ##########
( cd "$BRIDGE_DIR" && zip -qr "../$BRIDGE_ZIP" . )
( cd "$AGENT_DIR"  && zip -qr "../$AGENT_ZIP"  . )

echo "OK -> $BRIDGE_ZIP  $AGENT_ZIP"


