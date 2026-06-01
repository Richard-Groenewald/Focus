const https = require('https');
// Host is env-driven so production vs test databases can be selected per Netlify
// deploy context. Falls back to the production project if SUPABASE_HOST is unset.
const SB = process.env.SUPABASE_HOST || 'kevrfdjqyuhmgziqxuvs.supabase.co';

exports.handler = async (event) => {
  const KEY = process.env.SUPABASE_SECRET_KEY;
  if (!KEY) return { statusCode: 500, headers: { 'Access-Control-Allow-Origin': '*' }, body: 'Missing SUPABASE_SECRET_KEY env var' };
  if (event.httpMethod === 'OPTIONS') return {
    statusCode: 200,
    headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Content-Type,Prefer', 'Access-Control-Allow-Methods': 'GET,POST,PATCH,DELETE,OPTIONS' },
    body: ''
  };
  const path = event.path.replace('/.netlify/functions/sb', '/rest/v1');
  const qs = event.rawQuery ? '?' + event.rawQuery : '';
  return new Promise(resolve => {
    const req = https.request({
      hostname: SB, port: 443, path: path + qs, method: event.httpMethod,
      headers: { 'Content-Type': 'application/json', 'apikey': KEY, 'Authorization': 'Bearer ' + KEY, 'Prefer': event.headers['prefer'] || '' }
    }, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => resolve({
        statusCode: res.statusCode,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Content-Type,Prefer', 'Access-Control-Allow-Methods': 'GET,POST,PATCH,DELETE,OPTIONS' },
        body: d
      }));
    });
    req.on('error', e => resolve({ statusCode: 500, body: JSON.stringify({ error: e.message }) }));
    if (event.body) req.write(event.body);
    req.end();
  });
};
