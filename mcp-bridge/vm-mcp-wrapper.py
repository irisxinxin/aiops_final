#!/usr/bin/env python3
import json
import sys
import requests
import os

class VictoriaMetricsMCP:
    def __init__(self):
        self.vm_url = os.getenv('VM_INSTANCE_ENTRYPOINT', 'http://aps1-vm-internal-1.beta.tplinknbu.com/select/0/prometheus/')
        
    def handle_request(self, request):
        method = request.get('method')
        request_id = request.get('id')
        
        if method == 'initialize':
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "victoriametrics-mcp-wrapper", "version": "1.0.0"}
                }
            }
        elif method == 'tools/list':
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "tools": [{
                        "name": "query",
                        "description": "Execute VictoriaMetrics query",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "query": {"type": "string", "description": "PromQL/MetricsQL query"},
                                "time": {"type": "string", "description": "Query time (optional)"}
                            },
                            "required": ["query"]
                        }
                    }]
                }
            }
        elif method == 'tools/call':
            params = request.get('params', {})
            tool_name = params.get('name')
            arguments = params.get('arguments', {})
            
            if tool_name == 'query':
                return self.execute_query(request_id, arguments)
            else:
                return {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32601, "message": f"Unknown tool: {tool_name}"}
                }
        else:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": f"Unknown method: {method}"}
            }
    
    def execute_query(self, request_id, arguments):
        query = arguments.get('query')
        time_param = arguments.get('time')
        
        try:
            url = f"{self.vm_url}api/v1/query"
            params = {'query': query}
            if time_param:
                params['time'] = time_param
                
            response = requests.get(url, params=params, timeout=10)
            response.raise_for_status()
            
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "content": [{
                        "type": "text",
                        "text": json.dumps(response.json(), indent=2)
                    }]
                }
            }
        except Exception as e:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32603, "message": f"Query failed: {str(e)}"}
            }

def read_message():
    while True:
        line = sys.stdin.readline()
        if not line:
            return None
        line = line.strip()
        if line.startswith('Content-Length:'):
            length = int(line.split(':')[1].strip())
            sys.stdin.readline()
            content = sys.stdin.read(length)
            return json.loads(content)
        elif line and not line.startswith('Content-'):
            return json.loads(line)

def send_message(message):
    content = json.dumps(message)
    print(f"Content-Length: {len(content)}\r\n\r\n{content}", end='')
    sys.stdout.flush()

def main():
    mcp = VictoriaMetricsMCP()
    
    while True:
        try:
            request = read_message()
            if request is None:
                break
            response = mcp.handle_request(request)
            send_message(response)
        except Exception as e:
            error_response = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32603, "message": f"Internal error: {str(e)}"}
            }
            send_message(error_response)

if __name__ == "__main__":
    main()
