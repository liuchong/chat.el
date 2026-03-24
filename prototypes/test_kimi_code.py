#!/usr/bin/env python3
"""Prototype: Test Kimi Code China API

References:
- https://www.kimi.com/code/docs/more/third-party-agents.html
"""

import os
import json
import urllib.request
import ssl

# Disable SSL verification for testing
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def test_kimi_code_api():
    """Test Kimi Code API endpoint."""
    
    # Read API key from config
    config_file = os.path.expanduser('~/projects/src/github.com/liuchong/chat.el/chat-config.local.el')
    api_key = None
    
    if os.path.exists(config_file):
        with open(config_file) as f:
            content = f.read()
            import re
            # Look for kimi-code or kimi key
            match = re.search(r'sk-kimi-[a-zA-Z0-9]+', content)
            if match:
                api_key = match.group(0)
    
    if not api_key:
        print("Error: No API key found in chat-config.local.el")
        return False
    
    print(f"Using API Key: {api_key[:25]}...")
    print("="*60)
    
    # Kimi Code endpoint
    base_url = "https://api.kimi.com/coding/v1"
    url = f"{base_url}/chat/completions"
    
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}"
    }
    
    data = {
        "model": "kimi-for-coding",
        "messages": [{"role": "user", "content": "Hello, this is a test from chat.el prototype"}],
        "temperature": 0.7,
        "max_tokens": 1024,
        "stream": False
    }
    
    req = urllib.request.Request(
        url,
        data=json.dumps(data).encode('utf-8'),
        headers=headers,
        method='POST'
    )
    
    print(f"Endpoint: {url}")
    print(f"Model: kimi-for-coding")
    print(f"Request body: {json.dumps(data, indent=2)}")
    print("="*60)
    
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as response:
            body = response.read().decode('utf-8')
            print(f"✓ SUCCESS - Status: {response.status}")
            print(f"\nResponse:\n{body}")
            
            # Parse and verify
            result = json.loads(body)
            if 'choices' in result:
                content = result['choices'][0]['message']['content']
                print(f"\n✓ Content received: {content[:100]}...")
                return True
            else:
                print(f"\n✗ Unexpected response format")
                return False
                
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8')
        print(f"✗ HTTP Error {e.code}:")
        print(body)
        return False
    except Exception as e:
        print(f"✗ Error: {type(e).__name__}: {e}")
        return False

if __name__ == '__main__':
    success = test_kimi_code_api()
    print("\n" + "="*60)
    if success:
        print("✓ API test PASSED - Kimi Code is working!")
    else:
        print("✗ API test FAILED")
    print("="*60)
