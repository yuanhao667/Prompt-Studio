# Preview API

这是用于部署和联调的无状态预览 API，不保存 Prompt 或 API Key。

线上编辑页：https://s55a2810lfsogrqs2979l.apigateway-cn-beijing.volceapi.com/

线上历史页：https://s55a2810lfsogrqs2979l.apigateway-cn-beijing.volceapi.com/history

```bash
npm start
curl http://localhost:8080/health
```

发布后续版本：

```bash
vefaas deploy --appId 978680999533 --yes
```

正式 macOS App 仍按 PRD 使用用户 Keychain 中的 Key 直连 DeepSeek。
