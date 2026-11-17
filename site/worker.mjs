// No network dependencies or bindings: this Worker serves Kah's built assets.
export function createWorker(assets) {
  return {
    fetch(request) {
      const url = new URL(request.url);
      const headers = { 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'strict-origin-when-cross-origin' };
      if (!['GET', 'HEAD'].includes(request.method)) {
        return new Response('Method not allowed', { status: 405, headers: { ...headers, Allow: 'GET, HEAD' } });
      }
      if (url.pathname === '/kah' || url.pathname === '/kah/index.html') {
        url.pathname = '/kah/';
        return new Response(null, { status: 308, headers: { ...headers, Location: url.href } });
      }
      const asset = assets[url.pathname];
      if (!asset) return new Response(request.method === 'HEAD' ? null : 'Not found', { status: 404, headers });
      Object.assign(headers, {
        'Content-Type': asset.contentType,
        'Cache-Control': 'public, max-age=60, stale-while-revalidate=300',
        ETag: asset.etag,
      });
      if (asset.csp) headers['Content-Security-Policy'] = asset.csp;
      if (request.headers.get('If-None-Match') === asset.etag) return new Response(null, { status: 304, headers });
      return new Response(request.method === 'HEAD' ? null : asset.body, { headers });
    },
  };
}
