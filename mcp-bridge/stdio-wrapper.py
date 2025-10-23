#!/usr/bin/env python3
"""
Stdio wrapper for mcp-bridge HTTP server
Converts stdio MCP protocol to HTTP requests
"""
import json
import sys
import requests
import uuid
import logging

# Configure logging to stderr so it doesn't interfere with stdio
logging.basicConfig(level=logging.DEBUG, stream=sys.stderr, 
                   format='%(asctime)s - %(levelname)s - %(message)s')

MCP_BRIDGE_URL = "http://localhost:7011/mcp"

def send_request(data):
    """Send request to mcp-bridge HTTP server"""
    try:
        logging.debug(f"Sending request: {data}")
        response = requests.post(MCP_BRIDGE_URL, json=data, timeout=30)
        result = response.json()
        logging.debug(f"Received response: {result}")
        return result
    except Exception as e:
        logging.error(f"Error sending request: {e}")
        return {
            "jsonrpc": "2.0",
            "id": data.get("id"),
            "error": {
                "code": -32603,
                "message": f"Internal error: {str(e)}"
            }
        }

def main():
    """Main stdio loop"""
    logging.info("Starting MCP stdio wrapper")
    
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
                
            try:
                request = json.loads(line)
                response = send_request(request)
                output = json.dumps(response)
                print(output)
                sys.stdout.flush()
                logging.debug(f"Sent response: {output}")
            except json.JSONDecodeError as e:
                logging.error(f"JSON decode error: {e}")
                error_response = {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {
                        "code": -32700,
                        "message": "Parse error"
                    }
                }
                print(json.dumps(error_response))
                sys.stdout.flush()
    except Exception as e:
        logging.error(f"Fatal error in main loop: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
