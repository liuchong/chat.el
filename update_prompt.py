import re

with open('chat-tool-caller.el', 'r') as f:
    content = f.read()

# 更新提示词文字
content = content.replace(
    'respond with a function_call in this exact format:',
    'respond with ONLY a JSON function call in this exact format (no other text):'
)

content = content.replace(
    'After receiving tool results, continue helping the user naturally.',
    'After the function executes, you will receive the result and can continue helping the user.'
)

# 替换 XML 示例为 JSON 示例
# 需要处理多行字符串
old_xml = '''<function_calls>
<invoke name=\"TOOL_NAME\">
<parameter name=\"PARAM_NAME\">PARAM_VALUE</parameter>
</invoke>
</function_calls>'''

new_json = '{\\"function_call\\": {\\"name\\": \\"TOOL_NAME\\", \\"arguments\\": {\\"arg1\\": \\"value1\\", \\"arg2\\": \\"value2\\"}}}'

if old_xml in content:
    content = content.replace(old_xml, new_json)
    print("✓ XML 示例已替换为 JSON 示例")
else:
    print("✗ 未找到 XML 示例")

with open('chat-tool-caller.el', 'w') as f:
    f.write(content)

print("完成")
