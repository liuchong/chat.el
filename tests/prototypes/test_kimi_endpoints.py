#!/usr/bin/env python3
"""Prototype: Test Kimi API endpoints"""

import os, sys, json, urllib.request, urllib.error

def test_endpoint(base_url, api_key, name):
    url = f"{base_url}/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}"
    }
    data = json.dumps({
        "model": "moonshot-v1-8k",
        "messages": [{"role": "user", "content": "Hello"}],
        "temperature": 0.7,
        "stream": False
    }).encode('utf-8')
    
    req = urllib.request.Request(url, data=data, headers=headers, method='POST')
    
    print(f"\n{'='*50}")
    print(f"Testing: {name}")
    print(f"URL: {url}")
    
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            body = response.read().decode('utf-8')
            print(f"✓ SUCCESS - Status: {response.status}")
            print(f"Response: {body[:300]}")
            return True
    except urllib.error.HTTPError as e:
        print(f"✗ HTTP {e.code}: {e.read().decode('utf-8')[:200]}")
        return False
    except Exception as e:
        print(f"✗ Error: {type(e).__name__}: {e}")
        return False

def main():
    # Read API key from config
    api_key = None
    config_file = Path(__file__).resolve().parents[2] / 'chat-config.local.el'
    if config_file.exists():
        with config_file.open() as f:
            content = f.read()
            import re
            match = re.search(r'sk-[a-zA-Z0-9]+', content)
            if match:
                api_key = match.group(0)
    
    if not api_key:
        print("Error: No API key found")
        sys.exit(1)
    
    print(f"API Key: {api_key[:20]}...")
    
    # Test endpoints
    endpoints = [
        ("https://api.moonshot.cn/v1", "Standard Moonshot"),
        ("https://api.moonshot.cn", "Moonshot no /v1"),
    ]
    
    for base_url, name in endpoints:
        test_endpoint(base_url, api_key, name)
    
    print("\n" + "="*50)
    print("If both fail with 'Invalid Authentication', your key")
    print("is likely for Kimi Code China (console.kimi.com)")
    print("which may need a different endpoint.")

if __name__ == '__main__':
    main()
