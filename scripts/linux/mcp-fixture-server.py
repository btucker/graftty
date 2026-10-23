#!/usr/bin/env python3
"""Disposable parent-local MCP server for live bridge tests.

The second argument is a parent-only credential fixture. Its bytes are never
returned over MCP. Each tool call appends one marker, allowing replay checks.
"""
import json
import pathlib
import sys

marker = pathlib.Path(sys.argv[1])
credential = pathlib.Path(sys.argv[2])
assert credential.read_text().startswith('graftty-parent-only-')
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request:
        continue
    method = request.get('method')
    if method == 'initialize':
        result = {'protocolVersion': request['params']['protocolVersion'], 'capabilities': {'tools': {}},
                  'serverInfo': {'name': 'fixture', 'version': '1'}}
    elif method == 'tools/list':
        result = {'tools': [{'name': 'touch_parent', 'description': 'Record execution on the parent Mac',
                             'inputSchema': {'type': 'object', 'properties': {}}}]}
    elif method == 'tools/call' and request['params']['name'] == 'touch_parent':
        with marker.open('a') as output:
            output.write('parent executed\n')
        result = {'content': [{'type': 'text', 'text': 'parent executed'}]}
    else:
        result = {}
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
