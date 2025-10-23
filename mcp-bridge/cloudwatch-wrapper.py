#!/usr/bin/env python3
import json
import sys
import subprocess
import os

def read_message():
    line = sys.stdin.readline()
    if line.startswith('Content-Length:'):
        length = int(line.split(':')[1].strip())
        sys.stdin.readline()
        content = sys.stdin.read(length)
        return json.loads(content)
    return json.loads(line.strip())

def send_message(msg):
    content = json.dumps(msg)
    print(f"Content-Length: {len(content)}\r\n\r\n{content}", end='')
    sys.stdout.flush()

def main():
    env = os.environ.copy()
    env['AWS_DEFAULT_REGION'] = 'ap-southeast-1'
    
    proc = subprocess.Popen(
        ['uvx', 'awslabs.cloudwatch-mcp-server@latest'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, 
        env=env, text=True, bufsize=0
    )
    
    while True:
        try:
            req = read_message()
            if not req: break
            
            # Send JSON directly to server (no Content-Length)
            json_str = json.dumps(req) + '\n'
            proc.stdin.write(json_str)
            proc.stdin.flush()
            
            # Read response (expect JSON line)
            resp_line = proc.stdout.readline()
            if resp_line.strip():
                resp = json.loads(resp_line.strip())
                send_message(resp)
                
        except Exception as e:
            send_message({"jsonrpc":"2.0","id":req.get("id"),"error":{"code":-32603,"message":str(e)}})

if __name__ == "__main__":
    main()
