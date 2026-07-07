const http = require("http");

const port = Number(process.env.PORT || 8080);

const server = http.createServer((req, res) => {
  const { method, url } = req;

  if (method === "GET" && url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok", service: "control-plane" }));
    return;
  }

  if (method === "GET" && url === "/") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        service: "control-plane",
        message: "Control plane scaffold is running",
      })
    );
    return;
  }

  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "not_found" }));
});

server.listen(port, "0.0.0.0", () => {
  console.log(`control-plane listening on ${port}`);
});
