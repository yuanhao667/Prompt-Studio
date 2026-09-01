const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

const port = Number(process.env.PORT || 8080);
const previewPage = fs.readFileSync(path.join(__dirname, "index.html"));
const historyPage = fs.readFileSync(path.join(__dirname, "history.html"));

function send(response, status, body) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  response.end(`${JSON.stringify(body, null, 2)}\n`);
}

const server = http.createServer((request, response) => {
  const path = new URL(request.url, "http://localhost").pathname;

  if (request.method === "GET" && path === "/") {
    response.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(previewPage);
    return;
  }

  if (request.method === "GET" && (path === "/history" || path === "/history/")) {
    response.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(historyPage);
    return;
  }

  if (request.method === "GET" && path === "/health") {
    send(response, 200, {
      service: "Prompt Iteration Assistant Preview API",
      status: "ok",
      phase: "xcode-preview",
      privacy: "No prompts or API keys are stored by this service.",
    });
    return;
  }

  if (request.method === "POST" && path === "/api/v1/optimize") {
    send(response, 501, {
      error: "provider_not_configured",
      message: "The production macOS app will call DeepSeek directly with the user's Keychain key.",
    });
    return;
  }

  send(response, 404, { error: "not_found" });
});

server.listen(port, "0.0.0.0", () => {
  console.log(`Preview API listening on ${port}`);
});
