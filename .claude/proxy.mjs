// Simple reverse proxy to forward preview requests to the running Rails server
import http from "node:http";

const TARGET = process.env.TARGET_PORT || "3001";
const PORT = process.env.PORT || "3002";

const server = http.createServer((req, res) => {
  const opts = {
    hostname: "127.0.0.1",
    port: TARGET,
    path: req.url,
    method: req.method,
    headers: req.headers,
  };
  const proxy = http.request(opts, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res, { end: true });
  });
  proxy.on("error", (e) => {
    res.writeHead(502);
    res.end("Proxy error: " + e.message);
  });
  req.pipe(proxy, { end: true });
});

server.listen(PORT, () => {
  console.log(`Proxy listening on :${PORT} → :${TARGET}`);
});
