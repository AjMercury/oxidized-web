// HTTPS loopback proxy for the isolated browser fixture only.
const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');

https.createServer({
  key: fs.readFileSync(process.env.BACKUP_TLS_KEY),
  cert: fs.readFileSync(process.env.BACKUP_TLS_CERT)
}, (request, response) => {
  const upstream = http.request({
    hostname: '127.0.0.1', port: Number(process.env.BACKUP_FIXTURE_PORT || 45528),
    method: request.method, path: request.url,
    headers: { ...request.headers, 'x-forwarded-proto': 'https', 'x-forwarded-for': request.socket.remoteAddress }
  }, (result) => {
    response.writeHead(result.statusCode, result.headers);
    result.pipe(response);
  });
  upstream.on('error', () => { response.writeHead(502); response.end('Fixture unavailable'); });
  request.pipe(upstream);
}).listen(Number(process.env.BACKUP_PROXY_PORT || 45529), '127.0.0.1');
